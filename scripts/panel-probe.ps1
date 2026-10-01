<#
.SYNOPSIS
    探测 agent-panel 各成员的可用性，输出阵容表与建议名单。

.DESCRIPTION
    面板开会前跑一次，避免"以为成员在线，其实全都超时"。
    只做只读探测：TCP 连接 + HTTP /health（回退 /v1/models）+ CLI 可执行性。
    不会启动/停止任何模型服务，也不读取任何密钥内容。

.PARAMETER Config
    配置文件路径（扁平 key: value 格式，见 panel.example.yml）。
    只解析 `key: value` 行，不支持嵌套与列表 —— 这是刻意的简化。

.PARAMETER OpenCodeCli
    覆盖 CLI agent 路径（优先级高于配置文件与默认值）。

.PARAMETER LocalEndpoints
    本地 OpenAI 兼容端点（默认 1920 与 1919，可用配置文件覆盖）。

.PARAMETER TimeoutMs
    单个成员探测超时（毫秒），默认 1500。

.EXAMPLE
    pwsh -File scripts/panel-probe.ps1
    pwsh -File scripts/panel-probe.ps1 -Config panel.yml
    pwsh -File scripts/panel-probe.ps1 -LocalEndpoints http://127.0.0.1:8080/v1

.NOTES
    退出码：0 = 面板可用（≥2 名成员在线）；1 = 只有宿主模型，不建议开面板。
#>
[CmdletBinding()]
param(
    [string]$Config = "",
    [string]$OpenCodeCli = "",
    [string[]]$LocalEndpoints = @(),
    [int]$TimeoutMs = 1500
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 配置解析
function Read-FlatConfig {
    param([string]$Path)
    $cfg = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $cfg }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith('---')) { continue }
        $m = [regex]::Match($t, '^([A-Za-z0-9_.\-]+)\s*:\s*(.+?)\s*$')
        if ($m.Success) {
            $v = $m.Groups[2].Value.Trim('"').Trim("'")
            if ($v -and $v -notmatch '^<.*>$') { $cfg[$m.Groups[1].Value] = $v }
        }
    }
    return $cfg
}

$configPath = $Config
if (-not $configPath) {
    $candidate = Join-Path (Split-Path -Parent $PSScriptRoot) 'panel.yml'
    if (Test-Path -LiteralPath $candidate) { $configPath = $candidate }
}
$cfg = Read-FlatConfig -Path $configPath

if (-not $OpenCodeCli)   { $OpenCodeCli = $cfg['opencode.cli_path'] }
if (-not $OpenCodeCli)   { $OpenCodeCli = $env:PANEL_OPENCODE_CLI }
if (-not $LocalEndpoints -or $LocalEndpoints.Count -eq 0) {
    $eps = @()
    foreach ($k in 'local_a.url', 'local_b.url', 'local_c.url') { if ($cfg[$k]) { $eps += $cfg[$k] } }
    if ($eps.Count -eq 0 -and $env:PANEL_LOCAL_A) { $eps += $env:PANEL_LOCAL_A }
    if ($eps.Count -eq 0 -and $env:PANEL_LOCAL_B) { $eps += $env:PANEL_LOCAL_B }
    if ($eps.Count -eq 0) { $eps = @('http://127.0.0.1:1920/v1', 'http://127.0.0.1:1919/v1') }
    $LocalEndpoints = $eps
}

# 本地探测绕开系统代理（加速器开着时会把 127.0.0.1 也代理走）
try { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy } catch { }

# ---------------------------------------------------------------- 探测函数
function Test-TcpPort {
    # 参数不能叫 $Host —— 那是 PowerShell 的自动只读变量（与 $HOME 同类陷阱）
    param([string]$TargetHost, [int]$Port, [int]$Timeout)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($TargetHost, $Port)
        if (-not $task.Wait($Timeout)) { return $false }
        return $client.Connected
    } catch { return $false } finally { $client.Close() }
}

function Get-HttpOk {
    param([string]$Url, [int]$TimeoutSec)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Test-LocalEndpoint {
    param([string]$Base, [int]$Timeout)
    $result = [ordered]@{ Url = $Base; Tcp = $false; Http = $false; Detail = '' }
    # 容错：端点可能不带 scheme（例如写成 "127.0.0.1:1920/v1"）。
    # 直接用 [Uri] 解析时它会把首个 token 当 scheme → Host 为空、Port = -1，
    # 于是探测落到 80 端口并误报"离线"。（独立审查发现的真实缺陷，已回归验证）
    if ($Base -notmatch '^[a-zA-Z][a-zA-Z0-9+.\-]*://') { $Base = "http://$Base" }
    $result.Url = $Base
    try {
        $uri = [Uri]$Base
    } catch {
        $result.Detail = 'URL 无法解析'
        return [pscustomobject]$result
    }
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 80 }
    $result.Tcp = Test-TcpPort -TargetHost $uri.Host -Port $port -Timeout $Timeout
    if (-not $result.Tcp) {
        $result.Detail = "端口 $port 未监听（服务未启动？）"
        return [pscustomobject]$result
    }
    $timeoutSec = [Math]::Max(1, [int]($Timeout / 1000))
    $root = $Base.TrimEnd('/')
    $origin = "{0}://{1}:{2}" -f $uri.Scheme, $uri.Host, $port
    # 依次尝试：根路径 /health（多数推理服务的健康检查在这里）
    #            端点下 /health、端点下 /models（OpenAI 兼容面）
    foreach ($candidate in @("$origin/health", "$root/health", "$root/models")) {
        if (Get-HttpOk -Url $candidate -TimeoutSec $timeoutSec) {
            $result.Http = $true
            $result.Detail = "HTTP 200: " + $candidate.Replace($origin, '')
            return [pscustomobject]$result
        }
    }
    $result.Detail = '端口通、HTTP 探测失败（可能仍在装载）'
    return [pscustomobject]$result
}

# ---------------------------------------------------------------- 执行探测
Write-Host ''
Write-Host 'Agent Panel — 成员可用性探测' -ForegroundColor Cyan
Write-Host ('=' * 62)

$rows = New-Object System.Collections.ArrayList

# 宿主模型：永远在场
[void]$rows.Add([pscustomobject]@{
    成员 = '宿主模型'; 类型 = '当前会话'; 端点 = '(本进程)'; 状态 = '在线'; 备注 = '永远在场，担任裁判'
})

# CLI agent
$cliStatus = '离线'; $cliNote = '未找到可执行文件'
if ($OpenCodeCli -and (Test-Path -LiteralPath $OpenCodeCli)) {
    $cliStatus = '在线'; $cliNote = '可执行文件存在'
    try {
        $ver = & $OpenCodeCli --version 2>&1 | Select-Object -First 1
        if ($ver) { $cliNote = "可执行，版本输出: $ver" }
    } catch { $cliNote = '可执行文件存在，--version 未返回' }
} elseif ($OpenCodeCli) {
    $cliNote = "路径不存在: $OpenCodeCli"
}
[void]$rows.Add([pscustomobject]@{
    成员 = 'CLI agent'; 类型 = '云端免费模型'; 端点 = $(if ($OpenCodeCli) { $OpenCodeCli } else { '(未配置)' }); 状态 = $cliStatus; 备注 = $cliNote
})

# 本地端点
$idx = 0
foreach ($ep in $LocalEndpoints) {
    $idx++
    $probe = Test-LocalEndpoint -Base $ep -Timeout $TimeoutMs
    $status = if ($probe.Http) { '在线' } elseif ($probe.Tcp) { '半在线' } else { '离线' }
    [void]$rows.Add([pscustomobject]@{
        成员 = "本地端点 $idx"; 类型 = 'OpenAI 兼容'; 端点 = $probe.Url; 状态 = $status; 备注 = $probe.Detail
    })
}

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$online = @($rows | Where-Object { $_.状态 -eq '在线' })
Write-Host ('=' * 62)
Write-Host ("在线成员：{0} 名（含宿主模型）" -f $online.Count)

if ($online.Count -ge 3) {
    Write-Host '建议阵容：CLI agent + 本地模型 + 宿主模型（三票），可以开面板。' -ForegroundColor Green
    exit 0
} elseif ($online.Count -eq 2) {
    Write-Host '建议阵容：两票也能开会，但"共识"的说服力下降，报告里要注明只有两个独立来源。' -ForegroundColor Yellow
    exit 0
} else {
    Write-Host '只有宿主模型在线 —— 不建议开面板：先把至少一个本地模型或用 CLI agent 拉起来。' -ForegroundColor Red
    exit 1
}
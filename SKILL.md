---
name: agent-panel
description: Dispatch one question (or one code review) to multiple independent AI brains at once and aggregate their answers — a CLI coding agent on free cloud models, one or more local OpenAI-compatible endpoints, and the host model itself as a panel member. Produces a consensus / unique-findings / contradictions report instead of a single answer. Use when the user says "问面板", "让其他agent回答", "多模型交叉", "ask the panel", "帮我找个第二意见", "second opinion", or when a question is open-ended, high-stakes, or the user doubts an answer and wants independent perspectives.
---

# Agent Panel — 多脑会诊面板

You are the **panel chair**: you collect the question, poll the members, answer the
question yourself as one member, then aggregate.

The point is not "more words". It is **independent perspectives + a written record of
where they disagree**. See `README.md` for the design rationale.

## 0. Configuration

Resolve configuration in this order (first hit wins):

1. `panel.yml` next to this file (copy from `panel.example.yml`)
2. environment variables (`PANEL_OPENCODE_CLI`, `PANEL_LOCAL_A`, `PANEL_LOCAL_B`, …)
3. the defaults in the table below

Everything machine-specific (paths, ports, model IDs, timeouts) lives in that config.
**Never hardcode a personal path into a panel run.**

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `opencode.cli_path` | `<OPENCODE_CLI>` | CLI coding agent 可执行文件（如 OpenCode） |
| `opencode.model` | `<FREE_MODEL_ID>` | 免费模型 ID，**会轮换**，用 `models` 子命令重新拉取 |
| `local_a.url` | `http://127.0.0.1:1920/v1` | 本地端点 A（通常是小模型，快） |
| `local_a.model` | `<LOCAL_MODEL_A>` | 例如某个 7B/9B 量化模型 |
| `local_b.url` | `http://127.0.0.1:1919/v1` | 本地端点 B（通常是大模型，慢但稳） |
| `local_b.model` | `<LOCAL_MODEL_B>` | 例如某个 30B+ MoE 模型 |
| `timeouts.opencode_s` | `180` | CLI agent 超时 |
| `timeouts.local_s` | `300` | 本地模型超时 |
| `privacy.cloud_allowed` | `true` | 设为 `false` 则剔除所有云端成员 |
| `worker.home` | `<WORKER_HOME>` | 一次性工人实例的独立 HOME（隔离配置） |
| `worker.patch` | `<WORKER_PATCH>` | 工人用的模型/端点 patch 文件 |

## Panel roster & probes

| 成员 | 大脑 | 调用方式 | 可用性探测 |
|---|---|---|---|
| CLI agent | 免费云端模型 | `<OPENCODE_CLI> run "<问题>"` | 直接跑，失败即缺席 |
| 本地 A | 小模型（快，零成本） | `POST <local_a.url>/chat/completions`，body 见下 | 先 GET `/health`，不通则缺席 |
| 本地 B | 大模型（慢，更准） | `POST <local_b.url>/chat/completions` | 先 GET `/health` |
| 宿主模型 | 当前会话模型 | 直接作答 | 永远在场 |

**探测脚本**：`scripts/panel-probe.ps1` 会一次性输出上面这张表的实时状态
（在线/离线/缺席原因），跑一次比逐个手测省事：

```powershell
pwsh -File scripts/panel-probe.ps1 -Config panel.yml
```

本地端点请求体模板（**两个提速要点**）：

```json
{
  "model": "<LOCAL_MODEL_A>",
  "messages": [{"role": "user", "content": "<问题>"}],
  "temperature": 0.3,
  "max_tokens": 2048,
  "stream": false,
  "chat_template_kwargs": {"enable_thinking": false}
}
```

- `enable_thinking: false`：思考型模型（Qwen3 系等）默认会先吐一大段思考，
  既慢又可能吃满 `max_tokens` 导致正文为空。**必须关**。
- 若端点不认 `chat_template_kwargs`，退化为在问题前加 `/no_think` 前缀。
- 若返回正文为空而 `reasoning_content` 很长 → 加大 `max_tokens` 重试一次。

换 CLI agent 的免费模型：先跑 `<OPENCODE_CLI> models` 拉列表，再用
`-m <provider>/<model>` 指定。**不要假设某个免费 ID 长期存在。**

## Protocol

1. **确认问题与阵容**。默认：CLI agent + 一个可用的本地模型 + 你自己（三票）。
   用户可点名增减。
2. **并行发起**：各成员用后台任务同时跑，别串行等。问题作为单个位置参数传递；
   含引号/换行的长问题先写入临时文件，再用 `--file` 附加或管道传入。
3. **缺席要报告**：谁超时/报错，明确列出，不静默吞掉（沉默的失败最贵）。
4. **汇总输出**（固定格式）：

```markdown
## 会诊结果
| 成员 | 结论一句话 | 状态 |
|---|---|---|
...
### 🤝 共识（多数成员一致）
### 🔵 独有观点（仅一家提出 — 最有价值的部分，逐条评估可信度）
### ⚠️ 矛盾点（成员互不相同 — 给出你的裁判意见和理由）
### 🏁 裁判总结（你综合后的最终答案）
```

**裁判纪律**：你自己也是一票，但**收敛结论时必须说明理由**，不能只按票数。
多数不等于正确；三票里两票同错是常见情况（尤其两个本地模型同源同基座时，
它们的"共识"信息量很低——这一点必须在报告里点明）。

## 人肉成员协议（GUI-only 应用）

有些成员的宿主是**只有图形界面、没有 CLI** 的应用（如各类桌面 AI 助手）。
永远不要试图用自动化去驱动它们的窗口——脆弱、易被封、且不可靠。启用时：

1. 生成**会诊问题卡**（下面模板，替换占位符后放进一个代码块方便用户整块复制）：

```
【面板会诊 · 独立作答】
请独立回答，不要迎合任何主流观点，不知道就明说。
问题：<原始问题>
约束/背景：<可选，如目标平台 STM32F103 / 裸机 / FreeRTOS>
严格按此格式输出：
## 结论（一句话）
## 要点（最多5条，每条附一句理由）
## 风险与坑
## 置信度（高/中/低 + 一句原因）
```

2. 用户粘回各成员回答（文本或截图均可，截图用图像读取能力解析）后，
   说"面板齐了/汇总"时执行聚合：把 2-5 票统一填入会诊表
   （共识/独有/矛盾/裁判总结），GUI 成员与 CLI 成员**同等对待**。
3. 若某成员回答不符合模板格式，**先自行结构化提取再入表**，不要要求用户重问。

## 委托模式（宿主当指挥官，CLI agent 当工人）

CLI coding agent 自带读写/终端工具，可承接整个子任务。已验证的调用契约：

```powershell
$oc = "<OPENCODE_CLI>"
Set-Location <工作目录>          # CLI agent 以此目录为工地
& $oc run --auto -m <FREE_MODEL_ID> "<任务书>"   # --auto 放行工具权限
```

### 任务书模板（写清楚四点，工人不猜需求）

```
目标：<一句话说明要产出什么>
范围：<涉及的文件/目录，明确"只动这些">
验收标准：<怎么算做对了，如"编译通过"/"测试 X 变绿">
输出要求：改完在回复里三行内总结改动点；每处修改加 // NOTE: 注释
```

### 指挥官纪律

1. **派活前先侦察**：确认目录存在、确认任务边界；不要让工人碰你正在编辑的文件
   （防写冲突）。
2. **后台运行 + 超时**：真实任务要几分钟，用后台任务发起，超时给足（≥5 分钟）。
3. **验收必做**：工人交活后，指挥官亲自读改动文件核对（read/diff），
   **不轻信它的自我总结**——即使它历史汇报一直准确，纪律也是每次都验。
4. **追问用会话**：同一任务的多轮跟进用 `run --continue`（或 `-s <session-id>`），
   保持工人记忆连续；换任务开新会话，别 `--continue`。
5. **并行分包**：互不相干的子任务可以并行派多个 `run`（不同目录或不同会话）。
   汇总验收由指挥官负责。
6. **失败降级**：连续两次超时/报错，收回任务自己干，把中间产出当参考素材。
7. **模型回退链**：指定的免费模型 ID 失效时（免费期结束会从列表移除），
   重新拉取列表 → 按你配置的回退顺序换 → **并在交付报告里告知用户换了模型**。

### 适用任务画像

✅ 适合：单仓库代码修复/重构/写测试/批量机械改动/文档生成
⚠️ 不适合：跨多仓库架构决策（指挥官自己干）、需要视觉审美的 UI（用专门的设计技能）、
涉及密钥隐私的活儿（云端工人走公网）

## 一次性工人模式（强脑指挥弱脑，零 API 成本）

用一个**一次性宿主实例**当廉价工人：指挥官 = 当前会话的大模型，
工人 = 独立 profile + 本地小模型。

```powershell
# 前置：本地小模型已在跑
$env:<HOST>_HOME = "<WORKER_HOME>"      # 工人独立门户，隔离主设置劫持（关键！）
$env:<HOST>_API_KEY = "local"           # 占位 key，本地服务不校验
& <host-cli> --profile headless --patch "<WORKER_PATCH>" "<任务书>"
```

- 任务书同样用四点模板（目标/范围/验收标准/输出要求）。
- 工人沙箱通常较严：写工作区外文件可能被拒，随后自行降级为"只报结果"。
  派活时优先让它把产出写到自己的工作目录，或接受纯文本返回由指挥官落盘。
- 换更大模型当工人：复制一份 patch，把端点/模型 ID 改掉即可
  （**注意两个本地模型的显存可能互斥**）。
- 工人能力定位：小模型适合机械批量活（统计/格式化/模板化转换/初筛）；
  需要多步工具编排的硬活派给云端 CLI agent；**判断与验收永远归指挥官**。

### 成本路由模型

真正要省的不是"钱"这一项，而是**时间 + GPU + 配额**三者中的稀缺项：

- 高 token 量的粗活 → 本地工人（只花电费）或云端免费额度
- 需要判断力的细活 → 指挥官自己（用最强的脑子）
- 敏感材料 → 只走本地成员，云端成员一律剔除

按这个模型路由，而不是按"哪个更便宜"一刀切。

## Rules

- **GUI-only 的成员永远不要尝试驱动其窗口**（脆弱、不可靠、可能违反其条款）。
  用户点名要它们参加时，说明原因并改用问题卡 + 粘贴回传。
- **隐私闸门**：问题涉及敏感/私有材料（个人文件内容、密钥、未公开源码）时，
  剔除所有云端成员，只保留本地成员，并**主动向用户说明阵容变化**。
- **本地模型可能显存互斥**，同一时刻通常只有一个在线——探测即可，
  不要替用户启动/停止服务；提示他用自己惯用的方式拉起。
- **面板是"花更多算力买视角"**：简单事实题别动用面板，直接回答；
  开放题、方案题、疑难 debug 才值得开会。
- **同源成员的共识要降权**：两个本地模型若出自同一基座/同一量化版本，
  它们的一致意见不能当作"独立验证"，只能当作"同一次推理的重复"。
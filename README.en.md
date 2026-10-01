# agent-panel · a multi-brain panel for AI agents

**English** | [中文](README.md)

> Throw one question at **several genuinely independent AIs at once**, then get back a report structured as **consensus / unique findings / contradictions** — instead of a single model's answer.
>
> Shipped as a portable **Agent Skill** (no code required to use it). Panel members can be: a CLI coding agent running free cloud models, one or more local OpenAI-compatible endpoints, the host model itself, and optionally GUI-only apps bridged by a human. One optional PowerShell probe script is included.

**Why it exists**: when a single model answers, you cannot tell whether it *reasoned* its way there or just *sounded* confident. The value of a panel is not "more words" — it is **putting the disagreements on the record**. Disagreement is usually where the real difficulty hides.

---

## 1. The problem: three failure modes of a single model

| Failure mode | What it looks like | Why you can't catch it yourself |
|---|---|---|
| **Confident error** | Assertive tone, wrong details | Asking the same model three times returns the same mistake — same weights, same bias |
| **Single perspective** | Answers only from the angle it likes best | You cannot know *which* angle you failed to consider |
| **No self-check** | You suspect the answer is wrong but have nothing to compare against | Without an independent source, your suspicion can be neither confirmed nor dismissed |

So you want a second opinion. But doing it by hand is tedious: three windows, three pastes, and you must remember who said what and where they diverged. **A process that is annoying will not actually get run.**

This skill turns "get a second opinion" from a vague intention into a **repeatable procedure with a fixed output format**.

## 2. Core ideas

### 2.1 Independence is the whole point

Not "the same model asked three times", but **different model families from different sources**:

```
free cloud model (vendor A)  ←→  local model (different base/quant)  ←→  host model (the one you're using)
```

⚠️ **Consistency between same-origin members must be downweighted.** If two local models come from the same base model and the same quantization, their agreement is *not* independent verification — it is the same inference repeated. This rule is written into the skill because it is the easiest place for a panel to fool itself: **you think you got three-way confirmation, but you only got an echo.**

### 2.2 A fixed output format so disagreements cannot hide

Every aggregation fills the same four sections (fixed, so you never get "lots of text, no conclusion"):

```markdown
## Panel result
| Member | One-line conclusion | Status |
### 🤝 Consensus (majority agreement)
### 🔵 Unique findings (raised by only one member — the most valuable part; rate confidence per item)
### ⚠️ Contradictions (members disagree — give your ruling and the reason)
### 🏁 Chair's summary (your synthesized answer)
```

### 2.3 Why "unique findings" is the most valuable section

Consensus is usually what you already knew. Three models agreeing that "memory safety matters" carries zero information.

What actually changes a decision is typically **the one thing only a single member raised, and which can be verified**:

> Example: in one session, only the chair pointed out that *KV cache cost depends on whether the model uses hybrid state layers*. That reframed the whole debate from "make it big or small" to "first determine the architecture" — **the question itself changed.**

Hence this section requires a **confidence rating per item**, not a flat list.

### 2.4 The chair must be you — and must not merely count votes

The host model is both a player and the judge, so extra discipline is required:

- When converging, **state your reasoning**; do not just tally votes.
- **Majority does not mean correct** — two of three members being wrong together is common.
- The report must state **how many genuinely independent sources participated** (absences and same-origin members must be disclosed).

## 3. Architecture

```
                    ┌──────────────────────────────┐
        question ──▶│   Panel chair (host model)    │
                    │   1. probe roster             │
                    │   2. dispatch in parallel     │
                    │   3. answer as one member     │
                    │   4. aggregate & rule         │
                    └───────┬──────────┬───────────┘
                            │          │
        ┌───────────────────┘          └────────────────────┐
        ▼                          ▼                        ▼
┌────────────────┐        ┌────────────────┐      ┌──────────────────┐
│ CLI coding     │        │ local endpoints │      │ GUI-only apps     │
│ agent          │        │ (OpenAI-compat) │      │ (human bridge)    │
│ free cloud LLM │        │ small / large    │      │ user copy-paste   │
└────────────────┘        └────────────────┘      └──────────────────┘
        │                          │                        │
        └──────────────┬───────────┴────────────────────────┘
                       ▼
              ┌──────────────────┐
              │ probe: roster     │  ← scripts/panel-probe.ps1
              │ absence reported  │
              └──────────────────┘
```

**Member types**

| Type | How it is called | Integration cost |
|---|---|---|
| Local OpenAI-compatible endpoint | HTTP `POST /chat/completions` | Lowest — almost every local inference server exposes this |
| CLI coding agent | subprocess `run "<question>"` | Medium — needs a non-interactive CLI |
| GUI-only app | **human bridge** (question card + paste back) | Needs the user, but zero automation |
| Host model | answer directly | Zero |

## 4. Quick start

```bash
# 1. Drop the skill into your host's skills directory (the format is portable across agent hosts)
git clone https://github.com/niuyiming87-pixel/agent-panel.git ~/.dsh/skills/agent-panel

# 2. Copy the config and point it at your paths / ports / model IDs
cp panel.example.yml panel.yml

# 3. Probe the roster before the meeting (avoids "I assumed it was online")
pwsh -File scripts/panel-probe.ps1 -Config panel.yml
```

Then, in conversation:

```
ask the panel: <your question>
```

A sample run is in [`examples/sample-session.md`](examples/sample-session.md).

**Probe exit codes**: `0` = panel is viable (≥2 members online); `1` = host model only, don't bother.

## 5. Design trade-offs (the interesting part)

### 5.1 Why three votes by default, not every member?

Each additional member has diminishing returns and linear cost (time, compute, and *your own reading effort*). **Three independent sources** are usually enough to fill consensus / unique / contradictions; a fourth mostly echoes the most verbose of the first three. The roster is user-controllable — **conservative default, no ceiling on capability.**

### 5.2 Why keep a slot for a *small* local model?

It is often "not smart enough", and that is exactly why it is useful:

- It represents **a different common failure mode** — putting it into the contradictions section exposes where the concepts get muddled.
- It is free and fast: good for triage and mechanical bulk work.
- It is **offline** — the only place private material can go.

**Use it for what it is good at, instead of demanding it be as smart as the big model.**

### 5.3 Why "absences must be reported"

**Silent failure is the most expensive kind.** If a member timed out and its name is missing from the report, readers assume *everyone* saw the question — and a three-vote report gets read as five-vote certainty. This rule promotes probing from an afterthought into a step of the procedure.

### 5.4 Why GUI-only apps are bridged by a human instead of automated

We evaluated automating GUI apps and rejected it. Recording why, for whoever comes next:

| Approach | Why not |
|---|---|
| Synthetic clicks/keystrokes | Breaks the moment a window moves; dies completely across resolutions |
| Screenshot + OCR button hunting | Two layers of uncertainty; on failure you cannot tell "it didn't answer" from "I read it wrong" |
| Injecting / debug interfaces | Depends on undocumented internals, breaks on updates, may violate the app's terms |

**Asking the user to paste once costs 5 seconds. Automation costs long-term maintenance plus unreliability.** This is a case of engineering judgement beating technical showing-off: **the dumb approach that runs reliably beats the clever one that breaks.**

### 5.5 Cost routing: the scarce resource is not always money

The common mistake is "free is cheapest". Route by scarcity instead:

| Workload | Route to | Scarce resource consumed |
|---|---|---|
| High-token bulk work (counting, formatting, batch conversion) | local model or free cloud tier | electricity + time |
| Work needing judgement | host model (the strongest brain you have) | quota / attention |
| Anything private | **local members only** | VRAM + time (acceptable) |

Route by "which resource is tightest", not by "which one doesn't cost money".

### 5.6 The privacy gate is a hard switch

When the question touches personal files, unpublished source, or anything key-related: **drop every cloud member, keep local ones only** — and **tell the user the roster changed**. Never let a member silently disappear (that would be silent failure again).

### 5.7 Why the config only supports flat `key: value`

`panel.example.yml` deliberately parses only flat keys (no nesting, no lists). Rationale: **config complexity turns directly into usage friction.** This skill only needs five things changed — paths, ports, model IDs, timeouts, privacy switch — which one regex can read. No YAML library, no install step. **If 20 lines will do, don't pull in 200.**

### 5.8 Why a separate probe script

Probe logic (TCP connect + root `/health` + `/v1/models` fallback + bypassing the system proxy) left inside the skill text would have to be re-derived by the model on every run, and would frequently be derived wrong. Frozen into a script it becomes:

- **Deterministic**: results in 30 seconds, and the model cannot "skip" probing.
- **Reusable**: humans can run it directly.
- **Honest about state**: it distinguishes "offline" from "half-online — port open but HTTP failing, probably still loading".

## 6. Known limitations (honest list)

1. **A panel is not a voting machine.** Majority opinion is not correctness, and agreement between same-origin models means nothing. The output is *decision material*, not a verdict.
2. **It costs a multiple.** One panel run ≈ 3× the inference plus your reading time. Don't use it for factual lookups.
3. **Free model IDs rotate.** The IDs in the example config are placeholders; when a free window closes you must re-list models. This is why the skill mandates a fallback chain **and** reporting which model actually answered.
4. **Small local models have shallow knowledge.** Verify factual claims yourself; their job is perspective and triage.
5. **Passing long questions to subprocesses is fiddly** — quotes and newlines get truncated. The skill's workaround is: write the question to a temp file first, then pass it in.
6. **Platform differences**: the probe script is PowerShell (verified on Windows PowerShell 5.1). On Linux/macOS you need PowerShell 7+, or rewrite it as ~30 lines of shell.
7. **Keep `.ps1` files UTF-8 *with* BOM** (we hit this ourselves): PowerShell 5.1 parses BOM-less UTF-8 as the system ANSI codepage (GBK on Chinese Windows), so Chinese comments turn to mojibake and you get a cascade of nonsense syntax errors (`Unexpected token` / missing string terminator). The BOM is **committed inside the file on purpose** — `.gitattributes`' `working-tree-encoding` only applies on `git clone`, while GitHub's *Download ZIP* would drop it. Verify after editing:

   ```powershell
   $b = [IO.File]::ReadAllBytes('scripts/panel-probe.ps1')[0..2]
   ($b | ForEach-Object { $_.ToString('X2') }) -join ' '   # must be EF BB BF
   ```

## 7. Porting to another host

`SKILL.md` uses the generic Agent Skills shape (YAML frontmatter + Markdown body), so any host that loads instruction/skill files can use it; the core logic is host-agnostic.

Only three things need adjusting:

1. **Where skills live** (differs per host)
2. **Who "the host model" is** (just name it truthfully in the report)
3. **Image-reading ability** (needed when a GUI member returns a screenshot)

## 8. Repository layout

```
agent-panel/
├── SKILL.md                  # the skill itself (sanitized, portable)
├── README.md                 # design rationale (Chinese)
├── README.en.md              # design rationale (English) ← you are here
├── panel.example.yml         # config template (flat key: value)
├── scripts/
│   └── panel-probe.ps1       # member availability probe
├── examples/
│   └── sample-session.md     # redacted sample run
├── LICENSE                   # MIT
├── .gitattributes            # EOL policy + why the BOM lives in the file
└── .gitignore                # excludes panel.yml / secrets / logs
```

## 9. Contributing

Especially welcome: new member-type adapters (anything callable non-interactively), better aggregation protocols, and **field reports of when this skill made things worse** — that last category is the most valuable.

## 10. License

MIT © 2026 [niuyiming87-pixel](https://github.com/niuyiming87-pixel)

---

> **One-line design principle**: a tool's value is not how much technology it uses, but **whether it actually gets run — and whether it puts the disagreement in front of you at the moment it matters.**
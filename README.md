<!-- This is the source of truth. README.zh-CN.md is the Chinese translation. Keep both in sync. -->

**English** | [中文](./README.zh-CN.md) | [Codex Branch](https://github.com/Hydraallen/claude-code-config/tree/codex) | [Changelog](./CHANGELOG.md)

# Awesome Claude Code Configuration

![Statusline](assets/statusline.png)

Production-ready configuration for [Claude Code](https://claude.com/claude-code). One-command install of global instructions, multi-language coding rules (Python / TypeScript / Go), 24 curated plugins across 10 marketplaces, seven bundled skills (plus the `image-gen` Skill from `sinedied/agent-skills`, installed via npx), a gradient status bar, and a self-improvement loop that remembers corrections across sessions.

## Showcase

![Claude Code Demo](images/claude-code-demo.png)

- [paper-reading skill — *Attention Is All You Need*](docs/Attention_Is_All_You_Need.md)
- [adversarial-review skill — worked example](docs/adversarial-review-showcase.md)

## Quick Start

**macOS / Linux**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.sh)
```

**Windows (PowerShell)**:

```powershell
irm https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.ps1 | iex
```

Launches a two-level interactive selector. Append `--all` / `-All` to skip the menu and install everything non-interactively. Other flags: `--dry-run`, `--uninstall`, `--version` (PowerShell: `-DryRun`, `-Uninstall`, `-Version`).

```
  > [5/5] Core                   Global instructions, settings, rules...
    [0/3] Language Rules          Python / TypeScript / Go
    [1/3] Review                  code-review (adversarial-review opt-in)
    [8/8] Workflow                karpathy, superpowers, update-config...
    [3/3] Integrations            context7, github, playwright
    [3/4] Design & Content        document-skills, example-skills, humanizer...
    [0/2] Slides                  frontend-slides, ppt-master
    [0/3] Memory & Lifestyle      claude-mem, claude-health, PUA
    [1/10] Academic Research      paper-reading, deepxiv-cli...
    [1/2] MCP Servers             Playwright, Lark/Feishu (opt-in)
```

- **Main menu**: ↑↓ navigate groups, **Enter or →** open a group's sub-menu, **q** quit. Arrow to *Submit* and press Enter to install.
- **Sub-menu**: ↑↓ navigate items, **Space** toggle, **← or Esc** back to main menu (same as pressing Enter on *[ Back ]*).
- Shortcuts (any level): **a** all on, **n** all off, **d** defaults; in sub-menus these only affect that group.
- The Review group's `adversarial-review` and `codex` are mutually exclusive — selecting one deselects the other.

**Core (5)** — foundational files, all on by default.

| Item | What It Does | Default |
|------|--------------|---------|
| CLAUDE.md | Global instructions template | on |
| settings.json | Smart-merged Claude Code settings | on |
| Common rules | `rules/common/` — coding style, git, security, testing | on |
| StatusLine | Gradient bars + Anthropic/GLM 5h quota (`hooks/statusline.sh`) | on |
| Lessons | `lessons.md` template + `SessionStart` hook | on |

**Language Rules (3)** — off by default, enable only what your projects use.

| Item | What It Does | Default |
|------|--------------|---------|
| Python rules | PEP 8, pytest, type hints, bandit | off |
| TypeScript rules | Zod, Playwright, immutability | off |
| Go rules | gofmt, table-driven tests, gosec | off |

**Review (3)** — `adversarial-review` and `codex` are mutually exclusive.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| **code-review** | claude-plugins-official (plugin) | Confidence-based PR code review | on |
| [**adversarial-review**](https://github.com/poteto/noodle/blob/main/.agents/skills/adversarial-review/SKILL.md) | bundled skill | Cross-model review (Skeptic / Architect / Minimalist lenses); requires the `codex` CLI | off |
| [**codex**](https://github.com/openai/codex-plugin-cc) | openai-codex (plugin) | Codex CLI-backed adversarial review | off |

**Workflow (8)** — planning, iteration, code quality, meta-config.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| [**andrej-karpathy-skills**](https://github.com/forrestchang/andrej-karpathy-skills) | karpathy-skills (plugin) | Karpathy coding guidelines: Think-First, Simplicity, Surgical, Goal-Driven | on |
| [**superpowers**](https://github.com/obra/superpowers) | claude-plugins-official (plugin, Essential) | Brainstorming, debugging, code review, git worktrees, plan writing | on |
| **feature-dev** | claude-plugins-official | Guided feature development | on |
| **ralph-loop** | claude-plugins-official | Automated iteration loop (session-aware REPL) | on |
| **commit-commands** | claude-plugins-official | Git commit / push / PR workflow | on |
| **code-simplifier** | claude-plugins-official | Code simplification and refactoring | on |
| **ecc** | ecc (Optional plugin; interactive default) | Everything Claude Code workflows and skills | on |
| [**update-config**](skills/update-config/) | bundled skill | `/update-config` — re-run installer from inside a session | on |

**Integrations (3)** — external tools and services.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| [**context7**](https://github.com/upstash/context7) | claude-plugins-official | Up-to-date library documentation lookup | on |
| [**github**](https://github.com/github/github-mcp-server) | claude-plugins-official | GitHub integration (issues, PRs, workflows) | on |
| [**playwright**](https://github.com/microsoft/playwright-mcp) | claude-plugins-official | Browser automation, E2E testing, screenshots | on |

**Design & Content (4)** — documents, UI, creative artifacts, text humanization.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| [**document-skills**](https://github.com/anthropics/skills) | anthropic-agent-skills | PDF, DOCX, PPTX, XLSX creation and manipulation | on |
| [**example-skills**](https://github.com/anthropics/skills) | anthropic-agent-skills | Frontend design, MCP builder, canvas, algorithmic art | on |
| [**humanizer**](https://github.com/blader/humanizer) | bundled skill | Remove AI writing patterns (English) | on |
| [**humanizer-zh**](https://github.com/op7418/Humanizer-zh) | bundled skill | Remove AI writing patterns (Chinese) | off |

**Slides (2)** — AI slide / PPTX generation, both off by default.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| [**frontend-slides**](https://github.com/zarazhangrui/frontend-slides) | frontend-slides | Zero-dependency HTML slide generator with PPT conversion and bold template styles | off |
| [**ppt-master**](https://github.com/hugohe3/ppt-master) | ppt-master | Editable PPTX from PDF/DOCX/URL/Markdown — real shapes & animations (run `pip install -r requirements.txt` post-install) | off |

**Memory & Lifestyle (3)** — session memory and personal productivity, all off by default.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| [**claude-mem**](https://github.com/thedotmack/claude-mem) | thedotmack | Persistent memory with smart search, timeline, AST-aware code search | off |
| [**claude-health**](https://github.com/tw93/claude-health) | claude-health | Health check & wellness dashboard for Claude Code sessions | off |
| [**PUA**](https://github.com/tanweai/pua) | pua-skills | AI agent productivity booster (CN / EN / JA) | off |

**Academic Research (11)** — training / inference plugins + paper-reading & cheatsheet-creator skills, off by default except `paper-reading` and `cheatsheet-creator`.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| [**paper-reading**](skills/paper-reading/) | bundled skill | Research paper summarization with figure extraction | on |
| [**cheatsheet-creator**](skills/cheatsheet-creator/) | bundled skill | Exam-ready cheatsheet from lectures / homework / past exams, weighted by exam frequency | on |
| [**tokenization**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | HuggingFace Tokenizers, SentencePiece | off |
| [**fine-tuning**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | Axolotl, LLaMA-Factory, PEFT, Unsloth | off |
| [**post-training**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | GRPO, RLHF, DPO, SimPO | off |
| [**inference-serving**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | vLLM, SGLang, TensorRT-LLM, llama.cpp | off |
| [**distributed-training**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | DeepSpeed, FSDP, Megatron-Core, Ray Train | off |
| [**optimization**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | AWQ, GPTQ, GGUF, Flash Attention, bitsandbytes | off |
| [**deepxiv-cli**](https://github.com/DeepXiv/deepxiv_sdk) | DeepXiv (GitHub) | arXiv/PMC paper search & reading CLI (hybrid BM25+Vector, 2M+ papers) | off |
| [**deepxiv-trending-digest**](https://github.com/DeepXiv/deepxiv_sdk) | DeepXiv (GitHub) | Markdown digests of trending papers (last 7 days) | off |
| [**deepxiv-baseline-table**](https://github.com/DeepXiv/deepxiv_sdk) | DeepXiv (GitHub) | Build baseline comparison tables from research papers | off |

**MCP Servers (2)** — non-plugin MCP integrations.

| Item | Source | What It Does | Default |
|------|--------|--------------|---------|
| **Playwright MCP** | `mcp/` | Browser automation via `@playwright/mcp` | on |
| [**Lark MCP server**](https://github.com/larksuite/lark-openapi-mcp) | `mcp/` | Feishu / Lark integration — opt-in; needs Feishu App ID/Secret and uses ~1 GB RAM/session. Walkthrough: [docs/LARK-MCP.md](docs/LARK-MCP.md) | **off** |

**Re-running the installer reconciles your plugins.** The plugin stage aligns *every* plugin installed on the machine with the selection you make this run: anything not selected is uninstalled — including third-party plugins you installed by hand — along with any marketplace no remaining plugin needs. Pass `--keep-foreign-plugins` (PowerShell: `-KeepForeignPlugins`) to limit reconciliation to this catalogue. Uninstalls are not reversible, so preview with `--dry-run` first. Selecting no plugins at all reconciles nothing.

## Model Backends — First-Run Setup

The installer writes `~/.claude/profiles/*.json`, but every backend except `claude` needs a login and/or a pasted credential before `cl_<backend>` will work. Full detail: [docs/BACKENDS.md](docs/BACKENDS.md).

| Backend | Install | Login | Where the credential goes |
|---------|---------|-------|---------------------------|
| `claude` | — | native OAuth | Nothing to configure |
| `glm` | — (vendor-hosted endpoint) | — | Your BigModel API key → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/glm.json` |
| `or` | — (vendor-hosted endpoint) | — | Your OpenRouter key (`sk-or-v1-…`) → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/or.json` |
| `gpt` | `brew install cliproxyapi` | `cli-proxy-api --codex-login` (one-time browser authorization) | An `api-keys` entry from `~/.cli-proxy-api/config.yaml` → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/gpt.json` |
| `ccr` | `npm install -g @musistudio/claude-code-router` (needs Node.js >= 22) | `ccr ui` — admin UI on `http://127.0.0.1:3458` | The CCR client key minted in the UI → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/ccr.json` |

- **`gpt` carries a real account-ban risk.** It reuses a consumer ChatGPT subscription through a reverse-engineered OAuth flow; read the full warning in [docs/BACKENDS.md](docs/BACKENDS.md#gpt--chatgpt-pluspro-subscription) before using it.
- **`ccr` cannot be automated.** CCR v3 keeps its configuration in SQLite, so the providers, the client key, and the agent profile have to be created by hand in the web UI — once.
- **`or` needs a `/logout` first.** A cached Anthropic OAuth session outranks the environment variables the profile injects, so run `/logout` inside Claude Code once before the first `cl_or` launch — otherwise the requests keep going to Anthropic.
- **`or` has no 5h quota bar** in the statusline, and OpenRouter has no 5h rolling window to show one for; the reason is spelled out in [docs/BACKENDS.md](docs/BACKENDS.md#quota-in-the-statusline). OpenRouter also only *guarantees* its native Anthropic endpoint for Anthropic first-party models, so the DeepSeek slots this profile ships are best-effort and have not been tested against a live key.
- **`gpt` and `ccr` are no longer selected by default** in the installer. They are still shipped in full: tick them in the "Model Backends" group to install them, `--all` still includes them, and an existing `~/.claude/profiles/gpt.json` / `ccr.json` is never removed by an upgrade.

Then `cl_glm` / `cl_or` / `cl_gpt` / `cl_ccr` launches that backend, and `cl_switch <name>` makes it the default for a bare `cl`. Every launch prints the backend and the model it resolved to. To pick a model without editing JSON, pass claude's own flag — `cl_glm --model glm-5v-turbo` — or set `CL_MODEL=sonnet` for one launch.

## Image Generation

The [`sinedied/agent-skills`:`image-gen`](https://github.com/sinedied/agent-skills) Skill is **always installed** over the network (never vendored), alongside a repository-owned wrapper at `~/.claude/scripts/image-gen-openrouter.py`. Every `cl*` / `cl_*_auto` launcher shares the same global `~/.claude/skills/` and `~/.claude/scripts/` paths, so image generation works from any backend — and needs no local proxy at all: the wrapper posts straight to `https://openrouter.ai/api/v1/images` with `openai/gpt-image-2`, verifying the model is listed by `GET /api/v1/images/models` before it generates and failing closed if it is not. The upstream `image_gen.py` is not executed (its OpenAI routes do not exist on OpenRouter); `edit` sends reference images on the same endpoint instead. It needs `python3` and nothing else. **Authentication is the OpenRouter key in `~/.claude/profiles/or.json` (`.env.ANTHROPIC_AUTH_TOKEN`) and nothing else** — no environment-variable fallback, never on the command line, and **no OpenAI Platform API key is needed or requested**. `--uninstall` removes the Skill only when an ownership manifest, layout, and augmentation markers all agree. Real PowerShell runtime behaviour was not verified here. Full contract: [docs/BACKENDS.md](docs/BACKENDS.md).

> **Upgrading from 2.x:** image generation now requires the OpenRouter backend. Tick "OpenRouter" during install and put a key from <https://openrouter.ai/keys> into `~/.claude/profiles/or.json`, or image generation will stop working. The old `image-gen-cliproxyapi.sh` wrapper is deleted automatically.

## Directory Structure

```
.
├── CLAUDE.md              # Global instructions
├── settings.json          # Permissions, plugins, hooks, model
├── lessons.md             # Self-correction log template (auto-loaded via hook)
├── rules/                 # Coding standards (common + python/typescript/golang)
├── hooks/                 # Statusline with gradient progress bars
├── mcp/                   # MCP server config (Playwright; Lark-MCP opt-in)
├── plugins/               # Plugin catalogue & install guide
├── skills/                # Bundled custom skills (vendored)
├── scripts/               # User scripts (image-gen-openrouter.py wrapper + helpers)
├── docs/                  # Paper summaries, showcases
└── install.sh / install.ps1
```

## Key Mechanisms

- **Layered rules** — `rules/common/` (universal) extended by per-language directories. Each file references a deeper skill for patterns, testing, security.
- **Statusline** — model, directory, venv, git branch, context window (gradient bar), and the 5-hour quota of whichever backend the terminal is on: native Anthropic or GLM, with backends that have no quota endpoint (`gpt`, `ccr`) simply omitting the segment. Script at `hooks/statusline.sh`; details in [docs/BACKENDS.md](docs/BACKENDS.md#quota-in-the-statusline).
- **Self-improvement loop** — corrections route to `~/.claude/lessons.md` (cross-project) or project `MEMORY.md` (local). `SessionStart` hooks re-inject them on startup and after context compaction.
- **Plugin catalogue & marketplace URLs** — full list with install commands: [plugins/README.md](plugins/README.md).

## Settings Defaults

`settings.json` ships with high-performance defaults. Unknown keys are ignored by older Claude Code; only `auto` mode is version-gated (installer auto-downgrades to `bypassPermissions` below 2.1.80).

| Key | Value | Effect |
|-----|-------|--------|
| `permissions.defaultMode` | `auto` | Auto-approve safe actions, block risky ones |
| `skipDangerousModePermissionPrompt` | `true` | Suppresses the warning prompt when using `auto` or `bypassPermissions` mode — remove this key if you want the safety prompt |
| `effortLevel` | `xhigh` | High reasoning effort tier |
| `tui` | `fullscreen` | Flicker-free alt-screen rendering |
| `env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | `1` | Fixed thinking budget (no effect on Opus 4.7) |

Smart merge on re-install preserves your overrides for `env`, `permissions.allow`, `enabledPlugins`, `hooks.SessionStart`, and `statusLine`. As of 3.1.0 the plugin stage additionally drops `enabledPlugins` keys that are neither selected this run nor installed, so third-party entries outside this catalogue are no longer left untouched — `--keep-foreign-plugins` keeps them.

## Customization

- **Add a language**: create `rules/<lang>/` extending `rules/common/`
- **Add a skill**: place in `skills/<name>/SKILL.md`
- **Adapt CLAUDE.md**: tune for your shell, package manager, project context

## Acknowledgements

- [Claude Code in Action](https://anthropic.skilljar.com/claude-code-in-action) — Anthropic Academy's official course
- [Working for 10 Claude Codes](https://mp.weixin.qq.com/s/9qPD3gXj3HLmrKC64Q6fbQ) by Hu Yuanming — multi-instance patterns
- [Harness Engineering](https://openai.com/index/harness-engineering/) by OpenAI
- [Anthropic Engineering](https://www.anthropic.com/engineering) / [OpenAI Engineering](https://openai.com/news/engineering/)
- [Claude Code Best Practice](https://github.com/shanraisshan/claude-code-best-practice) by shanraisshan
- [Claude How To](https://github.com/luongnv89/claude-howto) by luongnv89

## Fork-specific Features

This fork adds the following custom features on top of upstream:

- **Shell Wrapper** (`claude.zsh`): `cl`/`cl_auto`/`cl_switch`/`cl_profiles` plus a generated `cl_<backend>` per profile
- **Model Backends** (`profiles/*.json`): One JSON per backend — `claude` (native OAuth), `glm` (Zhipu Coding Plan), `gpt` (ChatGPT subscription via CLIProxyAPI), `ccr` (claude-code-router gateway that merges providers into a single `/model` list). Dropping a new JSON in `~/.claude/profiles/` adds a backend with no code changes; profiles that declare a local proxy start it on demand and reuse it if already healthy. See [docs/BACKENDS.md](docs/BACKENDS.md)
- **Search Agent** (`agents/search.md`): Jeff, a read-only web research specialist
- **System Prompt** (`system-prompt.txt`): Custom behavioral guidelines
- **MCP Playwright**: Playwright MCP server config preserved
- **Co-authored-by**: Interactive installer option for commit attribution

## License

MIT

<!-- Keep the user-facing tables aligned with catalog.md and README.zh-CN.md. -->

**English** | [中文](README.zh-CN.md) | [Changelog](CHANGELOG.md)

# Awesome Agent Config

![Claude Statusline](assets/statusline.png)

One repository for [Claude Code](https://claude.com/claude-code) and [Codex](https://developers.openai.com/codex/): global instructions, coding rules, plugins, shared skills, status lines and correction memory. This fork of [Mizoreww/awesome-agent-config](https://github.com/Mizoreww/awesome-agent-config) keeps two install paths: the script installers (`install.sh` / `install.ps1`, Claude Code only) and the upstream agent-guided setup, where your existing agent detects the platform, explains the options and installs your choices. It also adds a multi-backend launcher and OpenRouter image generation, and keeps the Lark/Feishu MCP that upstream retired.

## Showcase

![Claude Code Demo](images/claude-code-demo.png)

## Quick Start

### Option A — script installer (Claude Code)

**macOS / Linux**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.sh)
```

**Windows (PowerShell)**:

```powershell
irm https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.ps1 | iex
```

Launches a two-level interactive selector: 48 items in 11 groups, 30 of them on by default. On Windows, `install.ps1` offers 41 items in 10 groups; the model backends, shell wrapper, co-author and Matt skills are macOS/Linux only for now. Flags (PowerShell spelling in parentheses):

- `--all` (`-All`): skip the menu and install every item except the opt-in storage-analyzer. Additive: nothing is removed.
- `--only <ids>` (`-Only`): install just the listed menu items, comma-separated. Additive: nothing is removed, plugins are not reconciled, `enabledPlugins` is not rebuilt and the version stamp is not written.
- `--list-ids` (`-ListIds`): print every menu ID with its default and group.
- `--prune-foreign-plugins` (`-PruneForeignPlugins`): on an interactive run, also reconcile plugins the installer does not manage (see below).
- `--dry-run` (`-DryRun`), `--uninstall` (`-Uninstall`), `--force` (`-Force`), `--version` (`-Version`).

```
  > [7/8]  Core                  Global instructions, settings, writing-style rule, statusline...
    [2/4]  Model Backends        GLM, OpenRouter, ChatGPT (CLIProxyAPI), CCR
    [3/3]  Language Rules        Python / TypeScript / Go
    [1/3]  Review                code-review (adversarial-review / Codex opt-in)
    [10/11] Workflow             karpathy, superpowers, mattpocock, ecc, update-config, edit-config, neat-freak...
    [2/2]  Integrations          context7, playwright
    [3/5]  Design & Content      document-skills, example-skills, humanizer, humanizer-zh, lieflat-charts
    [0/2]  Slides                frontend-slides, ppt-master
    [0/1]  Storage               storage-analyzer
    [2/7]  Academic Research     paper-reading, cheatsheet-creator, AI Research, ResearchStudio, DeepXiv...
    [0/2]  MCP Servers           Playwright, Lark/Feishu (opt-in)
```

- **Main menu**: ↑↓ navigate groups, **Enter or →** open a group's sub-menu, **q** quit. Arrow to *Submit* and press Enter to install.
- **Sub-menu**: ↑↓ navigate items, **Space** or **Enter** toggle, **← or Esc** back to main menu.
- Shortcuts (any level): **a** all on, **n** all off, **d** defaults; in sub-menus these only affect that group.
- The Review group's `adversarial-review` and `codex` are mutually exclusive — selecting one deselects the other.

**Re-running the interactive installer: unchecked means removed.** The menu opens with what is already installed checked; anything not installed starts at its default, except items you unchecked on an earlier interactive run, which stay unchecked. Submitting it unchanged changes nothing. Every item you leave unchecked is removed on submit, but only what the installer put there:

- Plugins from the installer's catalogue (code-review and codex included) are uninstalled, and so are the marketplaces no remaining plugin needs (never `claude-plugins-official`). Plugins you installed yourself stay unless you pass `--prune-foreign-plugins`. Unchecking every plugin item uninstalls all catalogue plugins.
- Skills, language rules, the writing-style rule, DeepXiv skills, the search agent, the Matt skills and pinned upstream skills are deleted. A copy you edited is first moved to `~/.claude/agent-config/backups/<timestamp>-deselect/` (pinned upstream skills: `agent-config/backups/<id>/`), and the installer says so.
- The Playwright and Lark MCP servers are removed only when their command is the one the installer registers (`npx @playwright/mcp` / `npx @larksuiteoapi/lark-mcp`); a same-name server of your own is kept, with a warning.
- StatusLine removes the `statusLine` setting (only when it runs `~/.claude/hooks/statusline.sh`) and that script. Lessons removes the SessionStart hook and keeps `lessons.md`. Co-authored-by sets `includeCoAuthoredBy` to `false`.
- The launcher (Shell wrapper, with every model backend unchecked) removes `claude.zsh`, `system-prompt.txt` and a `source ~/.claude/claude.zsh` line in `~/.zshrc` that matches exactly (the rc file is backed up first; other forms get a warning). `profiles/` and `default-profile` hold your API keys and are always kept, also for an unchecked backend.
- CLAUDE.md and settings.json are never deleted; unchecking them only stops the installer from updating them.

`--all`, `--only` and a run without a terminal (for example `curl | bash` in CI) are additive: they install what they select and remove nothing. Removals cannot be undone, so preview with `--dry-run`, which lists every removal and every backup.

**Every run, additive ones included, removes retired items:** the github plugin, the old user-scope GitHub MCP server (only when it points at `api.githubcopilot.com/mcp/`), and the claude-mem and PUA plugins with their marketplaces, plus what those leave behind: their plugin caches and data directories, stale `plugins/cache/temp_git_*` clones older than an hour, their usage records in `~/.claude.json` (backed up first) and claude-mem's data directory `~/.claude-mem` (kept while a claude-mem process is running, or with `ACCC_KEEP_CLAUDE_MEM_DATA=1`). If you still use claude-mem, read the [migration note](docs/migration.md#removed-integrations) before upgrading. Each run records its selection in `~/.claude/agent-config/selection.json`, so `edit-config` can take over later.

### Option B — agent-guided setup (Claude or Codex)

This fork's release line is [Hydraallen/claude-code-config](https://github.com/Hydraallen/claude-code-config) on `main`. Coming from upstream Mizoreww/awesome-agent-config? The agent treats it as a different source and switches only when you ask; see the [migration notes](docs/migration.md#repository-identity). Items that only the script installer provides (model backends, launcher, co-author, search agent, image-gen) are installed by the agent with `install.sh --only <id>` after you confirm.

Open this checkout in Claude or Codex, or share **the URL of the repository page you are reading** along with the request below. Keep its branch/ref when sharing a branch page.

> Read INSTALL.md from the checkout or repository page I shared, using the same branch/revision as its README. Configure the agent I am talking to. Detect my OS, client and existing configuration. Directly in this conversation, list every option supported by this agent by category with continuous numbers, a useful description, author recommendations and installed status. Prefer native multi-select questions when available; otherwise let me choose multiple numbers or names in chat. Keep the choices in the conversation; do not generate a separate Markdown document or report. Install and verify my choices, preserving my customizations.

The agent shows only your target agent's supported options directly in the conversation, with useful descriptions and recommendations. If the client offers a real multi-select question tool, choose options by category there; otherwise reply with multiple numbers, names or a description of what you want. The agent respects the tool's actual limits and reuses choices you already made. A plugin bundle gets one number and lists its members; capabilities included in that bundle are not installed twice. Author recommendations follow the recorded legacy main/Codex installer defaults and subsequent changes, with [explicit mappings](catalog.md#recommendations). Recommendations do not select items for you.

For later changes, say “add paper-reading”, “update my previous selections” or “remove storage-analyzer”. Existing choices are reused; omitting an installed item never uninstalls it. Both agents use `edit-config` for configuration queries, additions, edits, removals, repairs and updates. It tracks this repository’s `main` branch. Queries are read-only; if the skill is absent, the global instructions link to the same workflow.

Native plugin/MCP commands are preferred; the agent chooses source installation when the documented scope or client requires it. You do not need to choose between npx, plugins and skill copies yourself. Codex setup disables external-agent auto-import so installations follow your selections. Windows and WSL are detected and configured separately; App/CLI installations sharing a home are reused.

For Codex, the agent checks the available OpenAI official/curated directory, then upstream Codex packages and verified compatible plugins. The [plugin guide](platforms/codex/plugins.md) records exact routes and limitations; official availability depends on the account and client. Existing equivalent capabilities are reused.

[Installation workflow](INSTALL.md) · [Claude operations](platforms/claude/README.md) · [Codex operations](platforms/codex/README.md) · [Full catalogue and bundle members](catalog.md)

## Catalogue

The tables retain the original categories and merge the Claude and Codex capabilities. Third-party originals are installed from their upstream sources; this repository stores author-owned and intentionally customized skills with attribution. Handoff belongs to the Matt bundle only. `—` means this repository does not offer that item for the agent. The agent hides those entries when presenting your choices. A platform cell marked **★** identifies an author recommendation for that agent. Items marked *(fork)* are specific to this fork; a Claude cell reading *Script installer* means only `install.sh` / `install.ps1` installs it. Exact routes, stable IDs and recommendation markers live in [catalog.md](catalog.md).

### Core

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **CLAUDE.md / AGENTS.md** | [Repository](platforms/claude/README.md#configuration) | Separate global instructions for each agent | Template ★ | Template ★ |
| **Base settings** | [Repository](platforms/codex/README.md#configuration) | Partially merge model, reasoning and runtime settings | Template ★ | Template ★ |
| **Permissions** | [Repository](platforms/codex/README.md#configuration) | Optional high-autonomy permissions for a user-selected trusted environment | Template ★ | Template ★ |
| **Writing style rule** | [Repository](platforms/claude/README.md#configuration) | Complete English writing requirements and examples; replaces the previous common rules | Rule ★ | — |
| **StatusLine** | [Repository](platforms/claude/README.md#configuration) | Claude gradient context/usage bar (Anthropic / GLM 5h quota) and fonts; Codex native footer | Template ★ | Template ★ |
| **Lessons** | [Repository](platforms/codex/README.md#configuration) | Independent blank global logs and memory routing; preserve real corrections | Template ★ | Template ★ |
| **Search agent** *(fork)* | [Repository](agents/search.md) | Jeff, a read-only web research agent | Script installer ★ | — |
| **Shell wrapper** *(fork)* | [Repository](docs/BACKENDS.md) | `cl` / `cl_auto` / `cl_switch` launchers plus a `cl_<backend>` per profile and a custom system prompt | Script installer ★ | — |
| **Co-authored-by** *(fork)* | Repository | Add Claude as co-author in commits | Script installer | — |

### Model Backends *(fork)*

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **GLM Coding Plan** | [Repository](docs/BACKENDS.md) | Zhipu BigModel Anthropic-compatible endpoint, launched with `cl_glm` | Script installer ★ | — |
| **OpenRouter** | [Repository](docs/BACKENDS.md) | OpenRouter Anthropic-compatible endpoint, launched with `cl_or`; its key also serves image-gen | Script installer ★ | — |
| **ChatGPT via CLIProxyAPI** | [Repository](docs/BACKENDS.md) | Reuse a ChatGPT Plus/Pro subscription with `cl_gpt`; carries an account-ban risk | Script installer | — |
| **CCR gateway** | [Repository](docs/BACKENDS.md) | claude-code-router: GLM and GPT in one `/model` list with `cl_ccr`; manual web-UI setup | Script installer | — |

### Language Rules

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **Python rules** | [Repository](platforms/claude/README.md#configuration) | PEP 8, pytest, type hints and bandit | Template | — |
| **TypeScript rules** | [Repository](platforms/claude/README.md#configuration) | Zod, Playwright and immutability | Template | — |
| **Go rules** | [Repository](platforms/claude/README.md#configuration) | gofmt, table-driven tests and gosec | Template | — |

### Review

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **Claude code-review** | [Anthropic](https://github.com/anthropics/claude-plugins-official) | Confidence-based pull request review | Native plugin ★ | — |
| **Matt code-review** | [Matt Pocock](https://github.com/mattpocock/skills) | Separate Standards and Spec reviews; a standalone choice on Codex, not part of this fork's Claude Matt subset | — | Selected source ★ |
| **adversarial-review** | [poteto/noodle](https://github.com/poteto/noodle/blob/main/.agents/skills/adversarial-review/SKILL.md) | Cross-model review through Skeptic, Architect and Minimalist lenses | Bundled skill ★ | — |
| **codex-in-claude** | [OpenAI](https://github.com/openai/codex-plugin-cc) | Call Codex CLI from Claude; choose alongside review tools according to need | Native plugin | — |

### Workflow

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **andrej-karpathy-skills** | [Karpathy skills](https://github.com/forrestchang/andrej-karpathy-skills) | Think before coding, keep changes focused, define verifiable outcomes | Native plugin ★ | Plugin / source ★ |
| **superpowers** | [obra / OpenAI curated](https://github.com/obra/superpowers) | Brainstorming, debugging, TDD, worktrees and planning; 14-skill bundle | Native plugin | Plugin / source |
| **mattpocock-skills** | [Matt Pocock](https://github.com/mattpocock/skills) | Planning, TDD, research, grilling and delivery; this fork's Claude install is a 6-skill subset, Codex 20 selected v1.1.0 skills, including handoff | Selected source ★ | Selected source ★ |
| **neat-freak** | [khazix-skills](https://github.com/KKKKhazix/khazix-skills/tree/2b4a645cfdc894156ae347d897723562f719ce95/neat-freak) | Reconcile project docs, agent rules, authorized memory and workspace residue | Upstream install ★ | Upstream install ★ |
| **feature-dev** *(fork)* | [Anthropic](https://github.com/anthropics/claude-plugins-official) | Guided feature development | Native plugin ★ | — |
| **ralph-loop** *(fork)* | [Anthropic](https://github.com/anthropics/claude-plugins-official) | Automated iteration loop | Native plugin ★ | — |
| **commit-commands** *(fork)* | [Anthropic](https://github.com/anthropics/claude-plugins-official) | Git commit / push / PR workflow | Native plugin ★ | — |
| **ecc** *(fork)* | [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) | TDD, security, database and language workflows | Native plugin ★ | — |
| **code-simplifier** | [Anthropic](https://github.com/anthropics/claude-plugins-official) | Code simplification and refactoring agent | Native plugin ★ | — |
| **edit-config** | [Repository](skills/edit-config/SKILL.md) | Inspect and manage configuration on main; shared by both agents | Bundled skill ★ | Bundled skill ★ |
| **update-config** *(fork)* | [Repository](skills/update-config/SKILL.md) | `/update-config` — re-run the script installer from inside a session | Bundled skill ★ | — |

### Integrations

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **context7** | [Upstash](https://github.com/upstash/context7) | Up-to-date library documentation lookup | Native plugin ★ | Plugin / MCP ★ |
| **playwright** | [Microsoft](https://github.com/microsoft/playwright-mcp) | Browser automation, E2E testing and screenshots; Codex MCP pinned to 0.0.78 | Native plugin ★ | MCP ★ |

### Design & Content

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **document-skills** | [Anthropic](https://github.com/anthropics/skills) | PDF, DOCX, PPTX and XLSX creation and editing; reuse equivalent built-in Codex tools | Native plugin ★ | Built-in / compatible plugin / source ★ |
| **example-skills** | [Anthropic](https://github.com/anthropics/skills) | Claude: 12 examples; Codex: canvas-design, algorithmic-art and mcp-builder | Native plugin ★ | Selected source ★ |
| **humanizer** | [blader](https://github.com/blader/humanizer) | Remove mechanical AI writing patterns in English; on Claude the `humanizer@humanizer` plugin, called as `/humanizer:humanizer` (Claude Code 2.1.142 or later) | Plugin / source ★ | Upstream install ★ |
| **humanizer-zh** | [op7418](https://github.com/op7418/Humanizer-zh) | Remove mechanical AI writing patterns in Chinese | Upstream install | Upstream install |
| **lieflat-charts** | [lieflat-charts](https://github.com/larashero3-dotcom/lieflat-charts) | Lupi / Basics / Glance / Maps HTML galleries and 12 bilingual report templates; source excludes preview media; noncommercial use only | Selected source | — |
| **image-gen** *(fork)* | [sinedied/agent-skills](https://github.com/sinedied/agent-skills) | Image generation through OpenRouter; always installed by the script installer | Script installer | — |

### Slides

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **frontend-slides** | [zarazhangrui](https://github.com/zarazhangrui/frontend-slides) | Zero-dependency HTML slide generation with PPT conversion and varied styles | Native plugin | Compatible plugin / source |
| **ppt-master** | [hugohe3](https://github.com/hugohe3/ppt-master) | Editable PPTX from PDF / DOCX / URL / Markdown, with shapes and animations; runtime setup on first use | Native plugin | Selected source |

### Storage

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **storage-analyzer** | [khazix-skills (modified)](https://github.com/KKKKhazix/khazix-skills/tree/fcba3adcf5def1ccd4bb688de93060227471b129/storage-analyzer) | Read-only disk analysis and an interactive HTML report with guarded cleanup; includes Linux support and security fixes | Bundled skill | Bundled skill |

### Academic Research

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **paper-reading** | [Repository](skills/paper-reading/) | Research paper reading, figure extraction, evidence checks and HTML reports | Bundled skill ★ | Bundled skill ★ |
| **cheatsheet-creator** *(fork)* | [Repository](skills/cheatsheet-creator/) | Exam-ready cheatsheet from lectures, homework and past exams | Bundled skill ★ | — |
| **AI Research skills** | [AI Research](https://github.com/Orchestra-Research/AI-research-SKILLs) | One bundle: tokenization, fine-tuning, post-training, inference, distributed training and optimization; [the same 31 members on both agents](catalog.md#ai-research-members) | 6 native plugins | 6 compatible plugins / source |
| **deepxiv-cli** | [DeepXiv](https://github.com/DeepXiv/deepxiv_sdk) | arXiv / PMC hybrid paper search and reading CLI | Selected source | Selected source |
| **deepxiv-trending-digest** | [DeepXiv](https://github.com/DeepXiv/deepxiv_sdk) | Markdown digests of recently trending papers | Selected source | Selected source |
| **deepxiv-baseline-table** | [DeepXiv](https://github.com/DeepXiv/deepxiv_sdk) | Baseline comparison tables grounded in research papers | Selected source | Selected source |
| **ResearchStudio Idea** | [Microsoft](https://github.com/microsoft/ResearchStudio) | idea_spark, paper_search and scoop_check; complete source, first-use dependencies | Selected source | Selected source |
| **ResearchStudio Reel** | [Microsoft](https://github.com/microsoft/ResearchStudio) | paper2assets, paper2poster, paper2video, paper2blog and paper2reel; independently selected | — | Selected source |

### MCP Servers

| Item | Source | What It Does | Claude | Codex |
| --- | --- | --- | --- | --- |
| **OpenAI docs** | [OpenAI](https://developers.openai.com/mcp) | Official OpenAI developer documentation | — | MCP ★ |
| **Playwright MCP** *(fork)* | [Repository](mcp/README.md) | Standalone `@playwright/mcp` server; claims the same name as the playwright plugin and shadows it, so pick only one | MCP | — |
| **Lark / Feishu MCP** *(fork)* | [larksuite](https://github.com/larksuite/lark-openapi-mcp) | Feishu / Lark integration, kept in this fork although upstream retired it; needs an App ID / Secret and uses about 1 GB RAM per session, so it is off by default. Walkthrough: [LARK-MCP](docs/LARK-MCP.md) | MCP | — |


Complete bundle membership is listed in [catalog.md](catalog.md#members). Selected source revisions and adaptations are in [sources.md](platforms/sources.md). Storage analyzer modifications are documented in [UPSTREAM.md](skills/storage-analyzer/UPSTREAM.md) and submitted as [khazix-skills#50](https://github.com/KKKKhazix/khazix-skills/pull/50). Context7 and Playwright appear under Integrations; the standalone Playwright MCP is for users who skip the plugin.

Removed in 4.2.0: GitHub MCP and the github plugin, claude-mem, and PUA. The six AI Research entries became one bundle, and the Common rules became the writing-style rule. See the [migration notes](docs/migration.md#script-menu-ids) for the old IDs.

## Model Backends — First-Run Setup

The script installer writes `~/.claude/profiles/*.json`, but every backend except `claude` needs a login and/or a pasted credential before `cl_<backend>` will work. Full detail: [docs/BACKENDS.md](docs/BACKENDS.md).

| Backend | Install | Login | Where the credential goes |
| --- | --- | --- | --- |
| `claude` | — | native OAuth | Nothing to configure |
| `glm` | — (vendor-hosted endpoint) | — | Your BigModel API key → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/glm.json` |
| `or` | — (vendor-hosted endpoint) | — | Your OpenRouter key (`sk-or-v1-…`) → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/or.json` |
| `gpt` | `brew install cliproxyapi` | `cli-proxy-api --codex-login` (one-time browser authorization) | An `api-keys` entry from `~/.cli-proxy-api/config.yaml` → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/gpt.json` |
| `ccr` | `npm install -g @musistudio/claude-code-router` (needs Node.js >= 22) | `ccr ui` — admin UI on `http://127.0.0.1:3458` | The CCR client key minted in the UI → `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/ccr.json` |

- **`gpt` carries a real account-ban risk.** It reuses a consumer ChatGPT subscription through a reverse-engineered OAuth flow; read the full warning in [docs/BACKENDS.md](docs/BACKENDS.md) before using it.
- **`ccr` cannot be automated.** CCR v3 keeps its configuration in SQLite, so the providers, the client key, and the agent profile have to be created by hand in the web UI — once.
- **`or` needs a `/logout` first.** A cached Anthropic OAuth session outranks the environment variables the profile injects, so run `/logout` inside Claude Code once before the first `cl_or` launch — otherwise the requests keep going to Anthropic.
- **`or` has no 5h quota bar** in the statusline, and OpenRouter has no 5h rolling window to show one for; the reason is spelled out in [docs/BACKENDS.md](docs/BACKENDS.md). OpenRouter also only *guarantees* its native Anthropic endpoint for Anthropic first-party models, so the DeepSeek slots this profile ships are best-effort and have not been tested against a live key.
- **`gpt` and `ccr` are not selected by default** in the installer. Tick them in the "Model Backends" group to install them, `--all` still includes them, and an existing `~/.claude/profiles/gpt.json` / `ccr.json` is never removed by an upgrade.

Then `cl_glm` / `cl_or` / `cl_gpt` / `cl_ccr` launches that backend, and `cl_switch <name>` makes it the default for a bare `cl`. Every launch prints the backend and the model it resolved to. To pick a model without editing JSON, pass claude's own flag — `cl_glm --model glm-5v-turbo` — or set `CL_MODEL=sonnet` for one launch. Reasoning effort works the same way per backend: an optional top-level `"effort"` key in the profile (`low|medium|high|xhigh|max`) becomes that launcher's `--effort` default — shipped as `medium` for `claude`/`or`, `xhigh` for `glm` — and `cl_glm --effort high` or `CL_EFFORT=high` overrides it for one launch.

## Image Generation

The [`sinedied/agent-skills`:`image-gen`](https://github.com/sinedied/agent-skills) Skill is **always installed** by the script installer over the network (never vendored), alongside a repository-owned wrapper at `~/.claude/scripts/image-gen-openrouter.py`. Every `cl*` / `cl_*_auto` launcher shares the same global `~/.claude/skills/` and `~/.claude/scripts/` paths, so image generation works from any backend — and needs no local proxy at all: the wrapper posts straight to `https://openrouter.ai/api/v1/images` with `openai/gpt-image-2`, verifying the model is listed by `GET /api/v1/images/models` before it generates and failing closed if it is not. The upstream `image_gen.py` is not executed (its OpenAI routes do not exist on OpenRouter); `edit` sends reference images on the same endpoint instead. It needs `python3` and nothing else. **Authentication is the OpenRouter key in `~/.claude/profiles/or.json` (`.env.ANTHROPIC_AUTH_TOKEN`) and nothing else** — no environment-variable fallback, never on the command line, and **no OpenAI Platform API key is needed or requested**. `--uninstall` removes the Skill only when an ownership manifest, layout, and augmentation markers all agree. Full contract: [docs/BACKENDS.md](docs/BACKENDS.md).

## Directory Structure

```text
.
├── README.md / README.zh-CN.md   # User guide and category tables
├── AGENTS.md / CLAUDE.md         # Instructions for working in this repository
├── INSTALL.md                   # Agent-guided installation and updates
├── MAINTAIN.md                  # Agent workflow for changing this repository
├── catalog.md                   # IDs, support, recommendations and routes
├── skills/                      # Author-owned and customized skill sources
├── platforms/
│   ├── claude/                  # Claude instructions, lessons, rules, hooks, settings, skills
│   ├── codex/                   # Codex instructions, lessons, settings, skills
│   └── sources.md               # External revisions, members and adaptations
├── agents/                      # Fork: search agent
├── profiles/ / claude.zsh       # Fork: model backend profiles and the cl launcher
├── mcp/                         # Fork: Playwright and Lark/Feishu MCP configs
├── scripts/                     # Protected file operations, helpers, image-gen wrapper
├── lessons.md                   # This repository's correction history
├── docs/                        # Spec, migration notes, backend and Lark guides
└── install.sh / install.ps1     # Fork: interactive script installers (Claude Code)
```

## Key Mechanisms

- **Two install paths** — the script installers apply a menu selection to `~/.claude` in one run; the agent-guided path lists numbered choices in chat and records the user's selections. Both read the same templates under `platforms/claude/templates/`.
- **Independent memory** — Claude uses its own global `lessons.md` plus project `memory/MEMORY.md`; Codex uses its own global `lessons.md` plus project-root `lessons.md`. Templates and real histories remain separate. Only missing global logs are seeded.
- **Rules and status lines** — Claude has one writing rule and independent Python / TypeScript / Go rules; the gradient status line shows model, directory, venv, Git, context and the 5-hour quota of the active backend (Anthropic or GLM). Codex uses its native footer and subagent capabilities; this repository no longer installs custom role presets.
- **Configuration management** — edit-config follows main and records the actual revision; `/update-config` re-runs the script installer. Both paths share `agent-config/selection.json`. Conflicting source policies require an explicit migration choice; user selections and customizations are preserved.
- **Catalogue sync** — `scripts/check-catalog-sync.sh` checks catalog.md against both script installers, and `scripts/check-readme-sync.sh` keeps the two READMEs aligned.
- **Scoped changes** — preserve user edits, credentials, hooks and memory databases. Backups and file ownership support safe updates and explicit removals. ResearchStudio Idea/Reel and PPT Master prepare complete source only; runtime dependencies are handled on first use.

## Settings Defaults

These are values from the current templates, applied only when the corresponding item is selected. Existing overrides are preserved and differences reported. Base settings, permissions, status lines and lessons are separate choices; Codex's auto-import setting is an installation prerequisite. The agent checks local version support before applying a setting; the script installer downgrades `auto` to `bypassPermissions` below Claude Code 2.1.80.

| Agent | Key | Template value | Effect |
| --- | --- | --- | --- |
| Claude | `model` / `effortLevel` | `opus` / `xhigh` | Model and reasoning effort |
| Claude | `tui` | `fullscreen` | Fullscreen terminal interface |
| Claude | `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `1` | Enable the agent-teams experiment |
| Claude | `env.API_TIMEOUT_MS` / `env.FORCE_AUTOUPDATE_PLUGINS` | `3000000` / `1` | Fork: long API timeout and plugin auto-update |
| Claude | `includeCoAuthoredBy` | `false` | Fork: no co-author trailer unless Co-authored-by is selected |
| Claude | `permissions.defaultMode` | `auto` | Separate permissions template also contains broad tool allowances |
| Codex | `model` / `model_reasoning_effort` | `gpt-5.6-sol` / `max` | Model and reasoning effort |
| Codex | `web_search` | `live` | Live web search |
| Codex | `features.multi_agent` / `concurrent_reasoning_summaries` | `true` / `false` | Agent collaboration and summary behavior |
| Codex | `shell_environment_policy.inherit` | `all` | Inherit the shell environment |
| Codex | `approval_policy` / `sandbox_mode` | `never` / `danger-full-access` | Separately selected high-autonomy permissions |
| Codex | `desktop.external-agent-import-sync-enabled` | `false` | Keep imports under explicit selection control |

Actual settings and per-item operations: [Claude](platforms/claude/README.md#configuration) · [Codex](platforms/codex/README.md#configuration). Current platform validation limits are recorded in [migration notes](docs/migration.md).

## Customization

You can ask the agent to maintain the repository itself. It follows [MAINTAIN.md](MAINTAIN.md), updates the complete payload and installation route, and keeps the catalogue, both READMEs and the script installers consistent.

| Request | What the agent changes |
| --- | --- |
| “Add this skill and explain when to use it” | Local source for author-owned skills; upstream installation recipe for third-party originals, with support, category and usage description |
| “Update ResearchStudio” | Recorded upstream revision, members and necessary adaptations, verified in isolation |
| “Edit this skill / remove this option” | Current payload and references; removal records explain old IDs without silently uninstalling user copies |
| “Recommend these skills for Claude / Codex” | Only that agent's author recommendation markers |
| “Add language rules” | `platforms/claude/templates/rules/<lang>/` and its catalogue entry |
| “Change Claude / Codex instructions or lessons policy” | That agent's templates and matching memory rules |

For installed configuration queries and changes, use [edit-config](skills/edit-config/SKILL.md), which follows [INSTALL.md](INSTALL.md) for modifications. The root AGENTS.md, CLAUDE.md and lessons.md belong to this repository; deployable global files live under each platform's templates.

## Acknowledgements

- [Claude Code in Action](https://anthropic.skilljar.com/claude-code-in-action) — Anthropic Academy's official course
- [Working for 10 Claude Codes](https://mp.weixin.qq.com/s/9qPD3gXj3HLmrKC64Q6fbQ) by Hu Yuanming — multi-instance patterns
- [Harness Engineering](https://openai.com/index/harness-engineering/) by OpenAI
- [Anthropic Engineering](https://www.anthropic.com/engineering) / [OpenAI Engineering](https://openai.com/news/engineering/)
- [Claude Code Best Practice](https://github.com/shanraisshan/claude-code-best-practice) by shanraisshan
- [Claude How To](https://github.com/luongnv89/claude-howto) by luongnv89

## Fork-specific Features

This fork adds the following on top of upstream:

- **Script installers** (`install.sh` / `install.ps1`): interactive two-level selector, plugin reconciliation, `--only` / `--list-ids`, `--dry-run` / `--uninstall`
- **Shell Wrapper** (`claude.zsh`): `cl`/`cl_auto`/`cl_switch`/`cl_profiles` plus a generated `cl_<backend>` per profile
- **Model Backends** (`profiles/*.json`): one JSON per backend — `claude`, `glm`, `or`, `gpt`, `ccr`. Dropping a new JSON in `~/.claude/profiles/` adds a backend with no code changes. See [docs/BACKENDS.md](docs/BACKENDS.md)
- **Search Agent** (`agents/search.md`): Jeff, a read-only web research specialist
- **System Prompt** (`system-prompt.txt`): custom behavioral guidelines
- **Lark / Feishu MCP** (`mcp/`): opt-in, kept although upstream retired it; see [docs/LARK-MCP.md](docs/LARK-MCP.md)
- **Extra catalogue items**: feature-dev, ralph-loop, commit-commands and ecc plugins, the update-config and cheatsheet-creator skills, and a 6-skill Matt subset
- **Co-authored-by**: installer option for commit attribution

## License

This repository is MIT. Bundled and fetched third-party components retain their own licenses. **lieflat-charts** uses [PolyForm Noncommercial 1.0.0](https://github.com/larashero3-dotcom/lieflat-charts/blob/main/LICENSE), for noncommercial use only; it is fetched only when selected and is not redistributed here.

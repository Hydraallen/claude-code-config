# Plugins

25 plugins across 10 marketplaces + 3 DeepXiv academic research skills (fetched from GitHub at install time). Context7, GitHub, Playwright migrated from MCP to official plugins.

## Plugin List

| Plugin | Marketplace | What It Does |
|--------|-------------|--------------|
| [**superpowers**](https://github.com/obra/superpowers) | claude-plugins-official | Brainstorming, debugging, code review, git worktrees, plan writing |
| [**andrej-karpathy-skills**](https://github.com/forrestchang/andrej-karpathy-skills) | karpathy-skills | Karpathy coding guidelines: Think-First, Simplicity, Surgical Changes, Goal-Driven |
| [**document-skills**](https://github.com/anthropics/skills) | anthropic-agent-skills | PDF, DOCX, PPTX, XLSX creation and manipulation |
| [**example-skills**](https://github.com/anthropics/skills) | anthropic-agent-skills | Frontend design, MCP builder, canvas design, algorithmic art |
| [**claude-mem**](https://github.com/thedotmack/claude-mem) | thedotmack | Persistent memory with smart search, timeline, AST-aware code search |
| [**claude-health**](https://github.com/tw93/claude-health) | claude-health | Health check & wellness dashboard (default off) |
| [**PUA**](https://github.com/tanweai/pua) | pua-skills | AI agent productivity booster (pua, pua-en, pua-ja) (default off) |
| [**context7**](https://github.com/upstash/context7) | claude-plugins-official | Up-to-date library documentation lookup |
| **code-review** | claude-plugins-official | Confidence-based code review |
| [**github**](https://github.com/github/github-mcp-server) | claude-plugins-official | GitHub integration (issues, PRs, workflows) |
| [**playwright**](https://github.com/microsoft/playwright-mcp) | claude-plugins-official | Browser automation, E2E testing, screenshots |
| **feature-dev** | claude-plugins-official | Guided feature development |
| **code-simplifier** | claude-plugins-official | Code simplification and refactoring |
| **ralph-loop** | claude-plugins-official | Session-aware AI assistant REPL |
| **commit-commands** | claude-plugins-official | Git commit, clean branches, commit-push-PR |
| [**codex**](https://github.com/openai/codex-plugin-cc) | openai-codex | Adversarial code review, Codex CLI integration, cross-model analysis |
| [**tokenization**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | HuggingFace Tokenizers, SentencePiece |
| [**fine-tuning**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | Axolotl, LLaMA-Factory, PEFT, Unsloth |
| [**post-training**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | GRPO, RLHF, DPO, SimPO |
| [**inference-serving**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | vLLM, SGLang, TensorRT-LLM, llama.cpp |
| [**distributed-training**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | DeepSpeed, FSDP, Megatron-Core, Ray Train |
| [**optimization**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | AWQ, GPTQ, GGUF, Flash Attention, bitsandbytes |
| [**frontend-slides**](https://github.com/zarazhangrui/frontend-slides) | frontend-slides | Zero-dependency HTML slide generator with PPT conversion and bold template styles (default off) |
| [**ppt-master**](https://github.com/hugohe3/ppt-master) | ppt-master | Editable PPTX from PDF/DOCX/URL/Markdown — real shapes & animations; needs `pip install -r requirements.txt` (default off) |

## DeepXiv Academic Research Skills

Pulled from [github.com/DeepXiv/deepxiv_sdk](https://github.com/DeepXiv/deepxiv_sdk) at install time (always latest). Grouped under **Academic Research** alongside the AI Research plugins above.

| Skill | What It Does |
|-------|--------------|
| **deepxiv-cli** | arXiv/PMC paper search, section-by-section reading, AI agent analysis |
| **deepxiv-trending-digest** | Generate markdown digests of trending papers (last 7 days) |
| **deepxiv-baseline-table** | Build baseline comparison tables from research papers |

## Installation

```bash
./install.sh   # interactive selector — pick the plugin groups you want
```

Or manually — add marketplaces then install plugins using `name@marketplace` syntax:

```bash
# Add required marketplaces
claude plugin marketplace add https://github.com/anthropics/claude-plugins-official
claude plugin marketplace add https://github.com/anthropics/skills
claude plugin marketplace add https://github.com/thedotmack/claude-mem
claude plugin marketplace add https://github.com/zechenzhangAGI/AI-research-SKILLs
claude plugin marketplace add https://github.com/openai/codex-plugin-cc
claude plugin marketplace add https://github.com/forrestchang/andrej-karpathy-skills
claude plugin marketplace add https://github.com/tw93/claude-health
claude plugin marketplace add https://github.com/tanweai/pua
claude plugin marketplace add https://github.com/zarazhangrui/frontend-slides
claude plugin marketplace add https://github.com/hugohe3/ppt-master

# Install plugins (name@marketplace)
claude plugin install superpowers@claude-plugins-official
claude plugin install frontend-slides@frontend-slides
claude plugin install ppt-master@ppt-master
# ... repeat for each plugin above
```

## Plugins that need configuration

### github — requires `GITHUB_PERSONAL_ACCESS_TOKEN`

The plugin talks to `https://api.githubcopilot.com/mcp/` and sends
`Authorization: Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}`. The installer does not
set that variable, and Claude Code does not read your `gh` login for it. Without
it the header goes out as a bare `Bearer `, which GitHub rejects — every session
then opens with:

```
plugin:github:github (400): "Error POSTing to endpoint: bad request:
Authorization header is badly formatted"
```

That message names neither the variable nor the plugin's config file, so it is
easy to misread as a broken install. Export the variable in your shell rc — if
the `gh` CLI is already logged in, its token works and needs no separate PAT:

```bash
# ~/.zshrc  (or ~/.bashrc)
if command -v gh >/dev/null 2>&1; then
  export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token 2>/dev/null)"
fi
```

Open a new shell and confirm with `claude mcp list` — `plugin:github:github`
should report `✔ Connected`. Note this only reaches Claude Code when it is
launched from an interactive shell; started from Spotlight or the Dock it
inherits no rc, and the plugin stays broken.

If you would rather not touch your shell rc, put the token in the `env` block of
`~/.claude/settings.json` instead — plaintext either way, so treat the file
accordingly.

### playwright — do not also enable the standalone Playwright MCP

The plugin and the standalone MCP server in [`../mcp/`](../mcp/README.md) both
register under the name `playwright`. A user-scope MCP entry shadows the
plugin's, so enabling both leaves the plugin one silently never started. The
standalone server is default-off in the installer for this reason; if you
already have the duplicate, drop it with `claude mcp remove playwright`.

### context7 — optional `CONTEXT7_API_KEY`

Its header is `${CONTEXT7_API_KEY:-}`, so an unset key is not an error: the
server connects anonymously and is rate-limited. Set the variable only if you
hit throttling.

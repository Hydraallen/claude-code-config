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
| **frontend-design** | claude-plugins-official | Production-grade frontend interfaces |
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

[English](https://github.com/Mizoreww/claude-code-config/blob/main/README.md) | **中文**

# Claude Code 配置

[Claude Code](https://claude.com/claude-code) 的生产级配置：全局指令、多语言编码规则、插件、MCP 集成、自我改进循环。

## 目录结构

```
.
├── CLAUDE.md              # 全局指令
├── settings.json          # 设置（权限、插件、hooks、模型）
├── lessons.md             # 自我纠正日志模板（通过 hook 自动加载）
├── rules/                 # 多语言编码标准（common + python/typescript/golang）
├── mcp/                   # MCP 服务器配置（仅 Lark-MCP）
├── plugins/               # 插件安装指南（19 个插件，5 个市场）
├── skills/                # 自定义技能（paper-reading）
└── install.sh             # 一键安装脚本
```

## 快速开始

```bash
git clone https://github.com/Mizoreww/claude-code-config.git
cd claude-code-config
./install.sh              # 安装全部
./install.sh --dry-run    # 预览变更
```

选择性安装：

```bash
./install.sh --rules python typescript  # 仅规则
./install.sh --plugins                  # 仅插件
./install.sh --mcp                      # 仅 MCP
```

## 核心特性

### 自我改进循环

1. 用户纠正 Claude → 自动写入 `~/.claude/lessons.md`
2. 下次 session → `SessionStart` hook 自动注入 lessons 到上下文
3. 模式确认后 → 规则提升至 `CLAUDE.md`

### SessionStart Hook

`settings.json` 中配置了两个 `SessionStart` hook：
- **startup**：新 session 启动时注入 lessons.md
- **compact**：上下文压缩后重新注入 lessons.md

取代了以前在 CLAUDE.md 中要求手动 Read lessons.md 的方式（更可靠）。

### 分层规则

```
common/       → 通用原则（始终加载）
  ↓ extended by
python/       → PEP 8、pytest、black、bandit
typescript/   → Zod、Playwright、Prettier
golang/       → gofmt、表驱动测试、gosec
```

### 插件优先

19 个插件，5 个市场。Context7、GitHub、Playwright 已从 MCP 迁移到官方插件。MCP 仅保留 Lark-MCP。

| 插件 | 市场 | 功能 |
|------|------|------|
| [**superpowers**](https://github.com/obra/superpowers) | claude-plugins-official | 头脑风暴、调试、代码审查、Git worktree、计划编写 |
| [**everything-claude-code**](https://github.com/affaan-m/everything-claude-code) | everything-claude-code | TDD、安全审查、数据库模式、Go/Python/Spring Boot |
| [**document-skills**](https://github.com/anthropics/skills) | anthropic-agent-skills | PDF、DOCX、PPTX、XLSX 创建和操作 |
| [**example-skills**](https://github.com/anthropics/skills) | anthropic-agent-skills | 前端设计、MCP 构建器、画布设计、算法艺术 |
| [**claude-mem**](https://github.com/thedotmack/claude-mem) | thedotmack | 持久化记忆，智能搜索、时间线、AST 感知代码搜索 |
| **frontend-design** | claude-plugins-official | 生产级前端界面设计 |
| [**context7**](https://github.com/upstash/context7) | claude-plugins-official | 最新库文档查询 |
| **code-review** | claude-plugins-official | 基于置信度的代码审查 |
| [**github**](https://github.com/github/github-mcp-server) | claude-plugins-official | GitHub 集成（Issue、PR、工作流） |
| [**playwright**](https://github.com/microsoft/playwright-mcp) | claude-plugins-official | 浏览器自动化、E2E 测试、截图 |
| **feature-dev** | claude-plugins-official | 引导式功能开发 |
| **code-simplifier** | claude-plugins-official | 代码简化和重构 |
| **ralph-loop** | claude-plugins-official | 会话感知 AI 助手 REPL |
| **commit-commands** | claude-plugins-official | Git 提交、清理分支、提交-推送-PR |
| [**fine-tuning**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | Axolotl、LLaMA-Factory、PEFT、Unsloth |
| [**post-training**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | GRPO、RLHF、DPO、SimPO |
| [**inference-serving**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | vLLM、SGLang、TensorRT-LLM、llama.cpp |
| [**distributed-training**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | DeepSpeed、FSDP、Megatron-Core、Ray Train |
| [**optimization**](https://github.com/Orchestra-Research/AI-Research-SKILLs) | ai-research-skills | AWQ、GPTQ、GGUF、Flash Attention、bitsandbytes |

详见 [`plugins/README.md`](plugins/README.md) 了解安装方式。

### 自定义技能

| 技能 | 说明 |
|------|------|
| **paper-reading** | 结构化论文阅读与总结，自动截图关键图表。优先使用 ar5iv HTML 版本，Playwright 截图，输出标准化 Markdown（问题、方法、实验、洞见）。 |

自定义技能放在 `skills/<name>/SKILL.md`。

## 安全提示

`settings.json` 默认使用 `bypassPermissions` 模式（适合高级用户）。如需更安全的默认值，将 `defaultMode` 改为 `"default"`，并将 `skipDangerousModePermissionPrompt` 设为 `false`。

## 自定义

- **添加语言**：创建 `rules/<lang>/` 目录，扩展 common 规则
- **添加技能**：放到 `skills/<name>/SKILL.md`
- **调整 CLAUDE.md**：根据你的 shell、包管理器、项目上下文定制

## 致谢

- [**AI Agent Workflow Orchestration Guidelines**](https://gist.github.com/OmerFarukOruc/a02a5883e27b5b52ce740cadae0e4d60) by [@OmerFarukOruc](https://github.com/OmerFarukOruc) — 工作流编排的灵感来源
- [**Harness Engineering**](https://openai.com/zh-Hans-CN/index/harness-engineering/) by OpenAI — "驾驭工程"理念：工程师从代码编写者转变为系统设计者，用 Agent 生成百万行代码
- [**我给 10 个 Claude Code 打工**](https://mp.weixin.qq.com/s/9qPD3gXj3HLmrKC64Q6fbQ) by 胡渊鸣 — 多 Claude Code 实例并行协作的实践经验分享
- [**Claude Code in Action**](https://anthropic.skilljar.com/claude-code-in-action) by Anthropic Academy — 官方课程，涵盖 Claude Code 工具集成、MCP 服务器、GitHub 自动化等开发工作流
- [**ChatGPT Prompt Engineering for Developers**](https://www.deeplearning.ai/short-courses/chatgpt-prompt-engineering-for-developers/) by DeepLearning.AI & OpenAI — Andrew Ng 与 Isa Fulford 合作的提示工程入门课程

## 许可证

MIT

<!-- 用户表格与 catalog.md、README.md 同步维护。 -->

[English](README.md) | **中文** | [更新日志](CHANGELOG.zh-CN.md)

# Awesome Agent Config

![Claude 状态栏](assets/statusline.png)

一个仓库维护 [Claude Code](https://claude.com/claude-code) 和 [Codex](https://developers.openai.com/codex/) 的全局指令、编码规则、插件、共享 skills、状态栏与纠错记忆。本仓库是 [Mizoreww/awesome-agent-config](https://github.com/Mizoreww/awesome-agent-config) 的 fork，保留两条安装路径：脚本安装器（`install.sh` / `install.ps1`，仅 Claude Code）和上游的 agent 引导安装——由已有 agent 识别平台、解释选项并安装你选择的内容。此外还提供多后端启动器与 OpenRouter 出图，并保留上游已退役的 Lark/飞书 MCP。

## 示例

![Claude Code Demo](images/claude-code-demo.png)

## 快速开始

### 方式 A —— 脚本安装器（Claude Code）

**macOS / Linux**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.sh)
```

**Windows (PowerShell)**:

```powershell
irm https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.ps1 | iex
```

启动两级交互菜单：11 个分组共 48 项，其中 30 项默认开启。Windows 上的 `install.ps1` 提供 10 个分组共 41 项；模型后端、shell wrapper、co-author 与 Matt skills 目前只支持 macOS / Linux。参数（括号内为 PowerShell 写法）：

- `--all`（`-All`）：跳过菜单，安装除可选 storage-analyzer 之外的全部条目。增量安装：不删除任何内容。
- `--only <ids>`（`-Only`）：只安装列出的菜单项，逗号分隔。增量安装：不删除其他内容、不对账插件、不重建 `enabledPlugins`、不写版本戳。
- `--list-ids`（`-ListIds`）：列出全部菜单 ID、默认值与分组。
- `--prune-foreign-plugins`（`-PruneForeignPlugins`）：交互式运行对账时，也处理安装器不管理的插件（见下文）。
- `--dry-run`（`-DryRun`）、`--uninstall`（`-Uninstall`）、`--force`（`-Force`）、`--version`（`-Version`）。

```
    Platform: WSL (Ubuntu) — Playwright → Windows Chrome

  > [7/8]  Core                  全局指令、设置、写作规则、状态栏...
    [2/4]  Model Backends        GLM、OpenRouter、ChatGPT（CLIProxyAPI）、CCR
    [3/3]  Language Rules        Python / TypeScript / Go
    [1/3]  Review                code-review（adversarial-review / Codex 需手动勾选）
    [10/11] Workflow             karpathy、superpowers、mattpocock、ecc、update-config、edit-config、neat-freak...
    [2/2]  Integrations          context7、playwright
    [3/5]  Design & Content      document-skills、example-skills、humanizer、humanizer-zh、lieflat-charts
    [0/2]  Slides                frontend-slides、ppt-master
    [0/1]  Storage               storage-analyzer
    [2/7]  Academic Research     paper-reading、cheatsheet-creator、AI Research、ResearchStudio、DeepXiv...
    [0/2]  MCP Servers           Playwright、Lark/飞书（可选）
```

菜单顶部（以及每次运行开头）的 `Platform:` 行显示检测到的平台（macOS、Linux、WSL）以及 Playwright 的去向：playwright 插件，或在 WSL 中使用 Windows 的 Chrome（[说明](mcp/README.md#wsl-windows-chrome)）。

- **主菜单**：↑↓ 切换分组，**Enter 或 →** 进入子菜单，**q** 退出。移到 *Submit* 按 Enter 开始安装。
- **子菜单**：↑↓ 切换条目，**空格** 或 **Enter** 勾选，**← 或 Esc** 返回主菜单。
- 快捷键（任意层级）：**a** 全选，**n** 全不选，**d** 恢复默认；在子菜单中只作用于当前分组。
- Review 分组中 `adversarial-review` 与 `codex` 互斥——选中一个会取消另一个。

**交互式重跑安装器：取消勾选即删除。** 菜单打开时，已安装的条目处于勾选状态；未安装的条目按默认值显示，但你在之前某次交互式运行中取消勾选过的条目保持未勾选。原样提交不会改变任何东西。提交时，所有未勾选的条目都会被删除，但只删除安装器自己装上的内容：

- 安装器目录内的插件（包括 code-review 和 codex）会被卸载，不再被任何剩余插件需要的 marketplace 也会移除（`claude-plugins-official` 除外）。你自己安装的插件保留，除非传入 `--prune-foreign-plugins`。把所有插件项都取消勾选，会卸载全部目录内插件。
- skill、语言规则、writing-style 规则、DeepXiv skill、搜索 agent、Matt skills 和固定版本的上游 skill 会被删除。你改过的副本会先移到 `~/.claude/agent-config/backups/<时间戳>-deselect/`（固定版本上游 skill 移到 `agent-config/backups/<id>/`），安装器会提示。
- Playwright 和 Lark MCP 服务只在其命令与安装器注册的一致时（`npx @playwright/mcp` / `npx @larksuiteoapi/lark-mcp`，WSL 中为 Windows `node.exe` 条目）才移除；你自己注册的同名服务保留，并给出警告。
- StatusLine：删除 `statusLine` 设置（仅当它运行 `~/.claude/hooks/statusline.sh`）和这个脚本。Lessons：删除 SessionStart hook，保留 `lessons.md`。Co-authored-by：把 `includeCoAuthoredBy` 设为 `false`。
- 启动器（Shell wrapper，且所有模型后端都未勾选）：删除 `claude.zsh`、`system-prompt.txt`，以及 `~/.zshrc` 中完全一致的 `source ~/.claude/claude.zsh` 这一行（先备份 rc 文件；其他写法只给警告）。`profiles/` 和 `default-profile` 存有你的 API key，始终保留，取消勾选某个后端时也一样。
- CLAUDE.md 和 settings.json 不会被删除；取消勾选只表示安装器不再更新它们。

`--all`、`--only` 以及没有终端的运行（例如 CI 里的 `curl | bash`）都是增量的：只安装选中的内容，不删除任何东西。删除不可撤销，建议先用 `--dry-run` 预览，它会列出每一项删除和备份。

**每次运行（包括增量运行）都会清理已退役的条目：** github 插件、旧的 user scope GitHub MCP 服务（仅当它指向 `api.githubcopilot.com/mcp/`），以及 claude-mem、PUA 插件和它们的 marketplace，外加它们留下的内容：插件缓存和数据目录、超过一小时的 `plugins/cache/temp_git_*` 残留克隆、`~/.claude.json` 中的使用记录（先备份）以及 claude-mem 的数据目录 `~/.claude-mem`（有 claude-mem 进程运行或设置了 `ACCC_KEEP_CLAUDE_MEM_DATA=1` 时保留）。仍在使用 claude-mem 的话，升级前请先读[迁移说明](docs/migration.md#removed-integrations)。每次运行都会把选择记录到 `~/.claude/agent-config/selection.json`，之后可以交给 `edit-config` 接管。

### 方式 B —— agent 引导安装（Claude 或 Codex）

本 fork 的发布主线为 [Hydraallen/claude-code-config](https://github.com/Hydraallen/claude-code-config) 的 `main`。之前使用上游 Mizoreww/awesome-agent-config 的话，agent 会把它视为不同来源，只有你明确要求才切换，见[迁移说明](docs/migration.md#repository-identity)。只有脚本安装器提供的条目（模型后端、启动器、co-author、搜索 agent、image-gen）由 agent 在你确认后用 `install.sh --only <id>` 安装。

在 Claude 或 Codex 中打开这份 checkout，或把**当前正在阅读的仓库页面 URL**与下面这段请求一起发给 agent。分享分支页面时保留 URL 中的 branch/ref。

> 请读取我提供的 checkout 或仓库页面中的 INSTALL.md，使用与这份 README 相同的分支/revision。默认配置当前对话使用的 agent。检查系统、client 和已有配置，直接在当前对话中按分类完整列出这个 agent 支持的安装项，连续编号，附上具体用途、作者推荐与已安装状态。优先使用可用的原生多选问答；没有时让我在对话里选择多个编号或名称。选项直接显示在对话中，不生成单独的 Markdown 文档或报告。根据我的选择安装和验证，保留已有定制。

Agent 会在当前对话中只展示目标 agent 支持的完整选项，附上用途与推荐。客户端有真正的多选问答工具时，按分类勾选；没有时，直接回复多个编号、名称或自然语言选择。Agent 会遵守工具的实际限制，并沿用你已经明确的选择。插件整包占一个编号并列出成员，包内已有能力不会再重复安装。作者推荐依据已记录的旧 main/Codex 安装菜单默认项及后续调整，[映射关系](catalog.md#recommendations)已注明。推荐标记不代表你已同意安装。

之后直接说“添加 paper-reading”“更新我上次选择的内容”或“移除 storage-analyzer”。已有选择会沿用，没有提到的已安装项不会被卸载。两端统一使用 `edit-config` 查询、增删改、修复和更新配置，跟踪本仓库的 `main` 分支。查询只读；未安装 skill 时，全局指令提供同一工作流的读取入口。

优先使用原生插件/MCP 命令；所选范围或 client 需要时，agent 再按仓库说明采用源码安装。你无需自己判断 npx、插件和 skill 复制渠道。Codex 安装会关闭外部 agent 自动导入，使安装内容遵循你的选择。Windows 与 WSL 分别检测配置，共用 home 的 App/CLI 会复用已有安装。

Codex 会先检查可用的 OpenAI 官方/curated 目录，再核实上游 Codex 包与兼容插件。[插件说明](platforms/codex/plugins.md)集中记录具体渠道和限制；官方目录的可用范围取决于账号与 client，已有同等能力会优先复用。

[安装流程](INSTALL.md) · [Claude 操作说明](platforms/claude/README.md) · [Codex 操作说明](platforms/codex/README.md) · [完整目录与整包成员](catalog.md)

## 分类目录

保留原有分类，合并 Claude 与 Codex 的能力。第三方原版从上游安装，本仓库保存自有 skill 与保留署名的定制版。handoff 仅作为 Matt 包成员提供。`—` 表示本仓库未为该 agent 提供该项，agent 展示选择时会过滤它。平台列中的 **★** 表示该 agent 的作者推荐。标注 *（fork）* 的条目为本 fork 特有；Claude 列写着*脚本安装器*的条目只能由 `install.sh` / `install.ps1` 安装。准确渠道、稳定 ID 与推荐标记以 [catalog.md](catalog.md) 为准。

### Core · 基础配置

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **CLAUDE.md / AGENTS.md** | [本仓库](platforms/claude/README.md#configuration) | 各 agent 独立的全局指令 | 模板 ★ | 模板 ★ |
| **Base settings** | [本仓库](platforms/codex/README.md#configuration) | 局部合并模型、推理与运行设置 | 模板 ★ | 模板 ★ |
| **Permissions** | [本仓库](platforms/codex/README.md#configuration) | 用户选择可信环境后，单独配置高自主权限 | 模板 ★ | 模板 ★ |
| **Writing style rule** | [本仓库](platforms/claude/README.md#configuration) | 完整英文写作要求与示例，替代原 Common rules | 规则 ★ | — |
| **StatusLine** | [本仓库](platforms/claude/README.md#configuration) | Claude 渐变上下文/用量栏（Anthropic / GLM 5h 与每周额度）与字体；Codex 原生状态栏 | 模板 ★ | 模板 ★ |
| **Lessons** | [本仓库](platforms/codex/README.md#configuration) | 独立空白全局记录及记忆规则，保留真实纠错历史 | 模板 ★ | 模板 ★ |
| **Search agent** *（fork）* | [本仓库](agents/search.md) | Jeff，只读网络搜索 agent | 脚本安装器 ★ | — |
| **Shell wrapper** *（fork）* | [本仓库](docs/BACKENDS.zh-CN.md) | `cl` / `cl_auto` / `cl_switch` 启动器，每个 profile 生成一个 `cl_<backend>`，并附自定义系统提示 | 脚本安装器 ★ | — |
| **Co-authored-by** *（fork）* | 本仓库 | 在 commit 中把 Claude 加为共同作者 | 脚本安装器 | — |

### Model Backends · 模型后端 *（fork）*

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **GLM Coding Plan** | [本仓库](docs/BACKENDS.zh-CN.md) | 智谱 BigModel 的 Anthropic 兼容端点，用 `cl_glm` 启动 | 脚本安装器 ★ | — |
| **OpenRouter** | [本仓库](docs/BACKENDS.zh-CN.md) | OpenRouter 的 Anthropic 兼容端点，用 `cl_or` 启动；同一个 key 也供 image-gen 使用 | 脚本安装器 ★ | — |
| **ChatGPT via CLIProxyAPI** | [本仓库](docs/BACKENDS.zh-CN.md) | 用 `cl_gpt` 复用 ChatGPT Plus/Pro 订阅；有封号风险 | 脚本安装器 | — |
| **CCR gateway** | [本仓库](docs/BACKENDS.zh-CN.md) | claude-code-router：GLM 与 GPT 合并在一个 `/model` 列表，用 `cl_ccr` 启动；需在 Web UI 手动配置 | 脚本安装器 | — |

### Language Rules · 语言规则

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **Python rules** | [本仓库](platforms/claude/README.md#configuration) | PEP 8、pytest、类型注解与 bandit | 模板 | — |
| **TypeScript rules** | [本仓库](platforms/claude/README.md#configuration) | Zod、Playwright 与不可变性 | 模板 | — |
| **Go rules** | [本仓库](platforms/claude/README.md#configuration) | gofmt、表驱动测试与 gosec | 模板 | — |

### Review · 审查

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **Claude code-review** | [Anthropic](https://github.com/anthropics/claude-plugins-official) | 基于置信度的 PR 代码审查 | 原生插件 ★ | — |
| **Matt code-review** | [Matt Pocock](https://github.com/mattpocock/skills) | Standards / Spec 双轴审查；Codex 可单独选择，本 fork 的 Claude Matt 精选子集不含此项 | — | 精选源码 ★ |
| **adversarial-review** | [poteto/noodle](https://github.com/poteto/noodle/blob/main/.agents/skills/adversarial-review/SKILL.md) | Skeptic、Architect、Minimalist 视角的跨模型审查 | 内置 skill ★ | — |
| **codex-in-claude** | [OpenAI](https://github.com/openai/codex-plugin-cc) | 在 Claude 内调用 Codex CLI，按需选择审查方式 | 原生插件 | — |

### Workflow · 工作流

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **andrej-karpathy-skills** | [Karpathy skills](https://github.com/forrestchang/andrej-karpathy-skills) | 先思考、保持简单与改动集中、明确可验证结果 | 原生插件 ★ | 插件 / 源码 ★ |
| **superpowers** | [obra / OpenAI curated](https://github.com/obra/superpowers) | 头脑风暴、调试、TDD、worktree 与规划，14 项整包 | 原生插件 | 插件 / 源码 |
| **mattpocock-skills** | [Matt Pocock](https://github.com/mattpocock/skills) | 规划、TDD、研究、grilling 与交付；本 fork 的 Claude 安装为 6 项精选子集，Codex v1.1.0 精选 20 项，含 handoff | 精选源码 ★ | 精选源码 ★ |
| **neat-freak** | [khazix-skills](https://github.com/KKKKhazix/khazix-skills/tree/2b4a645cfdc894156ae347d897723562f719ce95/neat-freak) | 对齐项目文档、agent 规则、获准维护的记忆及工作区残留 | 上游安装 ★ | 上游安装 ★ |
| **feature-dev** *（fork）* | [Anthropic](https://github.com/anthropics/claude-plugins-official) | 引导式功能开发 | 原生插件 ★ | — |
| **ralph-loop** *（fork）* | [Anthropic](https://github.com/anthropics/claude-plugins-official) | 自动迭代循环 | 原生插件 ★ | — |
| **commit-commands** *（fork）* | [Anthropic](https://github.com/anthropics/claude-plugins-official) | Git commit / push / PR 工作流 | 原生插件 ★ | — |
| **ecc** *（fork）* | [Everything Claude Code](https://github.com/affaan-m/everything-claude-code) | TDD、安全、数据库与多语言工作流 | 原生插件 ★ | — |
| **code-simplifier** | [Anthropic](https://github.com/anthropics/claude-plugins-official) | 代码简化与重构 agent | 原生插件 ★ | — |
| **edit-config** | [本仓库](skills/edit-config/SKILL.md) | 查询和管理 main 的配置，两端共用 | 内置 skill ★ | 内置 skill ★ |
| **update-config** *（fork）* | [本仓库](skills/update-config/SKILL.md) | `/update-config` —— 在会话内重跑脚本安装器 | 内置 skill ★ | — |

### Integrations · 开发集成

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **context7** | [Upstash](https://github.com/upstash/context7) | 查询最新库文档 | 原生插件 ★ | 插件 / MCP ★ |
| **playwright** | [Microsoft](https://github.com/microsoft/playwright-mcp) | 浏览器自动化、E2E 与截图；Codex MCP 固定 0.0.78；WSL 中 install.sh 改为驱动 Windows 的 Chrome（[说明](mcp/README.md#wsl-windows-chrome)） | 原生插件 ★ | MCP ★ |

### Design & Content · 设计与内容

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **document-skills** | [Anthropic](https://github.com/anthropics/skills) | 创建和编辑 PDF、DOCX、PPTX、XLSX；优先复用 Codex 已有同等内置能力 | 原生插件 ★ | 内置能力 / 兼容插件 / 源码 ★ |
| **example-skills** | [Anthropic](https://github.com/anthropics/skills) | Claude：12 项示例；Codex：canvas-design、algorithmic-art、mcp-builder 三项 | 原生插件 ★ | 精选源码 ★ |
| **humanizer** | [blader](https://github.com/blader/humanizer) | 去除英文写作中的机械化 AI 表达；Claude 使用 `humanizer@humanizer` 插件，调用名 `/humanizer:humanizer`（需要 Claude Code 2.1.142 或更高） | 插件 / 源码 ★ | 上游安装 ★ |
| **humanizer-zh** | [op7418](https://github.com/op7418/Humanizer-zh) | 去除中文写作中的机械化 AI 表达 | 上游安装 | 上游安装 |
| **lieflat-charts** | [lieflat-charts](https://github.com/larashero3-dotcom/lieflat-charts) | Lupi / Basics / Glance / Maps HTML 图表与 12 个双语报告模板；源码不含预览媒体，仅限非商业用途 | 精选源码 | — |
| **image-gen** *（fork）* | [sinedied/agent-skills](https://github.com/sinedied/agent-skills) | 经 OpenRouter 出图；脚本安装器始终安装 | 脚本安装器 | — |

### Slides · 演示文稿

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **frontend-slides** | [zarazhangrui](https://github.com/zarazhangrui/frontend-slides) | 零依赖 HTML 演示文稿，支持 PPT 转换与多种风格 | 原生插件 | 兼容插件 / 源码 |
| **ppt-master** | [hugohe3](https://github.com/hugohe3/ppt-master) | 从 PDF / DOCX / URL / Markdown 生成可编辑 PPTX、形状与动画；首次使用准备运行环境 | 原生插件 | 精选源码 |

### Storage · 存储分析

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **storage-analyzer** | [khazix-skills（定制）](https://github.com/KKKKhazix/khazix-skills/tree/fcba3adcf5def1ccd4bb688de93060227471b129/storage-analyzer) | 只读磁盘分析、交互 HTML 报告与受保护的清理入口；包含 Linux 支持和安全修复 | 内置 skill | 内置 skill |

### Academic Research · 学术研究

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **paper-reading** | [本仓库](skills/paper-reading/) | 论文阅读、图表提取、证据检查与 HTML 报告 | 内置 skill ★ | 内置 skill ★ |
| **cheatsheet-creator** *（fork）* | [本仓库](skills/cheatsheet-creator/) | 从课件、作业和往年试卷生成考试速查表 | 内置 skill ★ | — |
| **AI Research skills** | [AI Research](https://github.com/Orchestra-Research/AI-research-SKILLs) | 一个整包：分词、微调、后训练、推理服务、分布式训练与优化；[两端共用 31 项成员](catalog.md#ai-research-members) | 6 个原生插件 | 6 个兼容插件 / 源码 |
| **deepxiv-cli** | [DeepXiv](https://github.com/DeepXiv/deepxiv_sdk) | arXiv / PMC 论文混合检索与阅读 CLI | 精选源码 | 精选源码 |
| **deepxiv-trending-digest** | [DeepXiv](https://github.com/DeepXiv/deepxiv_sdk) | 近期热门论文的 Markdown 摘要 | 精选源码 | 精选源码 |
| **deepxiv-baseline-table** | [DeepXiv](https://github.com/DeepXiv/deepxiv_sdk) | 基于研究论文生成基线对比表 | 精选源码 | 精选源码 |
| **ResearchStudio Idea** | [Microsoft](https://github.com/microsoft/ResearchStudio) | idea_spark、paper_search、scoop_check；完整源码，首次使用准备依赖 | 精选源码 | 精选源码 |
| **ResearchStudio Reel** | [Microsoft](https://github.com/microsoft/ResearchStudio) | paper2assets、paper2poster、paper2video、paper2blog、paper2reel，独立选择 | — | 精选源码 |

### MCP Servers · MCP 服务

| 项目 | 来源 | 功能 | Claude | Codex |
| --- | --- | --- | --- | --- |
| **OpenAI docs** | [OpenAI](https://developers.openai.com/mcp) | OpenAI 官方开发文档 | — | MCP ★ |
| **Playwright MCP** *（fork）* | [本仓库](mcp/README.md) | 独立的 `@playwright/mcp` 服务；与 playwright 插件同名并会遮蔽它，二者只选其一 | MCP | — |
| **Lark / 飞书 MCP** *（fork）* | [larksuite](https://github.com/larksuite/lark-openapi-mcp) | 飞书 / Lark 集成，上游已退役、本 fork 保留；需要 App ID / Secret，每会话约占 1 GB 内存，因此默认关闭。分步指引：[LARK-MCP](docs/LARK-MCP.zh-CN.md) | MCP | — |


完整包成员见 [catalog.md](catalog.md#members)，源码 revision 与适配见 [sources.md](platforms/sources.md)。存储分析的定制记录在 [UPSTREAM.md](skills/storage-analyzer/UPSTREAM.md)，已通过 [khazix-skills#50](https://github.com/KKKKhazix/khazix-skills/pull/50) 提交上游。Context7、Playwright 统一放在开发集成；独立的 Playwright MCP 供不装 playwright 插件的用户使用。

4.2.0 移除了 GitHub MCP 与 github 插件、claude-mem、PUA；六个 AI Research 条目合并为一个整包，Common rules 由写作规则取代。旧 ID 的处理见[迁移说明](docs/migration.md#script-menu-ids)。

## 模型后端 —— 首次使用前的配置

脚本安装器会写入 `~/.claude/profiles/*.json`，但除 `claude` 之外的每个后端都需要先登录、或粘贴一份凭证，`cl_<backend>` 才能用。完整说明见 [docs/BACKENDS.zh-CN.md](docs/BACKENDS.zh-CN.md)。

| 后端 | 安装 | 登录 | 凭证填到哪里 |
| --- | --- | --- | --- |
| `claude` | — | 原生 OAuth | 无需配置 |
| `glm` | —（厂商托管的 endpoint） | — | 你的 BigModel API key → `~/.claude/profiles/glm.json` 的 `.env.ANTHROPIC_AUTH_TOKEN` |
| `or` | —（厂商托管的 endpoint） | — | 你的 OpenRouter key（`sk-or-v1-…`）→ `~/.claude/profiles/or.json` 的 `.env.ANTHROPIC_AUTH_TOKEN` |
| `gpt` | `brew install cliproxyapi` | `cli-proxy-api --codex-login`（一次性浏览器授权） | `~/.cli-proxy-api/config.yaml` 中的一条 `api-keys` → `~/.claude/profiles/gpt.json` 的 `.env.ANTHROPIC_AUTH_TOKEN` |
| `ccr` | `npm install -g @musistudio/claude-code-router`（需要 Node.js >= 22） | `ccr ui` —— 管理界面在 `http://127.0.0.1:3458` | 在 UI 中生成的 CCR client key → `~/.claude/profiles/ccr.json` 的 `.env.ANTHROPIC_AUTH_TOKEN` |

- **`gpt` 有真实的封号风险。** 它通过逆向出来的 OAuth 流程复用消费级 ChatGPT 订阅；使用前请先读 [docs/BACKENDS.zh-CN.md](docs/BACKENDS.zh-CN.md) 里的完整警告。
- **`ccr` 无法自动化。** CCR v3 把配置存在 SQLite 里，因此 providers、client key、agent profile 都必须在 web UI 里手工创建一次。
- **`or` 必须先 `/logout`。** 缓存的 Anthropic OAuth 会话优先级高于 profile 注入的环境变量，因此首次 `cl_or` 之前要在 Claude Code 里执行一次 `/logout`，否则请求仍然会打到 Anthropic。
- **`or` 没有 5h 配额条**，OpenRouter 本身也不存在 5h 滚动窗口可供展示；原因见 [docs/BACKENDS.zh-CN.md](docs/BACKENDS.zh-CN.md)。另外 OpenRouter 官方只*保证* Anthropic 自家模型能走它的原生 Anthropic 端点，因此本 profile 里的 DeepSeek 槽位属于 best-effort，且尚未用真实 key 实测过。
- **`gpt` / `ccr` 在安装器中默认不勾选。** 在 "Model Backends" 分组里勾上即可安装，`--all` 仍然包含它们，已存在的 `~/.claude/profiles/gpt.json` / `ccr.json` 也不会被升级删除。

配好之后，`cl_glm` / `cl_or` / `cl_gpt` / `cl_ccr` 直接以对应后端启动，`cl_switch <name>` 则把它设为裸 `cl` 的默认后端。每次启动都会打印实际使用的后端与模型。想换模型不必改 JSON —— 直接传 claude 自己的参数（`cl_glm --model glm-5v-turbo`），或用 `CL_MODEL=sonnet` 改这一次的默认。推理等级（effort）同理，且每个后端独立：profile 顶层可选 `"effort"` 键（`low|medium|high|xhigh|max`）就是该 launcher 的 `--effort` 默认值 —— 出厂设为 `claude`/`or` = `medium`、`glm` = `xhigh` —— 用 `cl_glm --effort high` 或 `CL_EFFORT=high` 可临时覆盖单次启动。

## 图像生成

[`sinedied/agent-skills`:`image-gen`](https://github.com/sinedied/agent-skills) Skill 由脚本安装器**始终**通过网络安装（**绝不** vendored），同时安装一个仓库自有的包装器到 `~/.claude/scripts/image-gen-openrouter.py`。所有 `cl*` / `cl_*_auto` 启动器共享同一组全局 `~/.claude/skills/` 和 `~/.claude/scripts/` 路径，因此图像生成可在任意后端下工作 —— 而且完全不需要本地代理：包装器用 `openai/gpt-image-2` 直接 POST 到 `https://openrouter.ai/api/v1/images`，出图前先用 `GET /api/v1/images/models` 确认模型可用，确认不了就 fail-closed。上游的 `image_gen.py` 不会被执行（它那套 OpenAI 路由在 OpenRouter 上不存在）；`edit` 改为在同一端点上发送参考图。只需要 `python3`，无其他依赖。**鉴权只读 `~/.claude/profiles/or.json` 里的 OpenRouter key（`.env.ANTHROPIC_AUTH_TOKEN`），没有别的来源** —— 无环境变量兜底、绝不出现在命令行，且**不需要、也不会请求 OpenAI Platform API key**。`--uninstall` 仅在所有权清单、目录布局与注入标记三者一致时才删除该 Skill。完整契约见 [docs/BACKENDS.zh-CN.md](docs/BACKENDS.zh-CN.md)。

## 目录结构

```text
.
├── README.md / README.zh-CN.md   # 用户指南与分类表格
├── AGENTS.md / CLAUDE.md         # 本仓库的工作指令
├── INSTALL.md                   # Agent 引导的安装与更新
├── MAINTAIN.md                  # Agent 修改本仓库的流程
├── catalog.md                   # ID、支持范围、推荐与渠道
├── skills/                      # 自有及定制 skill 的完整源码
├── platforms/
│   ├── claude/                  # Claude 指令、lessons、规则、hooks、设置、skills
│   ├── codex/                   # Codex 指令、lessons、设置、skills
│   └── sources.md               # 外部 revision、成员与适配
├── agents/                      # Fork：搜索 agent
├── profiles/ / claude.zsh       # Fork：模型后端 profile 与 cl 启动器
├── mcp/                         # Fork：Playwright 与 Lark/飞书 MCP 配置
├── scripts/                     # 受控文件操作、小工具、出图包装器
├── lessons.md                   # 本仓库的项目纠错历史
├── docs/                        # 方案、迁移说明、后端与飞书指南
└── install.sh / install.ps1     # Fork：交互式脚本安装器（Claude Code）
```

## 关键机制

- **两条安装路径**：脚本安装器按菜单选择一次性写入 `~/.claude`；agent 引导路径在对话中列出编号选项并记录用户选择。两者读取同一套 `platforms/claude/templates/` 模板。
- **独立记忆**：Claude 使用自己的全局 `lessons.md` 与项目 `memory/MEMORY.md`；Codex 使用自己的全局 `lessons.md` 与项目根目录 `lessons.md`。模板和真实历史各自保留，仅在缺少全局记录时创建空白文件。
- **规则与状态栏**：Claude 提供一份写作规则，以及独立的 Python / TypeScript / Go 规则；渐变状态栏展示模型、目录、venv、Git、上下文、当前后端的 5 小时额度（Anthropic 或 GLM），以及正在运行的 subagent / in-process teammate 及其上下文占用。Codex 使用原生状态栏与子 agent 能力，本仓库不再安装自定义角色预设。
- **配置管理**：edit-config 跟踪 main 并记录实际 revision；`/update-config` 重跑脚本安装器。两条路径共用 `agent-config/selection.json`。来源策略冲突时明确选择是否迁移，保留已有选择与定制。
- **目录同步检查**：`scripts/check-catalog-sync.sh` 校验 catalog.md 与两个脚本安装器一致，`scripts/check-readme-sync.sh` 保持两份 README 对齐。
- **限定修改范围**：保留用户定制、凭据、hooks 和记忆数据库，通过备份与文件归属支持更新和明确移除。ResearchStudio Idea/Reel、PPT Master 只准备完整源码，运行依赖留到首次使用。

## 默认设置

下表来自当前模板，仅在选择对应项时应用。已有覆盖值会保留并报告差异。基础设置、权限、状态栏、lessons 分开选择；关闭 Codex 自动导入是安装前提。Agent 会先核实本机版本是否支持相关设置；脚本安装器在 Claude Code 低于 2.1.80 时把 `auto` 降级为 `bypassPermissions`。

| Agent | 配置键 | 模板值 | 作用 |
| --- | --- | --- | --- |
| Claude | `model` / `effortLevel` | `opus` / `xhigh` | 模型与推理强度 |
| Claude | `tui` | `fullscreen` | 全屏终端界面 |
| Claude | `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `1` | 开启 agent teams 实验功能 |
| Claude | `env.API_TIMEOUT_MS` / `env.FORCE_AUTOUPDATE_PLUGINS` | `3000000` / `1` | Fork：更长的 API 超时与插件自动更新 |
| Claude | `includeCoAuthoredBy` | `false` | Fork：未选 Co-authored-by 时不加共同作者 |
| Claude | `permissions.defaultMode` | `auto` | 独立权限模板还包含宽泛的工具放行规则 |
| Codex | `model` / `model_reasoning_effort` | `gpt-5.6-sol` / `max` | 模型与推理强度 |
| Codex | `web_search` | `live` | 实时网络搜索 |
| Codex | `features.multi_agent` / `concurrent_reasoning_summaries` | `true` / `false` | Agent 协作与摘要行为 |
| Codex | `shell_environment_policy.inherit` | `all` | 继承 shell 环境 |
| Codex | `approval_policy` / `sandbox_mode` | `never` / `danger-full-access` | 单独选择的高自主权限 |
| Codex | `desktop.external-agent-import-sync-enabled` | `false` | 安装内容由明确选择控制 |

实际配置及逐项操作见 [Claude](platforms/claude/README.md#configuration) · [Codex](platforms/codex/README.md#configuration)，当前平台验证范围见 [迁移说明](docs/migration.md)。

## 自定义

你可以直接让 agent 维护仓库本身。它会遵循 [MAINTAIN.md](MAINTAIN.md)，修改完整内容和安装办法，并同步目录、两份 README 与脚本安装器。

| 请求示例 | Agent 负责修改的内容 |
| --- | --- |
| “加上这个 skill，说明什么时候用” | 自有 skill 保存源码，第三方原版记录上游安装配方，并维护平台支持、分类与用途 |
| “更新 ResearchStudio” | 记录的上游 revision、成员和必要适配，在隔离环境验证 |
| “修改这个 skill / 删除这个选项” | 当前源码与引用；删除记录说明旧 ID 的处理，不静默卸载用户副本 |
| “Claude / Codex 推荐这些 skills” | 仅修改对应 agent 的作者推荐标记 |
| “添加一种语言规则” | `platforms/claude/templates/rules/<lang>/` 及目录条目 |
| “调整 Claude / Codex 指令或 lessons 策略” | 对应 agent 的模板与配套记忆规则 |

查询和修改已安装的配置时使用 [edit-config](skills/edit-config/SKILL.md)，修改操作遵循 [INSTALL.md](INSTALL.md)。根目录 AGENTS.md、CLAUDE.md、lessons.md 属于本仓库；待部署的全局文件在各平台的 templates 中。

## 致谢

- [Claude Code in Action](https://anthropic.skilljar.com/claude-code-in-action) — Anthropic Academy 官方课程
- [为 10 个 Claude Code 打工](https://mp.weixin.qq.com/s/9qPD3gXj3HLmrKC64Q6fbQ) by 胡渊鸣 — 多实例并行实践
- [Harness Engineering](https://openai.com/index/harness-engineering/) by OpenAI
- [Anthropic Engineering](https://www.anthropic.com/engineering) / [OpenAI Engineering](https://openai.com/news/engineering/)
- [Claude Code Best Practice](https://github.com/shanraisshan/claude-code-best-practice) by shanraisshan
- [Claude How To](https://github.com/luongnv89/claude-howto) by luongnv89

## Fork 特有功能

本 fork 在上游基础上新增：

- **脚本安装器**（`install.sh` / `install.ps1`）：两级交互菜单、插件对账、`--only` / `--list-ids`、`--dry-run` / `--uninstall`
- **Shell Wrapper**（`claude.zsh`）：`cl`/`cl_auto`/`cl_switch`/`cl_profiles`，并为每个 profile 自动生成 `cl_<backend>`
- **模型后端**（`profiles/*.json`）：每个后端一个 JSON —— `claude`、`glm`、`or`、`gpt`、`ccr`。往 `~/.claude/profiles/` 丢一个新 JSON 即可新增后端，无需改代码。详见 [docs/BACKENDS.zh-CN.md](docs/BACKENDS.zh-CN.md)
- **搜索 Agent**（`agents/search.md`）：Jeff，只读网络搜索专家
- **系统提示**（`system-prompt.txt`）：自定义行为准则
- **Lark / 飞书 MCP**（`mcp/`）：可选，上游已退役、本 fork 保留；见 [docs/LARK-MCP.zh-CN.md](docs/LARK-MCP.zh-CN.md)
- **额外目录条目**：feature-dev、ralph-loop、commit-commands、ecc 插件，update-config 与 cheatsheet-creator skill，以及 6 项 Matt 精选子集
- **Co-authored-by**：安装器选项，用于 commit 归属

## License

本仓库采用 MIT 许可，内置和获取的第三方组件保留各自许可。**lieflat-charts** 使用 [PolyForm Noncommercial 1.0.0](https://github.com/larashero3-dotcom/lieflat-charts/blob/main/LICENSE)，仅限非商业用途；只有选择后才从上游获取，本仓库不做再分发。

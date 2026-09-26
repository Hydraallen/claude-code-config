# 变更记录

## [4.1.0] - 2026-09-27

### Features
- Claude lessons hooks：Claude Code（已在 2.1.220 与 2.1.280 上核实）对超过 10,000 字符的 SessionStart hook 输出只把前 2,000 字符的预览交给模型。`platforms/claude/templates/lessons-hooks.json` 中的启动与 compaction 两条命令现在只在 `lessons.md` 小于 9,000 字节时输出全文；否则输出文件路径和字节数，并要求模型用 Read 工具读取（会话开始时读全文，compaction 后读与当前任务相关的条目）。hook 不再要求模型确认已加载 lessons。
- Codex AGENTS 模板：全局与项目 lessons 默认追加；新纠正重复已有规则时扩展原条目，合并或删除条目只在用户要求时进行。Self-correction 步骤按同一规则执行。Rule Set 一行删除「This repository does not install additional language skills implicitly」：该模板部署为全局 AGENTS.md 后，「this repository」会被读作当前打开的项目。
- `platforms/claude/README.md` 记录 hook 输出与 skill 列表的长度上限，以及部署 lessons、skills 或插件后的核对方法。

### Bug Fixes
- `storage-analyzer`：Linux 上 HTML 报告的按钮、说明、确认框和状态提示都使用 macOS 的文件管理器名「访达」；`system.os` 为 `Darwin` 时还会得到 Windows 的「资源管理器」。报告模板现在按 `system.platform`（`scan.py` 写入的 `sys.platform`）选择名称：macOS 为访达，Windows 为资源管理器，Linux 及其他平台为文件管理器。analysis JSON 缺少 `platform` 时按 `system.os` 整词匹配。
- `storage-analyzer`：Linux 上根文件系统在「其他磁盘」中重复出现。原因是 `disk_name` 使用设备名（`/dev/nvme0n1p2 (/)`），而 `system.disks` 中对应条目使用挂载点（`/`）。根盘条目现在与 `disk_name` 同名；macOS 与 Windows 原本一致。
- Claude settings 模板：删除 `env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING`。Claude Code 只在 Opus 4.6 与 Sonnet 4.6 上读取该变量；模板的 `opus` 别名解析为 Claude Opus 5.5，其 thinking 始终开启，深度由 `effortLevel` 设置。两份 README 的默认值表删除对应行。
- Claude 全局指令模板：删除 `Extended thinking: ultrathink`（Claude Code 只在用户消息中识别该关键词）、三步以上任务一律进入 Plan Mode 的规则、「Highest Priority」标题标注和「When in doubt, treat it as a correction」；lessons 一行改为说明 hook 的实际行为。
- `adversarial-review`（Claude）：Codex reviewer 显式使用只读 sandbox（只有需要运行测试的 reviewer 使用 `-s workspace-write`），stdin 重定向到 `/dev/null`；reviewer 以最终消息返回审查发现，由 `codex exec -o` 保存，不修改被审代码，也不把审查发现写入文件；输出只有计划或确认时记为该 reviewer 失败。删除 `TaskOutput` 轮询说明（Claude Code 2.1.280 已不提供该工具）和 Claude Code 不识别的 `schedule` frontmatter 字段；`brain/principles.md` 改为可选。`UPSTREAM.md` 已记录这些修改。
- `storage-analyzer`：更正 `references/linux.md` 与 `scan.py` 提示中的 snap 清理建议（`refresh.retain=2` 在 classic 系统上不减少保留数，改为删除 disabled revision），并补充有条件的 `/var/tmp` 说明；只读规则限定为被分析的数据，skill 自身的输出与本地服务不在此限；`server.py` 的路径白名单与 `app_paths` 规则按实际实现描述（装在 `Program Files` 的 Windows 应用不给 `app_paths`）；平台状态改为引用 `UPSTREAM.md` 的验证状态；触发描述按意图分类。`UPSTREAM.md` 已记录这些修改。
- `paper-reading`：删除 SKILL.md、references 与校验脚本报错信息中与旧版本对比的措辞（如「original technical template」「original list template」）、强制填写的作图审计表（第 7 节改名为「Choose and render visuals」），以及证据坐标中的运行类证据（该流程不运行实验）；写明快速概览类请求使用同一深度。
- 文档：`AGENTS.md` 说明项目 `lessons.md` 的读取方式（同一主题以较晚条目为准，已退役安装器与分支的条目用于追溯，与当前文件不一致时以当前文件为准）；项目 `lessons.md` 文件头写明两端各自的全局 lessons 位置，并删除模板示例块；catalog.md、docs/agent-setup-spec.md、docs/migration.md、scripts/README.md 与 TypeScript hooks 规则的措辞更正（Stop hook 在每次回复结束时运行）。

### Design Rationale
- 除 2026-09-17 的两项 storage-analyzer 修复（文件管理器名称与根盘）外，模板、skill 与文档的修改来自 Claude Code 的 `/claude-api prompt-audit`，目标模型为 Claude Fable 5.1 与 Claude Opus 5.5。每项修改都对应一条发现；涉及 Claude Code 行为的发现已对照 Claude Code 2.1.280 二进制和 claude-api 迁移文档核实。环境事实、用户偏好、精确命令和项目历史保持不变。
- 上限由 Claude Code 设定，所以 hook 按文件大小选择输出方式；用户可以保留完整的 lessons 文件，内容不会被截成 2,000 字符的预览。
- Claude 模板中的删除只针对 Claude 模型核实。Codex AGENTS 模板保留「(Highest Priority)」标题与计划要求，`adversarial-review` 的 Codex 历史副本不变。
- 项目 `lessons.md` 按 MAINTAIN.md 保留原始条目；条目的优先关系由 AGENTS.md 说明，不改写条目本身。

### Notes & Caveats
- 已安装的 CLAUDE.md、AGENTS.md 在 edit-config 合并新模板之前保持原文，ultrathink、Plan Mode 两行在此之前仍然存在。`scripts/managed_files.py merge` 只新增或更新键、追加 hook 条目，因此合并新的 settings 与 lessons-hooks 模板后，已安装的 `env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` 仍然保留，旧的 SessionStart `startup`、`compact` 条目与新条目同时存在；需经用户确认后从 settings.json 中另行删除。
- `lessons.md` 达到 9,000 字节时，其内容只能通过 hook 输出要求的 Read 调用进入上下文，每次会话开始都读取全文并占用相应上下文；文件小于该值时恢复直接注入。
- storage-analyzer 的磁盘修复修改了扫描输出，修改前生成的 analysis JSON 仍会重复列出 `/`，重新扫描即可。文件管理器名称与根盘两项修复在 Ubuntu 24.04.4 上验证了静态报告与服务模式渲染；macOS 与 Windows 只用代表性的 `system` 数据块做了渲染检查。本版本的 storage-analyzer 修改都不在 khazix-skills#50 中，已记录在 `skills/storage-analyzer/UPSTREAM.md`。
- 提示词修改没有在实际任务上做行为对比。

## [4.0.0] - 2026-09-17

### Features
- 仓库改名为 **awesome-agent-config**，统一 Claude/Codex 配置发布在 **main**。旧 Claude main 保存为 `archive/legacy-claude`，其他暂存分支统一使用 `archive/legacy-` 前缀；保留其提交历史及已有 tags/releases。
- 用 agent 引导的对话安装替代两套独立安装器。当前 agent 检测环境，直接在聊天中按分类完整展示支持项，通过原生多选问答或编号回复收集选择。
- 保留完整双语 README、11 个分类、使用说明与表格。共享目录包含 39 个活动 ID，采用当前作者推荐：Claude 20 项、Codex 18 项。
- 优先采用兼容原生插件及上游安装方式；自有与定制 skills 保留在仓库并注明来源。AI Research 为一个 31 项整包，handoff 仅通过 Matt 提供。
- 共享 edit-config 处理配置查询、增删改、修复与更新；它和两端全局模板均指向新仓库 main，识别旧仓库名并保留明确的来源策略。
- 两端指令与 lessons 独立。Claude 完整英文写作规则替代原 Common rules，语言规则仍可单选；Codex 安装关闭外部 agent 自动导入，保留原生子 agent 功能并移除自定义角色预设。

### Design Rationale
- 共享目录与对话流程让 agent 维护平台配方，减少独立安装框架与第三方源码副本的维护。
- 统一 main 作为当前安装与开发来源，归档分支和历史 provenance 用于追溯，不构成运行依赖。
- 推荐表达作者偏好，实际安装和修改范围仍由用户选择、文件归属与现有定制决定。

### Notes & Caveats
- **安装方式变更：** install.sh / install.ps1 仅说明 agent 入口并以状态码 2 退出。请使用 README 请求和 INSTALL.md，旧菜单参数不再安装配置。
- Lark/Feishu MCP、Claude-Mem、所有 PUA 变体、GitHub MCP 及其插件替代渠道、原 Common rules、Codex 角色预设从活动安装范围退役；旧更新 skills 迁移至 edit-config。已有安装、凭据、hooks、记忆及修改文件，仅在明确请求并核实归属后变更。
- 仓库改名不会自动将已安装的开发分支、固定 revision、fork 或本地来源迁移至 main。按[来源迁移说明](docs/migration.md#repository-identity)处理，保留旧来源记录和整包的部分选择。
- ResearchStudio Idea/Reel、PPT Master 只安装源码与必要适配，运行环境留到首次使用。插件可用性取决于 client/账号；受影响配置已在隔离 macOS 目录验证，原生 Windows/WSL 与凭据类集成仍需对应环境验收。

## [4.0.0-dev.7] - 2026-09-17

### Features
- 从两端安装范围退役 GitHub MCP，移除剩余目录及 README 条目、推荐、MCP 安装配方和该项的 GitHub 插件替代渠道。
- 活动目录现为 39 个 ID，推荐草案为 Claude 20 项、Codex 18 项；两端平台说明均将旧 GitHub 选择指向迁移说明。

### Design Rationale
- 移除集成时一并清理替代安装渠道，避免普通更新通过插件重新装回已退役条目。

### Notes & Caveats
- 保留现有服务、插件、共享连接和凭据。用户明确指定目标并核实归属后才卸载已有内容；普通 Git/gh 工作流和代码审查 skills 继续可用。
- 两端模板原本均不含 GitHub 服务配置，其他 MCP 配方、源码 revision 与历史记录保持不变。

## [4.0.0-dev.6] - 2026-09-17

### Features
- 退役 Codex 的 explorer、reviewer、docs-researcher 预设，移除三份角色模板、注册 patch、Core 条目与推荐。
- 同步目录、双语 README 与平台说明。活动目录现为 40 个 ID，推荐草案为 Claude 20 项、Codex 19 项。

### Design Rationale
- 使用原生子 agent 和已选 skills 按任务分工，减少固定模型角色及其并发、嵌套设置的维护。

### Notes & Caveats
- 保留原生多 agent 功能。已有自定义角色与共享设置，仅在明确要求卸载并核实归属后处理；迁移说明覆盖注册、文件及原配置值。
- 保留历史 provenance 和 changelog，其他安装选择与推荐标记保持不变。

## [4.0.0-dev.5] - 2026-09-17

### Features
- 在当前对话直接展示目标 agent 的完整安装选项、用途、作者推荐与实际安装状态。
- 优先使用宿主实际提供的多选问答；只有单选/文本问答或没有问答工具时，接收多个编号。同步 README 请求、仓库入口与 edit-config 的交互说明。

### Design Rationale
- 用户应在同一段对话中完成选型与安装；生成选型文档不能完成这项交互。两端仍读取同一份目录。

### Notes & Caveats
- 工具能力与限制取决于当前 client 和模式。沿用明确选择，未回复或预选值不构成安装授权。仅按用户要求导出选型文档或安装报告；安装记录仍正常维护。
- 目录条目、推荐草案与安装配方保持不变。

## [4.0.0-dev.4] - 2026-09-13

### Features
- 从活动目录、安装配方和模板移除 Lark/Feishu MCP、Claude-Mem 与 PUA 三语言 skills。
- Claude 原八个 Common rules 替换为一份完整英文写作 rule，保留全部给定示例；语言规则独立选择，移除失效 Common 引用及对未提供 skills/hooks 的假设。
- 两端更新 skill 统一为共享 edit-config，处理配置查询、增删改、修复与更新；全局模板提供调用入口，跟踪 agent-config-for-agents，查询只读。
- Context7 参考模板与 HTTP 配方对齐，统一配置入口说明；按当前发布分支的安装菜单默认项整理 Claude 20 项、Codex 22 项推荐草案，待作者最终确认。

### Design Rationale
- 一份配置管理 skill 避免两端更新规则不一致；明确的来源检查保留用户已选择的 fork、固定版本和本地来源策略。
- 写作要求独立成 rule，语言规则按需选择；推荐映射记录在当前目录，安装无需依赖旧分支。

### Notes & Caveats
- 活动目录现为 43 个 ID；退役条目、Common rules 和旧更新 skill 路径均有迁移说明，不自动删除已有安装、定制或记忆。
- 推荐依据为一致的 Bash/PowerShell 菜单默认值；权限从旧基础配置拆分、新写作 rule 替代 Common 的映射已注明，推荐不构成安装或提升权限的授权。
- 源码变更在隔离 home 验证；Windows/WSL 执行和凭据类集成仍需对应环境。

## [4.0.0-dev.3] - 2026-09-12

### Features
- AI Research 合为一个选择，通过六个上游插件在 Claude / Codex 提供同样的 31 项；成员继续列全，活动目录现为 46 个 ID。
- Codex 的 AI Research、Anthropic 文档四件套、frontend-slides 优先采用已验证插件。OpenAI 官方/curated 插件从账号实际目录发现，优先复用同等文档能力、Superpowers 及可用的 GitHub 插件。
- 新增集中的 Codex 插件说明，区分发布方，记录原生 selector 与源码/MCP 后备原因；验收同时检查安装状态和实际 skill 加载。

### Design Rationale
- 保留对话安装与 README 原有分类，减少顶层选择；插件生命周期交给原生机制，agent 维护上游配方与选择记录。
- 保持真实兼容性、所选范围和固定 revision；插件命令成功不等于 skill 已加载。

### Notes & Caveats
- 旧六组 ID 与 Codex 24 项选择在明确迁移前保持原范围；新整包增加七项，组件归属和部分失败可继续追溯。
- Codex CLI 0.153.4 忽略 Humanizer、PPT Master 的根目录 skill 入口；PPT Master 的嵌套 Git 来源还绕过外层 revision 约束。两项继续从上游源码安装；Matt、examples、PUA、Playwright 保持既有约束。
- 已在 macOS 隔离 Codex home 验证原生安装、实际加载和资源一致性；这些检查不覆盖 OAuth 集成、其他 OS 和业务运行依赖。IDE extension 当前不支持插件。

## [4.0.0-dev.2] - 2026-09-12

### Features
- 恢复完整双语 README，包括原有 11 类、使用说明、表格、示例、设置与自定义；51 个活动目录条目采用相同分类顺序。
- 安装与更新独立于历史分支，记录仓库来源及 branch、default-branch、pinned 或 local 更新策略，两端更新 skill 都读取该记录。
- 新增 MAINTAIN.md，让 agent 联动维护完整 skills、上游配方、推荐与双语 README，并明确处理退役 ID。
- 分开 Claude / Codex 空白 lessons 模板，创建时必须指定 agent；各自全局指令及项目记忆规则独立保留。
- Humanizer、Humanizer-zh、neat-freak 原样副本改为上游安装配方；自有和明确维护的定制 skills 保留在仓库并注明来源。
- handoff 合并到 Matt 包并使用上游版本，移除独立选项和本地副本；Codex 的 Matt 精选包现为 20 项。

### Design Rationale
- 当前仓库是后续开发依据。历史映射证明首次合并的完整性，可继续追溯，但不冻结之后的 skill 修改。
- 保留面向用户的详细指南，由 agent 承担平台检测、解释和安装命令的维护。

### Notes & Caveats
- 现有 lessons 不变；直接调用工具需使用 `seed-lessons --agent claude` 或 `--agent codex`。
- 旧安装记录更新前需补齐可核实的仓库来源；来源缺失或不兼容时不猜测历史分支。
- 已有独立 handoff 与第三方副本等用户选择后才迁移；Humanizer 当前上游为 3.0.0，迁移前说明与原内置 2.2.0 的变化。
- 本次不归档分支、不修改远端默认分支；过渡期请分享带 ref 的当前 README 页面 URL，或直接打开对应 checkout。

## [4.0.0-dev.1] - 2026-09-12

### Features
- Claude 与 Codex 共用对话安装流程：检测环境，按分类完整列出带编号、作者推荐标记的目录，再执行用户选择。
- 合并 main v3.2.0 和 codex v2.11.0 的 skills。五份相同 payload 共用源码，五份平台差异独立保留；外部来源、固定版本和精选成员有明确路径。
- 优先使用原生插件/MCP 管理；小工具负责受控复制、JSON/TOML 局部合并、备份、源码适配和 MCP 初始化检查。
- 基础设置、权限、状态栏、记忆 hooks 和子 agents 分开选择；Codex 自动导入独立于基础设置关闭。

### Design Rationale
- 由已有 agent 解释平台差异、理解用户选择，避免再维护终端菜单、二进制发布或包解析框架。
- 一份 Markdown 目录维护两端独立的作者推荐。作者尚未指定的标记留空。
- 原生渠道迁移保留已选范围和 revision，尤其是 Codex 的 Matt v1.1.0 与定制 handoff。

### Notes & Caveats
- 开发分支基于 main，两个发布分支均未合并或替换。详见[迁移说明](docs/migration.md)与[来源映射](docs/source-provenance.json)。
- install.sh/install.ps1 只显示对话入口并返回退出码 2，旧菜单参数不再修改配置。
- 保留用户定制、凭据、真实 lessons 与记忆数据库。更新不会卸载未提到的项；卸载需要明确请求与归属核对。
- ResearchStudio Idea/Reel、PPT Master 只安装完整源码及必要适配，运行依赖留到首次调用。
- 部署显式读取 lessons 的指令后，才移除确切的旧 model_instructions_file = "lessons.md" 设置。
- Windows/WSL 原生命令、凭据类集成与 Claude-Mem 完整生命周期仍需对应环境验证。新开发验收脚本保留在仓库之外，相关既有 skill 测试继续保留。

历史版本：[Claude](platforms/claude/CHANGELOG.previous.zh-CN.md) · [Codex](platforms/codex/CHANGELOG.previous.zh-CN.md)。

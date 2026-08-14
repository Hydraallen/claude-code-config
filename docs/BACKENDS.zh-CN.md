# 模型后端

Claude Code 只会说 Anthropic 协议。因此每一个非 Claude 模型都必须经过一层协议转换
才能接进来。本仓库把每一种接法都抽象成一个 **profile**：`~/.claude/profiles/` 下的
一个 JSON 文件，由 `claude.zsh` 加载。

```
~/.claude/profiles/
  claude.json   native OAuth, zero config
  glm.json      Zhipu GLM Coding Plan (vendor-provided Anthropic endpoint)
  gpt.json      ChatGPT subscription via a local CLIProxyAPI
  ccr.json      claude-code-router gateway — several providers in one /model list
~/.claude/default-profile      which backend a bare `cl` uses
```

## 命令

| 命令 | 作用 |
|---|---|
| `cl` | 用 `default-profile` 启动 |
| `cl_auto` | 同上，附带 `--dangerously-skip-permissions` |
| `cl_claude`、`cl_glm`、`cl_gpt`、`cl_ccr` | 强制指定某个后端 |
| `cl_<name>_auto` | 同上，跳过权限确认 |
| `cl_switch <name>` | 修改默认后端 |
| `cl_stop [<name>\|--all]` | 停止启动器拉起的代理服务 |
| `cl_profiles` | 列出所有后端、它们的标签，以及各自是否就绪 |

`cl_<name>` 是在 source 时根据 profiles 目录里的内容动态生成的 —— 新增一个后端
永远不需要改 `claude.zsh`。

每次启动都会打印所用的后端和最终解析出的模型，例如
`cl_glm: backend 'glm' (https://open.bigmodel.cn/api/anthropic, 20 vars)`，随后
`cl_glm: model opus -> glm-5.3`。

### 不改 JSON 也能选模型

profile 的 `opus` 槽位是默认值。可以按次启动覆盖它：

```bash
cl_glm --model glm-5v-turbo     # any exact model id the backend accepts
cl_glm --model sonnet           # or an alias, resolved by the profile's slots
CL_MODEL=sonnet cl_glm          # change the default alias for one launch
```

你自己参数里的 `--model` 永远优先于启动器的默认值。

环境变量只在单次启动期间注入，结束后精确还原，包括那些原本未设置的变量。不会向
`settings.json` 写入任何内容。

## 各后端的配置

### `claude` —— 官方订阅

无需任何配置。它还会在运行期间*清除* `ANTHROPIC_BASE_URL` 等变量，这样在 `.zshrc`
里导出的网关 URL 就无法悄悄劫持你的 Claude 订阅。

### `glm` —— 智谱 GLM Coding Plan

把你的 BigModel API key 粘贴到 `~/.claude/profiles/glm.json` 的
`.env.ANTHROPIC_AUTH_TOKEN`，然后：

```bash
cl_glm
```

Coding Plan 只覆盖 **`glm-5.3`（1M 输入 / 128K 输出）、`glm-5-turbo`（200K）、
`glm-4.7`（200K）** 这三个模型 —— opus、sonnet 和 fable 都路由到 `glm-5.3`，haiku
路由到 `glm-5-turbo`（`glm-4.7` 计划内覆盖，但不绑定到任何槽位）。
`fable` 是 Claude Code 的后台槽位（compact、会话标题、配额探测）。它和其他别名一样可以
显式选择，但客户端还会拿它发**你没主动发起**的请求 —— 所以留空会在这些请求上失败，
字面量 `claude-fable-5` 直接发出去然后 400。
`glm-5` 和 `glm-5.1` 在上游会被自动路由到 `glm-5.3`，所以不要固定写它们。
视觉模型 **`glm-5v-turbo`（200K）** 没有自己的槽位；用
`cl_glm --model glm-5v-turbo` 访问。

#### 解锁 glm-5.3 的 1M 上下文

对于任何它不认识的模型 id，Claude Code 都会硬编码 200K 的上下文上限，而它的注册表里
没有任何 `glm-*` id —— 所以不做处理的话，客户端会在 200K 就压缩上下文，并把输出限制在
默认的 32K，白白浪费掉 glm-5.3 实际能接受额度的五分之四。因此 profile 设置了：

| 变量 | 值 | 原因 |
|---|---|---|
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `1000000` | 客户端只对非 `claude-*` 的模型 id 认这个值；这就是官方留的逃生口 |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `1000000` | 压缩窗口取 `min(contextLimit, thisVar)`，所以单独设它是空操作 —— 两个都必须设 |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | glm-5.3 输出上限是 128K；`131072` 会被客户端截断，它最多只接受 `128000` |

服务端不需要任何额外配置 —— 不用加 header，模型 id 后面也不用加 `[1m]` 后缀。
**不要**把模型名改成 `glm-5.3[1m]`：那不是一个 Z.ai 模型代号，而且它会被原样发到线上。

> **注意 —— 一个上限，三个模型。** `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 是一个客户端级别的
> 全局值，不是按槽位区分的。它是按 glm-5.3 配的，glm-5.3 同时占 opus 和 sonnet 两个槽位、
> 也是启动器的默认模型。只有 **haiku（`glm-5-turbo`，200K）** 偏小：切到它时客户端会放任
> 上下文涨过服务端能接受的长度，而自动压缩救不了你。haiku 会话请控制在 200K 以内，或者
> `cl_switch` 到一个尺寸匹配的后端。

文档：<https://docs.bigmodel.cn/cn/coding-plan/tool/claude>

状态栏也会读这个后端的 5h 额度，见下方[状态栏里的额度](#状态栏里的额度)。

### `gpt` —— ChatGPT Plus/Pro 订阅

底层是 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)，它在
`127.0.0.1:8317` 上暴露一个 Anthropic 兼容的 `/v1/messages`。

> **动手之前，先读完本小节末尾的风险说明。**

> 该后端没有额度端点，因此 `gpt` 终端的状态栏**不渲染额度段**，其余各段不受影响。
> 详见[状态栏里的额度](#状态栏里的额度)。

#### 第 1 步 —— 安装

```bash
brew install cliproxyapi
```

**二进制名称取决于你的安装方式。** Homebrew 装出来的是 `cliproxyapi`；用
`go build -o cli-proxy-api ./cmd/server` 从源码构建得到的是 `cli-proxy-api`。
profile 在 `service.bins` 里两个都列了，会用 `PATH` 上先找到的那个，所以两种都能跑 ——
但上游文档是按 `cli-proxy-api` 写的，如果你是 brew 安装的，它给出的每条命令都要
把名字换成 `cliproxyapi`。

#### 第 2 步 —— 在安装器里选 `gpt`（key 会被自动协调）

选中 `gpt` 之后，安装器的 `configure_gpt_backend` 会替你协调 CLIProxyAPI 的 key
并归一化配置 —— **你不再需要自己编造或粘贴 key。** 它按下面的严格优先级解析 key
（配置优先）：

1. **配置中的 key。** `~/.cli-proxy-api/config.yaml` 里 `api-keys:` 的第一个条目
   在它是真实值（残留的占位符会被拒绝、不会被复用）时具有最高优先级，是权威来源。
2. **profile token。** 配置里没有可用的 key 时，复用
   `~/.claude/profiles/gpt.json` 里 `.env.ANTHROPIC_AUTH_TOKEN` 的值。
3. **生成。** 两者都解析不出来时，生成一个新的 32 字节（64 个小写十六进制字符）key。

解析出的 key 会同时写进 `config.yaml` 和 `gpt.json`，保持两者同步一致。任何已存在的
`config.yaml` 都会先被复制成带时间戳的 `config.yaml.YYYYMMDDHHMMSS.bak`（模式 `600`），
然后被**归一化**成下面这个仅监听环回地址的形态；如果文件已经归一化，就不会产生备份。
`~/.cli-proxy-api` 目录以模式 `700` 创建；`config.yaml` 和 `gpt.json` 都保持模式 `600`。

归一化后的配置恰好是：

```yaml
host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "<解析出的 key>"
```

**只有一行是可选的：** 当解析出了一个出站 `proxy-url`（见下面的
「第 4b 步 —— 出站代理（`proxy-url`）」），会在 `auth-dir` 和 `api-keys` 之间插进
第 6 行 `proxy-url: "…"`；没解析出来时，上面这个 5 行形态就按字节原样输出，不变。

其中三个值是关键：

- **`api-keys` 必须非空。** 如果这个列表为空或者根本没写，CLIProxyAPI 会直接把它的
  鉴权 provider 整个注销掉，**此后每一条 `/v1/*` 路由都会接受任何请求，带任何 token
  或者干脆不带 token** —— 它是 fail open，不是 fail closed。
  别把 `api-keys` 和 `remote-management.secret-key` 搞混了，后者守的是另一套 API，
  两者故意是分开的。
- **`host: "127.0.0.1"`** —— 默认值是 `""`，也就是绑定*所有*网络接口。再叠加上面那个
  fail-open 行为，默认配置等于把一个不需要鉴权、直通你 ChatGPT 订阅的代理挂到了局域网上。
- **`port: 8317`** 与启动器和 profile 对齐。

启动器总是用 `--config "$HOME/.cli-proxy-api/config.yaml"` 启动代理，所以不管你怎么
安装，这个确切路径都必须存在 —— Homebrew 自己的默认路径
（`$(brew --prefix)/etc/cliproxyapi.conf`）*不是*启动器使用的那个。配置缺失/不可读，
或者代理在启动过程中退出，都会**直接退出**，而不是回退到默认值。

#### 第 3 步 —— 登录一次（手动）

```bash
cliproxyapi --codex-login            # or ./cli-proxy-api --codex-login
```

这一步**仍然是手动** —— 安装器无法替你完成 OAuth。浏览器会打开；登录你的 ChatGPT
账号并授权。OAuth 回调落在 **`http://localhost:1455/auth/callback`**，所以 1455 端口
必须空着 —— 如果被别的程序占了，用 `--oauth-callback-port <n>` 改掉。无图形界面的
机器上用 `--no-browser`（会打印 URL）或者 `--codex-device-login`。

凭证会以 `codex-<hash>-<email>-<plan>.json` 的形式写进 `auth-dir`。多个账号会产生
多个文件，并以 round-robin 方式做负载均衡。

#### 第 4 步 —— 启动

```bash
cl_gpt            # 或 cl_gpt_auto
```

`cl_gpt` 会先对 `http://127.0.0.1:8317/healthz` 做健康检查，只在需要时才在后台拉起
代理，等它起来，日志写到 `~/.claude/logs/cli-proxy-api.log`。

> **Windows 限制。** GPT 自动配置以及 `cl_gpt` / `cl_gpt_auto` 启动器仅支持
> Bash/Zsh。`install.ps1` 会报告这一点并指回 `docs/BACKENDS.md`；它**不会**创建或
> 写入 `~/.cli-proxy-api/config.yaml`。

注意 `/healthz` 只要 HTTP 监听器起来了就返回 200 —— 它完全不能说明你的凭证是否加载
成功、上游是否可达。健康检查是绿的但请求全失败，说明第 3 步没生效。

#### 第 4b 步 —— 出站代理（`proxy-url`，可选）

当你在公司/VPN 代理后面时，CLIProxyAPI 可以把它的上游 HTTPS 请求经过一个本地转发器
发出去。安装器会协调 `config.yaml` 里一个可选的顶层 `proxy-url:` 标量；它从不自己编造
取值。优先级和 key 一样（配置优先）：

1. **配置里的 `proxy-url`。** `~/.cli-proxy-api/config.yaml` 里的顶层 `proxy-url:` 在
   它是合法 URL 时是权威来源，优先级最高。残留的占位符会被拒绝、不会被复用。
2. **`GPT_PROXY_URL` 环境变量。** 配置里没有 `proxy-url:` 时，显式的 `GPT_PROXY_URL`
   会被采用。
3. **省略。** 两者都解析不出来时，这一行就直接不写，CLIProxyAPI 直连上游。

```bash
# 一次性：给这次安装显式传一个上游代理
GPT_PROXY_URL="http://user:secret@127.0.0.1:10808" ./install.sh
```

接受的协议是 `http://`、`https://`、`socks5://`、`socks5h://`。URL
**可以携带凭证**（`scheme://user:pass@host:port`），且**绝不会被打印** ——
不在正常输出里，不在警告里，也不会在 `set -x` 下泄露（协调器会在内层解析时抑制
xtrace）。它通过临时文件重定向捕获，取值绝不经过 stdout。把它写进
`config.yaml`（模式 `600`）或者用 `GPT_PROXY_URL` 一次性传入都行。

**标准的代理环境变量被故意不自动持久化。** `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`
会被解析器忽略 —— 它们通常带的是临时凭证，把它们静默写进 `config.yaml` 既会破坏
幂等性，又会让密钥落盘泄漏。请用 `GPT_PROXY_URL` 或者手写的 `proxy-url:` 显式开启。

**已存在但格式错误的 `proxy-url` 会安全失败。** 如果配置里有一个顶层 `proxy-url:`，
但它解析不出来、协议不受支持，或者含有控制字符/YAML 注入字符，
`configure_gpt_backend` 会记一条 critical 错误，然后**原样保留** `config.yaml` 和
`gpt.json` —— 不会偷偷重写把你的值抹掉。显式的 `GPT_PROXY_URL` 格式错误时也是同样
的处理。修正取值后再跑一次即可。

> **为什么要用？** 不设 `proxy-url` 时，CLIProxyAPI 会直连 OpenAI。上游在首次直连时
> 返回 **500** 可能会触发二次的 **503 鉴权冷却** 状态，并在进程生命周期内持续，所以
> 登录后最先发出的几个请求会以一种「看起来不像鉴权问题」的方式失败。把上游走一条稳定
> 的 `proxy-url` 可以完全避开这条直连路径。

> **CCR 是独立的一条线。** `ccr` 后端跑在它自己的端口 `3456` 上，与这个 `8317` 代理
> 相互独立：`cl_ccr` 永远不会经过 CLIProxyAPI。CCR 通过 `gateway-proxy-preload.cjs`
> 预加载脚本配合 `CCR_UPSTREAM_PROXY_URL` 环境变量加载自己的上游代理，底层用的是
> Undici 的 `ProxyAgent`，且 GUI 里的代理设置是禁用的。两条代理线互不共享状态；在这里
> 设 `proxy-url` 不影响 CCR，反之亦然。

#### 选择模型

模型 ID 可以带一个可选的推理强度后缀，形如 `model(level)`。**在 zsh 里要加引号** ——
括号是 shell 元字符，而上游文档里是不带引号写的，那样会报错：

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.5(high)'
```

内置目录当前暴露 `gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`、`gpt-5.5`、
`gpt-5.3-codex-spark`。除非服务用 `--local-model` 启动，实时列表会在运行时从远端刷新，
所以请查 `curl http://127.0.0.1:8317/v1/models`，不要相信任何写死在文档里的列表。

**用之前先读这段。** 这条路径是通过一个逆向出来的 OAuth 流程复用消费级订阅。OpenAI
的条款禁止把账号凭证交给第三方客户端，而这个代理还自带一个「cloaking」模式，伪造
`User-Agent`/`Originator` 头来伪装成官方 Codex CLI —— 这强烈暗示 OpenAI 会校验客户端
指纹。另外，Anthropic 自己的文档明确写着他们*「不支持通过任何网关把 Claude Code 路由到
非 Claude 模型」*。真出了问题，两家厂商都不会帮你，而且它随时可能因为某个版本更新
而失效。`claude` 和 `glm` 这两个 profile 完全没有这些风险。

### 图像生成 —— `sinedied/agent-skills:image-gen`

本仓库**不内置任何图像生成代码**。`image-gen` Skill 由两个安装器通过网络拉取，且**始终安装** —— 它没有菜单项，即便所有可选项都被取消勾选也会安装：

```bash
npx -y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen
```

`DO_NOT_TRACK=1` 关闭 `skills` CLI 的匿名遥测；`--copy` 写真实文件（非 symlink）以便 `--uninstall` 能删除。缺少 `npx` 或网络失败是非致命的：记一条警告后继续，版本戳和其余安装照常完成。Skill 落在 `~/.claude/skills/image-gen/`（全局 `$HOME` 路径）；本仓库**不**追踪上游的 `image_gen.py`、提示词、示例或 license。仓库自有的包装器安装到 `~/.claude/scripts/image-gen-cliproxyapi.sh`，下载下来的 `SKILL.md` 会被幂等地注入一段受管指令块。

#### 模型、版本、端点

| | |
|---|---|
| 图像模型 | `gpt-image-2`（确切名称，绝不写成 `image2`） |
| 最低 CLIProxyAPI | `v7.2.17`（仅稳定版；**所有**预发布后缀 `-rc`/`-beta`/`-alpha`/`-pre`/`-dev`/… 都被拒绝） |
| Base URL | `http://127.0.0.1:8317/v1`（确切常量；绝不从 health URL 推导） |
| 存活探针 | `GET /healthz` —— 200 只代表监听端口起来了，**与鉴权无关** |
| 能力就绪 | 鉴权过的 `GET /v1/models`，要求精确匹配 `data[].id == "gpt-image-2"`（仅子串匹配不算）；超时内（默认 25 秒，可覆盖）无法证明则 fail-closed |
| 图像路由 | `/v1/images/generations` 与 `/v1/images/edits`（由上游 `image_gen.py` 向环回 base URL 发起） |

包装器先用 `/healthz` 决定启动还是复用，再执行鉴权过的 `/v1/models` 能力检查，通过后才委派。若无法证明能力，它会打印一条净化过的诊断（`OAuth/login may be inactive - run \`cliproxyapi --codex-login\` and retry`）并退出、**不**委派，避免配置错误的代理伪装成就绪。

#### 本地代理 key 与 OAuth —— 无需 OpenAI Platform key

包装器**绝不**索要 OpenAI Platform API key。鉴权有两层，都已在上面 `gpt` 后端配好：

1. **本地 client key** —— `~/.cli-proxy-api/config.yaml` 里 `api-keys:` 的第一个条目，安全读取，**绝不**打印、日志或放进 argv（仅 `export` 进委派子进程的环境；读取前后会禁用 xtrace，Authorization 头通过 curl `--config -` stdin 传入）。
2. **ChatGPT/Codex OAuth** —— 上面 `gpt` 一节描述的一次性 `cliproxyapi --codex-login`。若登录已失效，能力探针会 fail-closed 并给出上面的诊断。

升级已有的 CLIProxyAPI：

```bash
brew upgrade cliproxyapi        # 之后用 cl_gpt 重启，以便拾取新二进制
```

包装器与启动器 profile 维护的是**各自独立**的候选列表，不要用一个去推断另一个。包装器自己的 `IMAGE_GEN_BIN_NAMES` 依次尝试 `cliproxyapi`、`cli-proxy-api`、`cliproxy-api`；启动器的 `profiles/gpt.json` 里 `service.bins` 依次尝试 `cli-proxy-api`、`cliproxyapi`、`CLIProxyAPI`（两个列表及顺序都不同）。二进制缺失或低于 `v7.2.17` 时，包装器会同时给出 `brew install cliproxyapi` 与 `brew upgrade cliproxyapi` 作为修复指引。

#### 所有启动器共享同一组路径

`claude.zsh` 经过 grep 审计，**不含**任何 image-gen / `OPENAI_*` 耦合。每个 `cl`、`cl_claude`、`cl_glm`、`cl_gpt`、`cl_ccr` 以及生成的 `cl_<name>_auto` 都流经 `_cl_profile_run` → `_cl_run` → `claude`，后者只管理 `ANTHROPIC_*` 环境与 `claude` 二进制。Skill 与包装器位于全局 `$HOME` 路径，启动器从不触碰，因此图像生成可在任意后端下工作。恶意或不兼容的 `ANTHROPIC_BASE_URL` 永远不会改变子进程的 `OPENAI_BASE_URL`（始终是上面的环回常量）—— 图像流量直接走 `:8317`，绕过当前启动器拉起的那个代理（包括 `cl_gpt` 本身，这没问题：CLIProxyAPI 在自己的端口上接受请求）。

#### 所有权安全的卸载

安装器只有在包装器存在、上游布局（`SKILL.md` + `scripts/image_gen.py`）校验通过、且注入成功后，才写入模式 600 的清单 `~/.claude/.image-gen-sinedied`：

```text
skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-cliproxyapi.sh
```

`--uninstall` 仅在**三者同时满足**时才删除 `~/.claude/skills/image-gen`：逐字节匹配的标准清单、目录布局、**以及** `SKILL.md` 中格式正确的注入标记。同名但用户自建的目录、有清单但无标记的植入/残留、以及清单有效但目录缺失的情况，都会被保留（仅清理过期清单）。包装器本身通过管理 `cleanup-claude-data.sh` 的同一个 `USER_SCRIPTS` 循环移除。已拥有的旧版本在 `npx` 运行前会被备份，任何后续失败都按字节恢复；恢复失败时备份会保留并打印其路径。

#### 不支持原生 Windows

包装器是 Bash 脚本，CLIProxyAPI 服务生命周期仅支持 Bash/Zsh。`install.ps1` 在 Windows 上会安装网络 Skill 和包装器资产，但 `cl_*` / CLIProxyAPI 的图像生成路径在原生 Windows 上**不**受支持。请在 **WSL 内**运行 Bash 安装器，使其落到 WSL 的 `~/.claude` —— WSL 不会把 `%USERPROFILE%\.claude` 当作 `~/.claude`，而 Git Bash 的 `~/.claude` → `%USERPROFILE%\.claude` 映射取决于具体安装。本次会话**未**验证真实的 PowerShell 运行时行为（`pwsh` 不存在时行为测试套件会干净地 SKIP）；pwsh-equipped 的 Windows 机器需自行确认解析器、`cmd.exe /d /s /c` 调用 `npx.cmd`、字节级 `SKILL.md` 注入、以及清单原子性。

### `ccr` —— 跨多个供应商的统一 `/model` 列表

[claude-code-router](https://github.com/musistudio/claude-code-router) v3 把多个供应商
统一挡在一个网关后面。配上 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`
（profile 里已经有了），Claude Code 的 `/model` 会以 `provider/model` 的形式列出每个
供应商的模型。

> 该后端没有额度端点，因此 `ccr` 终端的状态栏**不渲染额度段** —— 无论网关最终路由到
> 哪个供应商。其余各段不受影响。详见[状态栏里的额度](#状态栏里的额度)。

**两个端口，搞混它们是最常见的错误：**

| 端口 | 是什么 | 谁在跟它通信 |
|---|---|---|
| `127.0.0.1:3458` | 管理 **UI** | 你的浏览器 |
| `127.0.0.1:3456` | 模型**网关** | Claude Code（`ANTHROPIC_BASE_URL`） |

**这一个没法完全自动化。** CCR v3 把配置存在
`~/.claude-code-router/config.sqlite`；老的 `config.json` 只在还没有 SQLite 配置的机器
上被读取一次。所以安装器能装好 CCR 和 profile，但供应商和客户端 key 必须手工创建一次。

#### 第 1 步 —— 安装并打开 UI

```bash
node --version                                   # must be >= 22
npm install -g @musistudio/claude-code-router
ccr ui                                           # opens http://127.0.0.1:3458
```

如果后台服务还没跑，`ccr ui` 会顺带把它拉起来 —— 不需要先执行 `ccr start`。这条命令
打印出的 URL 里带有 `ccr_web_token` 查询参数：**把整个 URL 当作密码对待。** 如果你
想要一个固定 token，而不是每个进程随机生成一个新的，就设置 `CCR_WEB_AUTH_TOKEN`。

v3 的命令是 `ccr start`、`ccr ui`、`ccr stop`、`ccr serve`（前台运行）、`ccr web`
（`serve` 的别名）和 `ccr <profile>`。**没有 `ccr status`，也没有 `ccr restart`** ——
要改 host 或 port，必须先 `ccr stop`，再 `ccr start --host … --port …`；在服务运行中
改这两项会静默地什么都不做。

#### 第 2 步 —— 添加一个供应商

**Providers**（供应商）→ **Add Provider**（添加供应商）。GLM 的话不要手敲任何东西：
直接选内置预设 **Zhipu AI (China) - Coding Plan**（中国大陆以外选
**Z.ai (Global) - Coding Plan**）。每个 coding-plan 预设都自带两个 endpoint：

| Endpoint | 协议 |
|---|---|
| `https://open.bigmodel.cn/api/coding/paas/v4` | OpenAI Chat Completions |
| `https://open.bigmodel.cn/api/anthropic` | **Anthropic Messages** |

选 Anthropic Messages 那个。把你的 BigModel key 粘进 **API key**，然后用
**Search models**（搜索模型）或 **Custom models**（自定义模型）选上 `glm-5.3`、
`glm-5-turbo`、`glm-4.7`。

如果还想把本地的 CLIProxyAPI 也挂进来，再加第二个供应商：**Other / custom
API endpoint**，endpoint 填 `http://127.0.0.1:8317`，协议选 **Anthropic
Messages**。

**Check Connection**（检查连接）会发出真实的模型请求，消耗真实的 token。跑一次是值得的；
只是别让它循环跑。

#### 第 3 步 —— 复制 **Local Gateway** 那个 key（不是 profile key）

**API Keys** 页面会列出不止一种 key，而只有一种在这里能用：

| UI 里的名字 | 用于我们的启动器？ |
| --- | --- |
| `Local Gateway` —— `sk-ccr-…` | **是。** 就是这个。 |
| `Profile: <agent>` —— `ccr-profile-…` | **不是。** 它只作用于 CCR 自己的 `ccr <profile>` 启动路径。 |

把 `sk-ccr-…` 粘贴到 `~/.claude/profiles/ccr.json` 的
`.env.ANTHROPIC_AUTH_TOKEN`。

这里填错了，报错完全不像鉴权问题。`ccr-profile-…` 这类 key 在
**`GET /v1/models` 上返回 401** —— 而这恰好是网关模型发现在启动时要打的那个请求 ——
于是 Claude Code 拿不到任何模型元数据，你还没敲一个字就迎面撞上
*"Context limit reached"*。自己验一下：

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $KEY" http://127.0.0.1:3456/v1/models   # want 200
```

**Add API key** 里还能设置过期时间，以及 **Advanced settings**（高级设置）下的每分钟/
每小时/每天请求数或 token 数限制。新建的 key **只显示一次**。

> CCR 里存在三种互不相同的密钥，彼此不能替代：这个网关 key、UI URL 里的
> `ccr_web_token`、以及你上游供应商的 key（BigModel 等）。

#### 第 4 步 —— 启动网关，然后启动 Claude Code

在 **Server**（服务）下点 **Start**。UI 能打开*并不*代表网关已经起来了 —— 用下面的
命令确认：

```bash
curl http://127.0.0.1:3456/health     # expect 200 "running"
cl_ccr
```

现在 `/model` 会在一个地方列出所有供应商的模型。

#### 第 5 步 —— 让安装脚本填模型槽位

网关起来、key 填好之后，重跑一次 `./install.sh`。它会查询 `GET /v1/models`，并让你把
`opus` / `sonnet` / `haiku` / `fable` 映射到真实的网关 id：

```
[OK]   gateway published 12 model(s)
      1) Codex API/gpt-5.6-sol
     10) Zhipu AI (China) - Coding Plan/glm-5.3
     opus [1-12, Enter=skip]:
```

这些 id 里嵌着**你自己在 UI 里输入的 provider 显示名**，所以没有任何模板能预置它们，
也没有任何安装脚本能猜到 —— 运行中的网关是唯一的事实来源。这就是它单独成为一步、而
不是往 `profiles/ccr.json` 里多塞几个静态键的原因。你选定的值会落进该 profile 的
`credentialKeys`，因此之后再跑 `./install.sh` 都会保留。

`opus` / `sonnet` / `haiku` 跳过也没问题。这三个槽位为空时，`cl_ccr` 会**故意不传
`--model`**，由你进去用 `/model` 按会话挑选 —— 因为对一个发布 `provider/model` 形式 id
的网关来说，`--model opus` 指的是一个它从没听说过的模型。

> **`fable` 是例外，别跳过。** Claude Code 不会把 fable 放进 `/model` 列表，它是后台专用
> 槽位（`/compact`、会话标题、配额探测）。槽位为空时，这些请求会直接以字面量
> `claude-fable-5` 发给网关，而网关只认 `provider/model` 形式的 id，于是每一条都在模型
> 解析阶段返回 `400 All target providers failed`。前台模型是好的，所以症状是会话时不时
> 冒出一个没有任何上下文的 `API Error: 400`，非常难查。指一个便宜模型给它就行。

> **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` 在这里是必填项，不是调优选项。** CCR 上报的每个
> 模型都是 `context_length: null`，所以模型发现从来不会给出上下文窗口，Claude Code 只能
> 退回一个很小的默认值 —— 配上庞大的启动上下文，那就是开机即
> *"Context limit reached"*。profile 里预置 `1000000` 以匹配 `glm-5.3`。它是
> **一个客户端全局值，不分槽位**：Codex 系列模型（`gpt-5.6-*`，约 272K）和 `glm-4.7` /
> `glm-5-turbo`（200K）都小得多，路由到这些模型的会话会把上下文涨过服务端能接受的上限、
> 中途失败 —— auto-compact 救不回来。如果你经常路由到它们，把这个值降到 `200000`。

#### 可选：Agent Profiles 与路由

**Agent Profiles 是可选的 —— 而对 Claude Code，别去动它。** 只有在你要用
`ccr <profile>` 启动，或者想让 CCR 帮你写某个 agent 的 settings 文件时才需要它。
我们的启动器两个都不用 —— 它自己设置 `ANTHROPIC_BASE_URL`。

> **不要在 CCR 的 Agent Profiles 里绑定 / 注册 Claude Code。** 一旦绑定，CCR 就会去写
> 并接管那些本应由 `~/.claude/profiles/ccr.json` 和 `cl_ccr` 启动器控制的设置
> （`ANTHROPIC_BASE_URL`、模型槽位、`CLAUDE_CODE_MAX_CONTEXT_TOKENS`）。两边互相打架，
> 结果就是配置被重复或覆盖、`/model` 发现失效、或者上下文窗口不对。让 Claude Code 接入
> 网关只用我们文档里的方式 —— 用 `cl_ccr` 启动 —— CCR 的 Agent Profiles 留空。

v3 的路由**不再是**老 v1 那套 `default` / `background` / `think` / `longContext`
配置块；那东西已经没了。v3 有按 profile 的内置路由（**Use enhanced route**，启用增强
路由）、一个由有序自定义规则组成的 **Routing**（路由）页面，以及可选的 Node.js 脚本
规则。子代理路由的实现方式是注入
`<CCR-SUBAGENT-MODEL>provider/model</CCR-SUBAGENT-MODEL>`，并且只有在 **Models**
（模型）页面上至少有一个模型填了 **Description**（描述）之后才会生效。

## 状态栏里的额度

`hooks/statusline.sh` 会渲染当前终端**实际所用后端**的 5 小时额度条。后端由
`$ANTHROPIC_BASE_URL` 推导，而这个变量是启动器按 shell 导出的，所以两个终端跑两个
后端时会同时显示各自的数字，互不干扰：

| `$ANTHROPIC_BASE_URL`           | 标签      | 数据来源                                                        | 刷新间隔 |
| ------------------------------- | -------- | -------------------------------------------------------------- | ------- |
| 未设置（`claude` profile）       | `5h`     | `api.anthropic.com/api/oauth/usage`，OAuth token                | 60 秒   |
| `*bigmodel.cn*` / `*z.ai*`      | `glm 5h` | `{host}/api/monitor/usage/quota/limit`，`$ANTHROPIC_AUTH_TOKEN` | 600 秒  |
| 其他（`gpt`、`ccr` 等）          | —        | 没有可用的额度端点，整段不渲染                                    | —       |

进度条显示的是**已用**百分比，后面的时间是窗口重置时刻。GLM 的窗口是滚动的 —— 从开启
窗口的那次请求起五小时后重置，而不是按整点 —— 所以重置时间取自接口返回值，不在本地推算。

说明：

- **GLM 的轮询频率是原生 API 的十分之一。** 状态栏每次渲染都会触发，而智谱有未公开的
  限流与风控规则，600 秒的 TTL 能让活跃会话离阈值足够远。代价是新开终端的第一次渲染
  通常没有额度段，下一次才有。
- **每个后端各有自己的缓存文件**（位于 `$TMPDIR`），GLM 后端还会再按凭据细分
  （`claude-usage-cache-anthropic.json`、`claude-usage-cache-glm-<校验和>.json`）。
  因此国内版和国际版两个 GLM key 并排使用是安全的。校验和取自 token，token 本身不落盘。
  **但原生 Anthropic 路径不按凭据细分** —— 它的指纹恒为 `anthropic`，因为 OAuth token
  是在后台抓取内部才从钥匙串读出的，计算文件名时拿不到。同一台机器上的两个 Anthropic
  账号会共用 `claude-usage-cache-anthropic.json`，所以切换账号后，额度条最多会有一个
  刷新周期仍显示上一个账号的数字。
- **凭据绝不经命令行传给 `curl`。** 两条抓取路径都把请求头经 stdin 交给 `curl -K -`，
  因此同机其他用户的 `ps` 输出里不会出现任何 token。
- **`export CL_NO_USAGE=1` 可彻底关闭额度功能** —— 任何后端都不再抓取、也不渲染额度段。
  它必须在 `~/.zshrc` 里 `export`；写成 `CL_NO_USAGE=1 cl_glm` 这样的一次性前缀赋值
  传不到状态栏进程。
- **网络请求绝不阻塞渲染。** 状态栏只读缓存；缓存过期时会拉起一次后台刷新，供**下一次**
  渲染使用。任何失败 —— 没有凭据、域名不可达、schema 不符 —— 都只会静默去掉额度段，
  其余各段照常显示。

## 添加你自己的后端

写一个 `~/.claude/profiles/<name>.json`。`<name>` 有两条约束：

- 必须匹配 `^[A-Za-z0-9_-]+$`。其他任何字符 —— 空格、引号、点 —— 都会被跳过，因为
  这个名字会被插值进一个 shell 函数定义里，写坏了曾经会导致每个新开的 shell 都报错。
- 不能和内置命令撞名：`switch`、`auto`、`stop`、`profiles`。这些名字已经占用了对应的
  `cl_*` 函数，同名 profile 会被跳过，而不是把它们覆盖掉。



```json
{
  "label": "Human-readable name",
  "credentialKeys": ["ANTHROPIC_AUTH_TOKEN"],
  "service": null,
  "unset": [],
  "env": {
    "ANTHROPIC_BASE_URL": "https://…",
    "ANTHROPIC_AUTH_TOKEN": "YOUR_KEY"
  }
}
```

开一个新 shell，`cl_<name>` 就存在了。`credentialKeys` 里点名的键会在重新安装时保留 ——
其余内容都从仓库模板刷新，这样模型默认值能跟上上游，同时永远不会覆盖掉你的 key。

要让某个 profile 管理一个本地代理，加上：

```json
"service": {
  "label": "My proxy",
  "health": "http://127.0.0.1:PORT/healthz",
  "bins": ["my-proxy"],
  "start": "{bin} --config \"$HOME/.my-proxy/config.yaml\"",
  "timeoutSec": 25,
  "logName": "my-proxy.log",
  "installHint": "brew install my-proxy",
  "loginHint": "{bin} --login"
}
```

`{bin}` 会被替换成 `bins` 里第一个在 `PATH` 上存在的条目。如果一个都没有，启动器会
拒绝启动并打印 `installHint`。

## 从 `glm-env.json` 迁移

安装器会把 2.11 之前的 `~/.claude/glm-env.json` 移动到
`~/.claude/profiles/glm.json`，保留你的凭证，并把旧文件重命名为
`glm-env.json.migrated`。如果 profiles 目录整个不存在，`claude.zsh` 仍然会读取那个扁平
的旧文件，所以升级升到一半也不会把你卡死。

`--uninstall` 会刻意保留 `~/.claude/profiles/`，因为那些文件里存着你自己粘进去的 API key。

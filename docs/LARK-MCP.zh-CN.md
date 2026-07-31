# 飞书 / Lark MCP —— 一步步配置

[English](LARK-MCP.md)

`@larksuiteoapi/lark-mcp` 把飞书/Lark 开放平台 API 以 MCP 工具的形式暴露给
Claude Code。本仓库的安装器**默认不装它**，因为它需要一组只有你自己能创建的
App ID 和 App Secret。

开始之前有两件事要知道：

- 上游仍标注为 **beta**，最新版本 `0.5.1` 发布于 2025 年 8 月。请**锁定版本号**，
  否则 `npx` 某次后台刷新可能悄悄改变行为。
- **飞书（feishu.cn）应用和 Lark（larksuite.com）应用不能混用。** 拿其中一个去请求
  另一个的域名会认证失败，且不会给出有用的报错。创建应用前先确认你在哪一边。

## 1. 检查 Node.js

```bash
node -v          # 必须 >= 20.0.0
```

`>=20` 这个下限写在包的 manifest 里。上游 README 只说「装 LTS 版本」，所以很多人
在这里翻车。

## 2. 创建应用，拿到 APP_ID 和 APP_SECRET

1. 登录开发者后台：
   - 中国 / 飞书 → <https://open.feishu.cn/>
   - 国际 / Lark → <https://open.larksuite.com/>
2. 进入**开发者后台**，创建新应用，类型选**创建企业自建应用**。
3. 在应用的左侧栏打开**凭证与基础信息**，**App ID** 和 **App Secret** 就在这一页。

App ID 长这样：`cli_xxxxxxxxxxxxxxxx`。

## 3. 开通权限 —— 真正卡住人的就是这一步

**没有权限时，MCP 工具照样会出现，但每次调用都会失败。** 按你实际要用的功能开通：

1. 应用 → **权限管理** → **开通权限**。例如 `im:message`（消息）、
   `docx:document`（云文档）、`bitable:app`（多维表格）、
   `contact:user.id:readonly`（通讯录）。
2. **要不要发版，取决于权限种类**：
   - **免审权限**：自建应用开通后**立即生效**，什么都不用做。
   - **需审核权限**：必须走 **版本管理与发布** → **创建版本** → **申请线上发布**，
     再由企业管理员在 飞书管理后台 → 工作台 → 应用审核 里批准。

如果你需要敏感权限但一时找不到管理员审批，官方给了两条绕行路：使用
**开发者本人的 `user_access_token`**（见第 5 节），或者配置一个**测试企业**，
在测试企业里调用免审。

## 4. 添加到 Claude Code —— 最小可用版

```bash
claude mcp add lark-mcp --scope user -- \
  npx -y @larksuiteoapi/lark-mcp@0.5.1 mcp \
  -a cli_xxxxxxxxxxxxxxxx -s your_app_secret \
  -t preset.light
```

其中有三处是刻意的：

- **`--` 不能省。** `claude mcp add` 自己用 `-s` 表示 `--scope`，而 `lark-mcp`
  用 `-s` 表示 app secret。`--` 之后的内容会被原样透传，不会打架；但一旦漏掉 `--`，
  你的 app secret 会被 Claude Code 当成 scope 参数吃掉。
- **`-t preset.light`** 限制暴露哪些工具。不写的话默认是 `preset.default`，
  上游 FAQ 自己把「启动 MCP 服务后提示 token limit exceeded」列为已知问题，
  给出的解法正是这个参数。先从小的开始，不够用再放宽。
- **`@0.5.1`** 锁定版本。

### 不想把 secret 写在命令行里

```bash
claude mcp add lark-mcp --scope user \
  --env APP_ID=cli_xxxxxxxxxxxxxxxx --env APP_SECRET=your_app_secret \
  -- npx -y @larksuiteoapi/lark-mcp@0.5.1 mcp -t preset.light
```

支持的环境变量：`APP_ID`、`APP_SECRET`、`USER_ACCESS_TOKEN`、`LARK_TOOLS`、
`LARK_DOMAIN`、`LARK_TOKEN_MODE`。其余参数没有对应的环境变量。
优先级：命令行参数 > 环境变量 > 配置文件 > 默认值。

### 国际版 Lark

加上 `-d https://open.larksuite.com`。该参数默认值是 `https://open.feishu.cn`。

## 5. 应用身份 vs 用户身份

只给 `-a` / `-s` 时，你拿到的是 **`tenant_access_token`**，也就是**应用自己的身份**。
它够用来访问应用自有资源，但**读不了**用户的个人云文档、个人日历，也不能以该用户的
身份发消息。

要用用户身份，先在开发者后台把重定向 URL 设为 `http://localhost:3000/callback`，
然后登录一次：

```bash
npx -y @larksuiteoapi/lark-mcp@0.5.1 login -a cli_xxxx -s your_app_secret
# 指定 scope：
npx -y @larksuiteoapi/lark-mcp@0.5.1 login -a cli_xxxx -s your_app_secret \
  --scope offline_access docx:document
```

然后以 OAuth 模式注册服务：

```bash
claude mcp add lark-mcp --scope user -- \
  npx -y @larksuiteoapi/lark-mcp@0.5.1 mcp \
  -a cli_xxxx -s your_app_secret -t preset.light \
  --oauth --token-mode user_access_token
```

**`--token-mode user_access_token` 必须显式写出来。** 默认值是 `auto`，上游明确警告：
在 `auto` 下部分调用会**静默回退**到 `tenant_access_token`，结果就是权限不足或者
读不到私人数据。

也可以用 `-u <token>` 直接粘贴 token，但用户 token 大约 2 小时就过期，所以
`login` + `--oauth` 才是能长期用的方案。`lark-mcp logout` 清除已存的 token。

## 6. 确认连上了

```bash
claude mcp list          # 看是否显示 "✔ Connected"
claude mcp get lark-mcp
```

或者在会话里输入 `/mcp`。

注意：**`claude mcp add` 不会校验凭证** —— 你给什么它存什么，App Secret 写错了
也要等到之后连接失败才看得出来。失败时手动跑一遍服务命令并加上 `--debug` 看详情。

## 7. 工具预设

`-t` 接受预设和单个工具，用逗号分隔：`-t "preset.light,im.v1.message.create"`。

| 预设 | 范围 |
|---|---|
| `preset.light` | 最小集合 —— 从这个开始 |
| `preset.default` | 不写 `-t` 时的默认值 |
| `preset.im.default` | 消息 |
| `preset.doc.default` | 云文档 |
| `preset.base.default` / `preset.base.batch` | 多维表格 |
| `preset.task.default` | 任务 |
| `preset.calendar.default` | 日历 |

## 8. 已知的坑

- **域名搞错** —— 用 feishu.cn 的应用去打 `open.larksuite.com`（或反过来）永远认证
  不过。这是最常见的静默 401。
- **凭证错误不报错** —— 见第 6 节。
- **Linux**：出现 `[StorageManager] Failed to initialize` 说明 `keytar` 缺 libsecret
  （`apt-get install libsecret-1-dev`）。不使用存储的用户 token 时无害。
- **Windows**：先执行 `chcp 65001`，否则中文输出乱码。
- **完全不支持的功能**：文件/图片的上传与下载，以及云文档的直接编辑（只支持导入和
  读取）。不要围绕这些设计工作流。
- **频率限制**走飞书开放平台的通用限流，MCP 这一层自己不做任何节流。

## 卸载

```bash
claude mcp remove lark-mcp
```

上游仓库：<https://github.com/larksuite/lark-openapi-mcp>

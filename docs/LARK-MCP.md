# Lark / Feishu MCP — step by step

[中文版](LARK-MCP.zh-CN.md)

`@larksuiteoapi/lark-mcp` exposes Feishu/Lark OpenAPI to Claude Code as MCP
tools. It is **off by default** in this repo's installer, because it needs an
App ID and an App Secret that only you can create.

Two things to know before you start:

- The package is still labelled **beta** upstream, and the latest release
  (`0.5.1`) is from August 2025. Pin the version so a background `npx` refresh
  cannot change behaviour under you.
- **A Feishu (feishu.cn) app and a Lark (larksuite.com) app are not
  interchangeable.** Using one against the other's domain fails authentication
  with no useful error. Decide which one you are on before creating the app.

## 1. Check Node.js

```bash
node -v          # must be >= 20.0.0
```

The `>=20` floor is in the package manifest. The upstream README only says
"install the LTS version", which is why people hit this.

## 2. Create the app, get APP_ID and APP_SECRET

1. Sign in to the developer console:
   - China / Feishu → <https://open.feishu.cn/>
   - International / Lark → <https://open.larksuite.com/>
2. Go to **开发者后台** (Developer Console) and create a new app. Choose
   **创建企业自建应用** (enterprise self-built app).
3. In the app's left sidebar open **凭证与基础信息** (Credentials & Basic Info).
   **App ID** and **App Secret** are shown there.

The App ID looks like `cli_xxxxxxxxxxxxxxxx`.

## 3. Grant permissions — this is the step that actually blocks people

The MCP tools will appear even with no permissions, and then every call fails.
Grant scopes matching what you plan to use:

1. App → **权限管理** → **开通权限**. Add e.g. `im:message` (messages),
   `docx:document` (docs), `bitable:app` (Base), `contact:user.id:readonly`.
2. Whether you need to publish depends on the scope:
   - **免审权限** (review-free scopes) take effect **immediately** for a
     self-built app. Nothing else to do.
   - **需审核权限** (sensitive scopes) require
     **版本管理与发布** → **创建版本** → **申请线上发布**, then an enterprise
     admin approves it in 飞书管理后台 → 工作台 → 应用审核.

If you need a sensitive scope and cannot get an admin to approve quickly, there
are two documented ways to work anyway: use the **developer's own
`user_access_token`** (see step 5), or configure a **测试企业** (test tenant),
where calls are review-free.

## 4. Add it to Claude Code — the minimal version

```bash
claude mcp add lark-mcp --scope user -- \
  npx -y @larksuiteoapi/lark-mcp@0.5.1 mcp \
  -a cli_xxxxxxxxxxxxxxxx -s your_app_secret \
  -t preset.light
```

Three parts of that are deliberate:

- **`--` is load-bearing.** `claude mcp add` uses `-s` for `--scope`, and
  `lark-mcp` uses `-s` for the app secret. Everything after `--` is passed
  through untouched. Drop the `--` and your app secret is swallowed as a Claude
  Code argument.
- **`-t preset.light`** limits which tools are exposed. The default is
  `preset.default`, and upstream's own FAQ lists "token limit exceeded after
  starting the MCP service" as a known problem whose fix is exactly this flag.
  Start small and widen later.
- **`@0.5.1`** pins the version.

### Keeping the secret out of the command line

```bash
claude mcp add lark-mcp --scope user \
  --env APP_ID=cli_xxxxxxxxxxxxxxxx --env APP_SECRET=your_app_secret \
  -- npx -y @larksuiteoapi/lark-mcp@0.5.1 mcp -t preset.light
```

Supported env vars: `APP_ID`, `APP_SECRET`, `USER_ACCESS_TOKEN`, `LARK_TOOLS`,
`LARK_DOMAIN`, `LARK_TOKEN_MODE`. The other flags have no env equivalent.
Precedence is CLI args > env vars > config file > defaults.

### International Lark

Add `-d https://open.larksuite.com`. The flag defaults to
`https://open.feishu.cn`.

## 5. App identity vs user identity

With only `-a` / `-s` you get a **`tenant_access_token`** — the app's own
identity. That is enough for app-owned resources, but it **cannot** read a
user's personal docs or calendar, and cannot send messages as that user.

For user identity, set the redirect URL to `http://localhost:3000/callback` in
the console, then log in once:

```bash
npx -y @larksuiteoapi/lark-mcp@0.5.1 login -a cli_xxxx -s your_app_secret
# scoped:
npx -y @larksuiteoapi/lark-mcp@0.5.1 login -a cli_xxxx -s your_app_secret \
  --scope offline_access docx:document
```

Then register the server with OAuth enabled:

```bash
claude mcp add lark-mcp --scope user -- \
  npx -y @larksuiteoapi/lark-mcp@0.5.1 mcp \
  -a cli_xxxx -s your_app_secret -t preset.light \
  --oauth --token-mode user_access_token
```

**Set `--token-mode user_access_token` explicitly.** The default is `auto`, and
upstream warns that under `auto` some calls silently fall back to
`tenant_access_token`, producing permission errors or missing private data.

`-u <token>` pastes a token directly instead, but user tokens expire in roughly
two hours, so `login` + `--oauth` is the maintainable path. `lark-mcp logout`
clears stored tokens.

## 6. Confirm it connected

```bash
claude mcp list          # look for "✔ Connected"
claude mcp get lark-mcp
```

Or `/mcp` inside a session.

`claude mcp add` **does not validate credentials** — it saves whatever you give
it, and a wrong App Secret shows up only later as a failed connection. If it
fails, re-run the server command by hand with `--debug`.

## 7. Tool presets

`-t` accepts presets and individual tools, comma-separated:
`-t "preset.light,im.v1.message.create"`.

| Preset | Scope |
|---|---|
| `preset.light` | Smallest set — start here |
| `preset.default` | The default if you omit `-t` |
| `preset.im.default` | Messaging |
| `preset.doc.default` | Docs |
| `preset.base.default` / `preset.base.batch` | Base (Bitable) |
| `preset.task.default` | Tasks |
| `preset.calendar.default` | Calendar |

## 8. Known traps

- **Wrong domain** — a feishu.cn app pointed at `open.larksuite.com` (or the
  reverse) never authenticates. This is the most common silent 401.
- **Silent credential failure** — see step 6.
- **Linux**: `[StorageManager] Failed to initialize` means `keytar` needs
  libsecret (`apt-get install libsecret-1-dev`). Harmless unless you use stored
  user tokens.
- **Windows**: run `chcp 65001` first or Chinese output is garbled.
- **Not supported at all**: file/image upload and download, and direct editing
  of cloud docs (import and read only). Don't design a workflow around them.
- **Rate limits** are Feishu's general OpenAPI limits. The MCP layer does no
  throttling of its own.

## Removing it

```bash
claude mcp remove lark-mcp
```

Upstream: <https://github.com/larksuite/lark-openapi-mcp>

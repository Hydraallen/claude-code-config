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

## 4. Add it to Claude Code with the installer (macOS, Linux, WSL)

```bash
./install.sh --only mcp-lark      # or tick "Lark/Feishu MCP" in the selector
```

The installer asks for the App ID and the App Secret (typed without echo) on
your terminal, installs `@larksuiteoapi/lark-mcp@0.5.1` globally with
`npm i -g`, and sets up the [shared service](#shared-service): one lark-mcp
process on `127.0.0.1:3100` that every Claude session connects to over HTTP,
instead of one ~1 GB process per session. A re-run reuses the saved
credentials and does not prompt again.

Native Windows (`install.ps1`) keeps the per-session stdio registration from
the next section.

## 4b. Add it by hand — the minimal version

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

<a id="shared-service"></a>
## Shared service

| | macOS | Linux / WSL with systemd |
|---|---|---|
| Service | LaunchAgent `~/Library/LaunchAgents/com.claude-code-config.lark-mcp.plist` (RunAtLoad, KeepAlive) | `~/.config/systemd/user/lark-mcp.service` (Restart=on-failure, no linger) |
| App Secret | login Keychain, service `claude-code-config.lark-mcp`, account = App ID | `APP_SECRET` in `~/.config/lark-mcp/env` (chmod 600) |
| Settings | `~/.config/lark-mcp/env`: `APP_ID`, `LARK_TOOLS`, `LARK_MCP_PORT` | same file |
| Logs | `~/Library/Logs/lark-mcp.log`, `~/Library/Logs/lark-mcp.err.log` | `journalctl --user -u lark-mcp` |

`~/.config` follows `XDG_CONFIG_HOME`. Claude Code is registered with
`claude mcp add --scope user --transport http lark-mcp http://127.0.0.1:3100/mcp`.
The server binds to `127.0.0.1` only. Pick another port at install time with
`LARK_MCP_PORT=3200 ./install.sh --only mcp-lark`; the port is saved in the env
file. To widen the tool preset or switch to international Lark, edit
`LARK_TOOLS` or add `LARK_DOMAIN=https://open.larksuite.com` in the env file and
restart the service; a re-run keeps both.

**Security:** the localhost port has no authentication. Any process running on
the machine can call Lark through it with the app's identity. That is
acceptable on a single-user machine; on a shared host, use the stdio
registration from step 4b instead.

Status, logs and restart:

```bash
# all platforms: MCP initialize against the service
python3 scripts/check_mcp.py --timeout 10 --url http://127.0.0.1:3100/mcp

# macOS
launchctl print gui/$(id -u)/com.claude-code-config.lark-mcp | head -20
tail -f ~/Library/Logs/lark-mcp.err.log
launchctl kickstart -k gui/$(id -u)/com.claude-code-config.lark-mcp   # restart

# Linux / WSL
systemctl --user status lark-mcp
journalctl --user -u lark-mcp -f
systemctl --user restart lark-mcp
```

The installer's selection record (`~/.claude/agent-config/selection.json`,
item `lark`) also stores the mode and whether the service answered.

**Fallback.** When there is no service manager (WSL without systemd, no
`systemctl --user` session), or the service does not answer an MCP
`initialize` within about 15 seconds, the installer removes the service and
registers `~/.config/lark-mcp/run.sh` as a stdio server instead. Each Claude
session then starts its own lark-mcp again, but the secret still stays out of
the command line. The installer prints the reason. To use the shared service
in WSL, enable systemd (`[boot]` / `systemd=true` in `/etc/wsl.conf`, then
`wsl --shutdown`) and re-run. When the npm global prefix is not writable, the
installer prints how to fix it (`npm config set prefix ~/.npm-global`) and the
launcher uses `npx` until you re-run.

**Migrating an existing registration.** If `lark-mcp` was registered by an
earlier version of this installer (`npx -y @larksuiteoapi/lark-mcp ... -a ...
-s ...`), `./install.sh --only mcp-lark` reads the App ID and Secret from that
entry, replaces it, and does not prompt. A `lark-mcp` entry you added yourself
with another command is left in place; remove it first
(`claude mcp remove lark-mcp --scope user`) and re-run to switch.

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

Untick the item in the installer's selector, or run `./install.sh --uninstall`.
Either removes the registration, stops and deletes the LaunchAgent or systemd
unit, deletes `~/.config/lark-mcp/` and the Keychain item. The global npm
package stays; remove it with `npm rm -g @larksuiteoapi/lark-mcp`.

By hand:

```bash
claude mcp remove lark-mcp --scope user
# macOS
launchctl bootout gui/$(id -u)/com.claude-code-config.lark-mcp
rm ~/Library/LaunchAgents/com.claude-code-config.lark-mcp.plist
security delete-generic-password -s claude-code-config.lark-mcp
# Linux / WSL
systemctl --user disable --now lark-mcp && rm ~/.config/systemd/user/lark-mcp.service
# all
rm -r ~/.config/lark-mcp
```

Upstream: <https://github.com/larksuite/lark-openapi-mcp>

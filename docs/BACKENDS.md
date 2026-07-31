# Model Backends

Claude Code only speaks the Anthropic protocol. Every non-Claude model therefore
has to arrive through a translation layer. This repo models each way of getting
there as a **profile**: one JSON file in `~/.claude/profiles/`, loaded by
`claude.zsh`.

```
~/.claude/profiles/
  claude.json   native OAuth, zero config
  glm.json      Zhipu GLM Coding Plan (vendor-provided Anthropic endpoint)
  gpt.json      ChatGPT subscription via a local CLIProxyAPI
  ccr.json      claude-code-router gateway — several providers in one /model list
~/.claude/default-profile      which backend a bare `cl` uses
```

## Commands

| Command | Effect |
|---|---|
| `cl` | Launch using `default-profile` |
| `cl_auto` | Same, with `--dangerously-skip-permissions` |
| `cl_claude`, `cl_glm`, `cl_gpt`, `cl_ccr` | Force a specific backend |
| `cl_<name>_auto` | Same, skipping permission prompts |
| `cl_switch <name>` | Change the default |
| `cl_stop [<name>\|--all]` | Stop proxy services the launcher started |
| `cl_profiles` | List backends, their labels, and whether each is ready |

`cl_<name>` is generated at source time from whatever is in the profiles
directory — adding a backend never requires editing `claude.zsh`.

Every launch prints the backend and the model it resolved to, e.g.
`cl_glm: backend 'glm' (https://open.bigmodel.cn/api/anthropic, 20 vars)` then
`cl_glm: model opus -> glm-5.2`.

### Picking a model without editing JSON

The profile's `opus` slot is the default. Override it per launch:

```bash
cl_glm --model glm-5v-turbo     # any exact model id the backend accepts
cl_glm --model sonnet           # or an alias, resolved by the profile's slots
CL_MODEL=sonnet cl_glm          # change the default alias for one launch
```

A `--model` in your own arguments always wins over the launcher's default.

Env vars are injected only for the duration of one launch and restored exactly
afterwards, including vars that were previously unset. Nothing is written to
`settings.json`.

## Setup per backend

### `claude` — official subscription

Nothing to configure. It also *clears* `ANTHROPIC_BASE_URL` and friends for the
duration of the run, so a gateway URL exported in `.zshrc` cannot silently
hijack your Claude subscription.

### `glm` — Zhipu GLM Coding Plan

Paste your BigModel API key into `.env.ANTHROPIC_AUTH_TOKEN` of
`~/.claude/profiles/glm.json`, then:

```bash
cl_glm
```

Coding Plan covers **`glm-5.2` (1M in / 128K out), `glm-5-turbo` (200K),
`glm-4.7` (200K)** only — those are the three mapped to opus/sonnet/haiku.
`glm-5` and `glm-5.1` are auto-routed to `glm-5.2` upstream, so don't pin them.
The vision model **`glm-5v-turbo` (200K)** has no slot of its own; reach it with
`cl_glm --model glm-5v-turbo`.

#### Unlocking glm-5.2's 1M context

Claude Code hardcodes a 200K context limit for any model id it does not
recognise, and no `glm-*` id is in its registry — so without help the client
compacts at 200K and caps output at its 32K default, wasting four fifths of what
glm-5.2 actually accepts. The profile therefore sets:

| Var | Value | Why |
|---|---|---|
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `1000000` | The client honours this only for non-`claude-*` model ids; it is the intended escape hatch |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `1000000` | The compact window is `min(contextLimit, thisVar)`, so setting it alone is a no-op — both are needed |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | glm-5.2 tops out at 128K output; `131072` would be clamped by the client, which accepts at most `128000` |

Nothing extra is needed server-side — no header, no `[1m]` suffix on the model
id. Do **not** rename the model to `glm-5.2[1m]`: that is not a Z.ai model code
and it would go out on the wire.

> **Caveat — one limit, three models.** `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is a
> single client-wide value, not per-slot. It matches glm-5.2, which is the opus
> slot and the launcher default. If you route to **sonnet (`glm-5-turbo`)** or
> **haiku (`glm-4.7`)**, both 200K, the client will let the context grow past
> what the server accepts and auto-compact will not save you. Keep those
> sessions under 200K, or `cl_switch` to a backend sized for them.

Docs: <https://docs.bigmodel.cn/cn/coding-plan/tool/claude>

### `gpt` — ChatGPT Plus/Pro subscription

Backed by [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), which
exposes an Anthropic-compatible `/v1/messages` on `127.0.0.1:8317`.

```bash
brew install cliproxyapi
cli-proxy-api --codex-login          # one-time browser authorization
# put an api-keys entry from ~/.cli-proxy-api/config.yaml into the profile:
#   .env.ANTHROPIC_AUTH_TOKEN
cl_gpt                               # starts the proxy if it isn't already up
```

`cl_gpt` health-checks `http://127.0.0.1:8317/healthz` first, starts the proxy
in the background only if needed, waits for it to come up, and logs to
`~/.claude/logs/cli-proxy-api.log`.

**Read this before using it.** This path reuses a consumer subscription through
a reverse-engineered OAuth flow. OpenAI's terms prohibit sharing account
credentials with third-party clients, and the proxy ships a "cloaking" mode that
forges `User-Agent`/`Originator` headers to look like the official Codex CLI —
which strongly implies OpenAI validates client fingerprints. Separately,
Anthropic's own docs state they *"do not support routing Claude Code to
non-Claude models through any gateway"*. Neither vendor will help you if this
breaks, and it can break at any release. The `claude` and `glm` profiles carry
none of this risk.

### `ccr` — one `/model` list across providers

[claude-code-router](https://github.com/musistudio/claude-code-router) v3 fronts
several providers behind one gateway on `127.0.0.1:3456`. With
`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` (already in the profile), Claude
Code's `/model` lists every provider's models as `provider/model`.

**This one cannot be fully automated.** CCR v3 keeps its configuration in
`~/.claude-code-router/config.sqlite`; the legacy `config.json` is read only
once, on a machine that has no SQLite config yet. So the installer can install
CCR and the profile, but the providers, the client key, and the agent profile
must be created by hand, once:

```bash
npm install -g @musistudio/claude-code-router   # needs Node.js >= 22
ccr ui                                          # admin UI on http://127.0.0.1:3458
```

In the UI:

1. **Providers** — add Zhipu (`https://open.bigmodel.cn/api/anthropic`, type
   `anthropic_messages`, models `glm-5.2`/`glm-5-turbo`/`glm-4.7`) and, if you
   use it, your local CLIProxyAPI (`http://127.0.0.1:8317`).
2. **API Keys** — create a CCR client key. It is shown once. Paste it into
   `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/ccr.json`.
3. **Agent profiles** — add a Claude Code profile and set its default model.
4. **Service** — confirm the gateway is up.

Then `cl_ccr`, and `/model` shows everything in one list.

Filling in `modelDescriptions` for a provider is what enables CCR's automatic
subagent routing.

## Adding your own backend

Write `~/.claude/profiles/<name>.json`. Two constraints on `<name>`:

- It must match `^[A-Za-z0-9_-]+$`. Anything else — a space, a quote, a dot — is
  skipped, because the name is interpolated into a shell function definition and
  a malformed one used to break every new shell.
- It must not collide with a built-in command: `switch`, `auto`, `stop`,
  `profiles`. Those already own their `cl_*` function and a profile of the same
  name is skipped rather than shadowing them.



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

Open a new shell and `cl_<name>` exists. Keys named in `credentialKeys` are
carried across re-installs — everything else is refreshed from the repo
template, so model defaults track upstream without ever clobbering your key.

To have a profile manage a local proxy, add:

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

`{bin}` is replaced with the first entry of `bins` that exists on `PATH`. If
none does, the launcher refuses to start and prints `installHint`.

## Migration from `glm-env.json`

The installer moves a pre-2.11 `~/.claude/glm-env.json` to
`~/.claude/profiles/glm.json`, keeps your credentials, and renames the old file
to `glm-env.json.migrated`. `claude.zsh` still reads the flat legacy file if the
profiles directory is missing entirely, so a partial upgrade won't strand you.

`--uninstall` deliberately leaves `~/.claude/profiles/` in place, because those
files hold API keys you pasted in.

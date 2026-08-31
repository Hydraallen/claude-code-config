# Model Backends

[中文版](BACKENDS.zh-CN.md)

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
| `cl_claude`, `cl_glm`, `cl_or`, `cl_gpt`, `cl_ccr` | Force a specific backend |
| `cl_<name>_auto` | Same, skipping permission prompts |
| `cl_switch <name>` | Change the default |
| `cl_stop [<name>\|--all]` | Stop proxy services the launcher started |
| `cl_profiles` | List backends, their labels, and whether each is ready |

`cl_<name>` is generated at source time from whatever is in the profiles
directory — adding a backend never requires editing `claude.zsh`.

Every launch prints the backend and the model it resolved to, e.g.
`cl_glm: backend 'glm' (https://open.bigmodel.cn/api/anthropic, 20 vars)` then
`cl_glm: model opus -> glm-5.3`.

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

> **`gpt` and `ccr` are not selected by default.** Since 2.22.0 the installer
> ships them unticked in the "Model Backends" group — both need something the
> installer cannot do for you (a `brew` binary plus a reverse-engineered OAuth
> for `gpt`, a manual web-UI configuration for `ccr`). Nothing was removed: tick
> them to install, `--all` still includes them, and an already-installed
> `gpt.json` / `ccr.json` survives every upgrade untouched.

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

Coding Plan covers **`glm-5.3` (1M in / 128K out), `glm-5.3-flash` (1M in /
128K out), `glm-5-turbo` (200K), `glm-4.7` (200K)** — opus and sonnet route to
`glm-5.3`, haiku and fable route to `glm-5.3-flash` (added to the plan
2026-08-26 at 3x the glm-5.3 quota; natively multimodal, thinking always on).
`glm-5-turbo` and `glm-4.7` are covered by the plan but wired to no slot.
`fable` is Claude Code's background slot (compact, session titles, quota probes).
It is a selectable alias like the others, but the client also uses it for requests
you never issue — so leaving it unmapped fails on traffic you did not ask for, with
the literal id `claude-fable-5` going out and 400ing.
`glm-5` and `glm-5.1` are auto-routed to `glm-5.3` upstream, so don't pin them.
For vision, the haiku/fable model `glm-5.3-flash` is natively multimodal;
**`glm-5v-turbo` (200K)** has no slot of its own but is reachable with
`cl_glm --model glm-5v-turbo`.

#### Unlocking glm-5.3's 1M context

Claude Code hardcodes a 200K context limit for any model id it does not
recognise, and no `glm-*` id is in its registry — so without help the client
compacts at 200K and caps output at its 32K default, wasting four fifths of what
glm-5.3 actually accepts. The profile therefore sets:

| Var | Value | Why |
|---|---|---|
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `1000000` | The client honours this only for non-`claude-*` model ids; it is the intended escape hatch |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `1000000` | The compact window is `min(contextLimit, thisVar)`, so setting it alone is a no-op — both are needed |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | glm-5.3 tops out at 128K output; `131072` would be clamped by the client, which accepts at most `128000` |

Nothing extra is needed server-side — no header, no `[1m]` suffix on the model
id. Do **not** rename the model to `glm-5.3[1m]`: that is not a Z.ai model code
and it would go out on the wire.

> **Caveat — one limit, four models.** `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is a
> single client-wide value, not per-slot. It matches glm-5.3 and glm-5.3-flash
> (1M each), which now fill all four shipped slots, so no slot the profile
> wires is undersized any more. Only models you pin by hand — **`glm-5-turbo` /
> `glm-4.7` (200K)** — are: with one of those pinned the client will let the
> context grow past what the server accepts and auto-compact will not save
> you. Keep such sessions under 200K, or `cl_switch` to a backend sized for
> them.

Docs: <https://docs.bigmodel.cn/cn/coding-plan/tool/claude>

The statusline reads this backend's 5h quota too — see
[Quota in the statusline](#quota-in-the-statusline) below.

### `or` — OpenRouter (direct)

Paste your OpenRouter key (`sk-or-v1-…`) into `.env.ANTHROPIC_AUTH_TOKEN` of
`~/.claude/profiles/or.json`, then:

```bash
cl_or
```

Like `glm`, this is a direct connection: `service` is `null`, no local proxy is
started, and nothing is installed.

#### Log out of Anthropic first

A cached Anthropic OAuth session **outranks** the environment variables the
profile injects. Run `/logout` inside Claude Code once before the first `cl_or`
launch, otherwise your requests keep going to Anthropic and the OpenRouter key
is never used. This is a one-time step per machine, not per launch.

#### Why the base URL has no `/v1`

`ANTHROPIC_BASE_URL` is `https://openrouter.ai/api`, deliberately without a
trailing `/v1`. Claude Code appends `/v1/messages` itself; adding `/v1` here
produces `/v1/v1/messages` and a 404.

#### Why `ANTHROPIC_API_KEY` is the empty string

OpenRouter authenticates with `Authorization: Bearer`, which Claude Code sends
only when `ANTHROPIC_API_KEY` is falsy. As soon as that variable holds *any*
value the client switches to the `x-api-key` header and treats the call as a
direct Anthropic request — the OpenRouter token never leaves the machine. So
the profile pins it to `""`. Three details follow from that:

- **`env`, not `unset[]`.** The launcher's `unset[]` performs a real `unset`,
  which is not the same as an empty value; an inherited-then-unset variable and
  an explicitly-empty one behave identically here only by accident, and the
  empty string is what is actually specified. Restoration on exit is correct
  either way: `_cl_save_var` records "was not set" separately from "was set to
  X" and puts the shell back exactly as it found it.
- **The empty value really is injected.** `_cl_profile_env_pairs` rejects only
  `array` and `object` values, so `""` emits the line `ANTHROPIC_API_KEY=`, and
  the injection loop skips empty *keys*, not empty values.
- **Not in `credentialKeys`.** Re-installs preserve only the keys listed there,
  so leaving it out means every upgrade rewrites the empty string from the
  template. It also keeps it out of the "still a placeholder" scan, which is
  correct — an empty string is not something you are supposed to fill in.

#### Model slots

| Slot | Model | Context / output |
|---|---|---|
| `opus`, `sonnet` | `deepseek/deepseek-v4-pro` | 1,048,576 / 393,216 |
| `haiku`, `fable` | `deepseek/deepseek-v4-flash` | 1,048,576 / 384,000 |

`fable` is Claude Code's background slot (compact, session titles, quota
probes), so it is pointed at the cheaper model.

> **Caveat — one context limit, all slots.** `CLAUDE_CODE_MAX_CONTEXT_TOKENS`
> is a single client-wide value. It is set to `1000000` because both DeepSeek V4
> models accept ~1M. If you repoint any slot at a 163K-context model
> (`deepseek/deepseek-v3.2`, `deepseek/deepseek-chat`) you **must** lower it by
> hand — otherwise the client grows the context past what the server accepts and
> auto-compact will not rescue you.

> **`deepseek/deepseek-reasoner` does not exist on OpenRouter.** That id belongs
> to DeepSeek's own API. Using it here 404s.

#### No `_SUPPORTED_CAPABILITIES` keys

The `effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking`
strings that `glm.json` and `gpt.json` carry are intentionally absent. They make
Claude Code emit Anthropic thinking/effort parameters that OpenRouter has to
translate into DeepSeek's `reasoning` field, and `adaptive_thinking` /
`interleaved_thinking` have no DeepSeek counterpart at all — a plausible source
of sporadic 400s. If you want reasoning controls, add them back one key at a
time and test after each.

#### Best-effort, and untested

OpenRouter's own documentation says the native Anthropic endpoint

> "is built for Anthropic models and is only guaranteed to work with the
> Anthropic first-party provider",

and that "Claude Code expects Anthropic request semantics, so non-Anthropic
models aren't supported through the native endpoint". That is a
*no-guarantee*, not a hard API-level rejection, and no public report of DeepSeek
succeeding or failing through this endpoint exists either way. **This profile
has never been exercised against a live OpenRouter key** — in particular
`tool_use` round-trips through DeepSeek are unverified. If it misbehaves, check
tool calls first.

There is no 5h quota bar for this backend — see
[Quota in the statusline](#quota-in-the-statusline) below.

Docs: <https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration>

### `gpt` — ChatGPT Plus/Pro subscription

Backed by [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), which
exposes an Anthropic-compatible `/v1/messages` on `127.0.0.1:8317`.

> **Read the risk section at the end of this subsection before you start.**

> This backend exposes no quota endpoint, so the statusline renders **no quota
> segment** on a `gpt` terminal. Every other segment is unaffected. See
> [Quota in the statusline](#quota-in-the-statusline).

#### Step 1 — install

```bash
brew install cliproxyapi
```

**The binary name depends on how you installed it.** Homebrew installs
`cliproxyapi`; a `go build -o cli-proxy-api ./cmd/server` source build gives
`cli-proxy-api`. The profile lists both in `service.bins` and uses whichever it
finds on `PATH`, so either works — but the upstream docs are written for
`cli-proxy-api`, and on a brew install you must substitute `cliproxyapi` in
every command they show.

#### Step 2 — select `gpt` in the installer (the key is reconciled automatically)

Once you select `gpt`, the installer's `configure_gpt_backend` reconciles the
CLIProxyAPI key and normalizes the config for you — **you no longer invent or
paste a key.** It resolves the key by this strict precedence (config-first):

1. **Config key.** The first entry of `api-keys:` in
   `~/.cli-proxy-api/config.yaml` is authoritative when it is a real value
   (a leftover placeholder is rejected, not reused).
2. **Profile token.** If the config has no usable key, the value of
   `.env.ANTHROPIC_AUTH_TOKEN` in `~/.claude/profiles/gpt.json` is reused.
3. **Generated.** If neither resolves, a fresh 32-byte key (64 lowercase hex
   characters) is generated.

The resolved key is written to **both** `config.yaml` and `gpt.json`, keeping
them in sync. Any existing `config.yaml` is first copied to a timestamped
`config.yaml.YYYYMMDDHHMMSS.bak` (mode `600`) and then **normalized** to the
loopback-only shape below; if the file is already normalized, no backup is
written. `~/.cli-proxy-api` is created with mode `700`; `config.yaml` and
`gpt.json` are both kept at mode `600`.

The normalized config is exactly:

```yaml
host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "<the resolved key>"
```

With **one optional line**: when an outbound `proxy-url` is resolved (see
"Step 4b — outbound proxy (`proxy-url`)" below), a 6th line `proxy-url: "…"`
is inserted between `auth-dir` and `api-keys`; when none is resolved the
5-line form above is emitted byte-for-byte unchanged.

Three of those values are load-bearing:

- **`api-keys` must be non-empty.** If the list is empty or absent, CLIProxyAPI
  unregisters its auth provider entirely and **every `/v1/*` route then accepts
  any request, with any token or none at all.** It fails open, not closed.
  Don't confuse `api-keys` with `remote-management.secret-key`, which guards a
  different API; they are intentionally separate.
- **`host: "127.0.0.1"`** — the upstream default is `""`, which binds *all*
  interfaces. Combined with the fail-open behaviour above, the default config
  would put an unauthenticated proxy onto your ChatGPT subscription on your LAN.
- **`port: 8317`** matches the launcher and the profile.

The launcher always starts the proxy with
`--config "$HOME/.cli-proxy-api/config.yaml"`, so that exact path must exist
regardless of install method — Homebrew's own default
(`$(brew --prefix)/etc/cliproxyapi.conf`) is *not* what the launcher uses. A
missing or unreadable config, or a proxy that exits during start-up, is a
**hard exit**, not a fall-back to defaults.

#### Step 3 — log in once (manual)

```bash
cliproxyapi --codex-login            # or ./cli-proxy-api --codex-login
```

This step is **still manual** — the installer cannot perform OAuth on your
behalf. A browser opens; log in to your ChatGPT account and approve. The OAuth
callback lands on **`http://localhost:1455/auth/callback`**, so port 1455 must
be free — override it with `--oauth-callback-port <n>` if something else holds
it. On a headless box use `--no-browser` (prints the URL) or
`--codex-device-login`.

Credentials are written into `auth-dir` as
`codex-<hash>-<email>-<plan>.json`. Multiple accounts produce multiple files and
are load-balanced round-robin.

#### Step 4 — launch

```bash
cl_gpt            # or cl_gpt_auto
```

`cl_gpt` health-checks `http://127.0.0.1:8317/healthz` first, starts the proxy
in the background only if needed, waits for it to come up, and logs to
`~/.claude/logs/cli-proxy-api.log`.

> **Windows limitation.** GPT auto-configuration and the `cl_gpt` /
> `cl_gpt_auto` launchers are Bash/Zsh-only. `install.ps1` reports this and
> points back at `docs/BACKENDS.md`; it does **not** create or write
> `~/.cli-proxy-api/config.yaml`.

Note that `/healthz` returns 200 as soon as the HTTP listener is up — it says
nothing about whether your credentials loaded or the upstream is reachable. A
green health check plus failing requests means step 3 didn't take.

#### Step 4b — outbound proxy (`proxy-url`, optional)

CLIProxyAPI can route its upstream HTTPS through a local forwarder when you are
behind a corporate/VPN proxy. The installer reconciles an optional top-level
`proxy-url:` scalar in `config.yaml`; it never invents one. The precedence is
the same shape as the key (config-first):

1. **Config `proxy-url`.** A top-level `proxy-url:` in
   `~/.cli-proxy-api/config.yaml` is authoritative when it is a valid URL.
   A leftover placeholder is rejected, not reused.
2. **`GPT_PROXY_URL` env var.** If the config has no `proxy-url:`, an explicit
   `GPT_PROXY_URL` is consumed.
3. **Omitted.** If neither resolves, the line is simply absent and
   CLIProxyAPI connects directly.

```bash
# one-shot: pass an explicit upstream proxy for this install run
GPT_PROXY_URL="http://user:secret@127.0.0.1:10808" ./install.sh
```

Accepted schemes are `http://`, `https://`, `socks5://`, `socks5h://`. The URL
**may contain credentials** (`scheme://user:pass@host:port`) and is **never
printed** by the installer — not in normal output, not in warnings, not under
`set -x` (the coordinator suppresses xtrace for the inner resolver). It is
captured through a temp-file redirect so the value never crosses stdout. Store
it in `config.yaml` (mode `600`) or pass it via `GPT_PROXY_URL` for a single
run.

**Standard proxy env vars are deliberately not auto-persisted.** `HTTP_PROXY`,
`HTTPS_PROXY`, and `ALL_PROXY` are ignored by the resolver — they routinely
carry short-lived credentials, and silently writing them into `config.yaml`
would break idempotency and leak secrets at rest. Opt in explicitly via
`GPT_PROXY_URL` or a hand-written `proxy-url:`.

**A malformed existing `proxy-url` fails safe.** If the config carries a
top-level `proxy-url:` that is unparseable, has an unsupported scheme, or
contains control/YAML-injection characters, `configure_gpt_backend` records a
critical error and returns **without touching** `config.yaml` or `gpt.json` —
no silent rewrite strips your value. A malformed explicit `GPT_PROXY_URL` fails
the same way. Fix the value and re-run.

> **Why bother?** With no `proxy-url`, CLIProxyAPI connects to OpenAI
> directly. An initial direct-connect **500** from the upstream can trigger a
> secondary **503 auth-cooldown** state that lingers for the process, so the
> first few requests after login fail in a way that does not look like an auth
> problem. Routing the upstream through a stable `proxy-url` avoids that
> direct-connect path entirely.

> **CCR is a separate plane.** The `ccr` backend runs on its own port `3456`
> and is independent of this `8317` proxy: `cl_ccr` never traverses
> CLIProxyAPI. CCR loads its own upstream proxy via the `gateway-proxy-preload.cjs`
> preload together with the `CCR_UPSTREAM_PROXY_URL` env var, backed by Undici's
> `ProxyAgent`, and the GUI proxy setting is disabled. The two proxy planes
> share no state; setting `proxy-url` here does not affect CCR and vice versa.

#### Choosing models

Model IDs carry an optional reasoning-effort suffix, `model(level)`. **Quote
them in zsh** — the parentheses are shell metacharacters and the upstream docs
show them unquoted, which breaks:

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.5(high)'
```

The embedded catalog currently exposes `gpt-5.6-sol`, `gpt-5.6-terra`,
`gpt-5.6-luna`, `gpt-5.5`, `gpt-5.3-codex-spark`. The live list is refreshed
remotely at runtime unless the server is started with `--local-model`, so check
`curl http://127.0.0.1:8317/v1/models` rather than trusting any written list.

**Read this before using it.** This path reuses a consumer subscription through
a reverse-engineered OAuth flow. OpenAI's terms prohibit sharing account
credentials with third-party clients, and the proxy ships a "cloaking" mode that
forges `User-Agent`/`Originator` headers to look like the official Codex CLI —
which strongly implies OpenAI validates client fingerprints. Separately,
Anthropic's own docs state they *"do not support routing Claude Code to
non-Claude models through any gateway"*. Neither vendor will help you if this
breaks, and it can break at any release. The `claude` and `glm` profiles carry
none of this risk.

### Image generation — `sinedied/agent-skills:image-gen`

This repo ships **no image-generation code**. The `image-gen` Skill is fetched
over the network by both installers and is **always installed** — there is no
menu item for it, and it installs even when every selectable item is
deselected:

```bash
npx -y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen
```

`DO_NOT_TRACK=1` disables the `skills` CLI's anonymous telemetry; `--copy`
writes real files (not symlinks) so `--uninstall` can remove them. A missing
`npx` or a network failure is non-fatal: the install records a warning and
continues, so the version stamp and the rest of the install still complete.
The Skill lands at `~/.claude/skills/image-gen/` (a global `$HOME` path); no
upstream `image_gen.py`, prompts, samples, or license is tracked in this repo.
A repository-owned wrapper is installed at
`~/.claude/scripts/image-gen-openrouter.py` and the downloaded `SKILL.md` is
augmented idempotently with a managed instructions block.

The upstream `image_gen.py` is **not executed**. Its `/v1/images/generations`
and `/v1/images/edits` routes do not exist on OpenRouter, and image editing
there is expressed as reference images on the same generation endpoint. The
installer still checks that `scripts/image_gen.py` is present, purely as proof
that `npx` downloaded the layout we expect and not something else under the
same name.

#### Model, endpoints, arguments

| | |
|---|---|
| Default image model | `openai/gpt-image-2` (override with `--model` or `IMAGE_GEN_MODEL`) |
| Base URL | `https://openrouter.ai/api/v1` (override with `--base-url` or `IMAGE_GEN_BASE_URL`) |
| Generation route | `POST /api/v1/images` — used for both `generate` and `edit` |
| Availability precheck | `GET /api/v1/images/models`, requires an exact `data[].id` match on the target model |
| Timeout | 300 s per request (`IMAGE_GEN_TIMEOUT`) |
| Runtime | `python3`, standard library only — no third-party packages, no local service |

The wrapper is **fail-closed**: it calls `GET /api/v1/images/models` before
every generation and exits `4` if the target model is absent or the list cannot
be parsed, printing the first few model ids that *are* available. There is no
bypass switch — an unverified endpoint never receives a generation request.

Argument surface (a superset of the upstream CLI, so existing guidance keeps
working):

| Argument | Behaviour |
|---|---|
| `generate` / `gen`, `edit` | Preserved, including the `gen` alias |
| `-o/--output` | Identical to upstream: file-vs-directory mode, `_N` suffix for `--n > 1`, existing files are **never** overwritten |
| `-m/--model`, `--n`, `-q/--quality`, `--background`, `-f/--output-format`, `--output-compression` | Preserved; `--n` is validated locally against OpenRouter's 1–10 limit |
| `-s/--size` | Widened: the `512`/`1K`/`2K`/`4K` tiers and arbitrary `WxH` are accepted alongside the old values |
| `-i/--image` (edit) | Widened: local paths are base64 data-URL encoded, and http(s) URLs pass through directly; up to 16 references |
| `--aspect-ratio`, `--resolution`, `--seed` | New — OpenRouter-native |
| `--api-key` | **Accepted but refused.** A key must never appear in argv; the wrapper explains where to put it instead |
| `--mask` (edit) | **Accepted but refused.** OpenRouter has no inpainting mask; describe the region in the prompt |
| `--moderation` (generate) | Accepted, warned about, and ignored — the request body has no such field |
| `.env` auto-loading | **Removed.** Upstream walked up from the CWD looking for a `.env` to inject; generating an image inside an arbitrary repo should not read that repo's secrets |

Exit codes are graded rather than always `1`: `0` success, `1` API/IO failure,
`2` argument usage error, `3` no usable API key, `4` model precheck failed.

#### Where the key comes from — no OpenAI Platform key

The wrapper reads **one** source: `.env.ANTHROPIC_AUTH_TOKEN` in
`~/.claude/profiles/or.json` — the same token the `or` backend uses. There is
no environment-variable fallback, so there is exactly one place to fill in and
exactly one place to rotate.

- The key is used **only** as an `Authorization: Bearer` request header. It
  never enters argv, a subprocess environment, stdout, stderr, or any error
  message; HTTP failures echo the URL and a truncated response body only.
- It must match `[A-Za-z0-9._~-]+`, which is header-safe and rules out newline
  injection into the request headers. OpenRouter keys (`sk-or-v1-…`) qualify.
- The unfilled template placeholder is treated as *absent*, not as a key, so
  you get "fill in your key" rather than a 401 from the API.

**This means image generation requires the OpenRouter backend to be installed
and its key filled in**, whether or not you use `cl_or` for chat. Tick
"OpenRouter" in the installer, then put a key from
<https://openrouter.ai/keys> into `~/.claude/profiles/or.json`.

#### All launchers share the same paths

`claude.zsh` contains no image-gen coupling. Every `cl`, `cl_claude`, `cl_glm`,
`cl_or`, `cl_gpt`, `cl_ccr`, and generated `cl_<name>_auto` flows through
`_cl_profile_run` → `_cl_run` → `claude`, which only manages `ANTHROPIC_*` env
and the `claude` binary. The Skill and wrapper live at global `$HOME` paths the
launcher never touches, so image generation works from any backend — and it no
longer depends on any local proxy being up, because the request goes straight
to OpenRouter over HTTPS.

#### Ownership-safe uninstall

The installer writes a mode-600 manifest at `~/.claude/.image-gen-sinedied`
only after the wrapper exists, the upstream layout (`SKILL.md` +
`scripts/image_gen.py`) validates, and augmentation succeeds:

```text
skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-openrouter.py
```

`--uninstall` deletes `~/.claude/skills/image-gen` only when **all three**
agree: a byte-exact canonical manifest, the directory layout, **and**
well-formed augmentation markers in `SKILL.md`. A user-authored directory that
collides by name, a planted/leftover valid manifest without the markers, or a
stale manifest with the directory absent are all preserved (only a stale
manifest is pruned). The wrapper itself is removed through the same
`USER_SCRIPTS` loop that manages `cleanup-claude-data.sh`. A prior-owned
upgrade is backed up before `npx` runs and restored byte-for-byte on any later
failure; on restore failure the backup is retained and its path emitted.

#### Upgrading from the CLIProxyAPI-era install

Both the managed markers and the manifest's `wrapper=` line changed with the
move to OpenRouter. Ownership checks therefore accept **either** the current
values or the pre-OpenRouter ones; without that, every existing install would
fail the ownership proof, be classified as "not installer-owned", and be
skipped forever with a warning. Only the current values are ever *written*, so
the migration happens exactly once, on the next successful install:

1. The legacy manifest and markers still prove ownership, so the upgrade
   proceeds normally instead of being skipped.
2. Augmentation strips the legacy block before inserting the current one, so
   the file ends up with exactly one managed block rather than two.
3. A canonical manifest is written, and every later run takes the pure
   current-format idempotent path.

`~/.claude/scripts/image-gen-cliproxyapi.sh` is deleted automatically on the
next install — it is no longer in `USER_SCRIPTS`, so uninstall would otherwise
leave it behind as an orphan.

#### Native Windows

The wrapper is now a dependency-free Python script with no local service, so it
runs anywhere `python3` is on PATH. `install.ps1` fixes a long-standing path bug
in this release (it looked for `image-gen\image_gen.py` instead of
`image-gen\scripts\image_gen.py`, which made augmentation — and therefore the
whole image-gen install — fail on every Windows run). Running the Bash installer
**inside WSL** is still recommended so the layout lands in the WSL `~/.claude`;
WSL does not see `%USERPROFILE%\.claude` as `~/.claude`, and Git Bash's mapping
depends on the install. Real PowerShell runtime behaviour was **not** verified
here; a pwsh-equipped Windows machine must confirm the parser, the
`cmd.exe /d /s /c` `npx.cmd` invocation, the byte-level `SKILL.md` augmentation
(including the new legacy-block strip), and the manifest atomicity.

### `ccr` — one `/model` list across providers

[claude-code-router](https://github.com/musistudio/claude-code-router) v3 fronts
several providers behind one gateway. With
`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` (already in the profile), Claude
Code's `/model` lists every provider's models as `provider/model`.

> This backend exposes no quota endpoint, so the statusline renders **no quota
> segment** on a `ccr` terminal — whichever provider the gateway routes to. Every
> other segment is unaffected. See
> [Quota in the statusline](#quota-in-the-statusline).

**Two ports, and mixing them up is the most common mistake:**

| Port | What it is | Who talks to it |
|---|---|---|
| `127.0.0.1:3458` | Management **UI** | Your browser |
| `127.0.0.1:3456` | Model **gateway** | Claude Code (`ANTHROPIC_BASE_URL`) |

**This one cannot be fully automated.** CCR v3 keeps its configuration in
`~/.claude-code-router/config.sqlite`; the legacy `config.json` is read only
once, on a machine that has no SQLite config yet. So the installer can install
CCR and the profile, but the providers and the client key must be created by
hand, once.

#### Step 1 — install and open the UI

```bash
node --version                                   # must be >= 22
npm install -g @musistudio/claude-code-router
ccr ui                                           # opens http://127.0.0.1:3458
```

`ccr ui` starts the background service if it isn't already running — you do not
need `ccr start` first. The command prints a URL containing a `ccr_web_token`
query parameter: **treat that whole URL as a password.** Set
`CCR_WEB_AUTH_TOKEN` if you want a stable token instead of a fresh random one
each process.

The v3 commands are `ccr start`, `ccr ui`, `ccr stop`, `ccr serve` (foreground),
`ccr web` (alias of `serve`), and `ccr <profile>`. There is **no `ccr status`
and no `ccr restart`** — to change host or port you must `ccr stop` first, then
`ccr start --host … --port …`; changing them on a running service silently does
nothing.

#### Step 2 — add a provider

**Providers** → **Add Provider**. For GLM, don't hand-type anything: pick the
built-in preset **Zhipu AI (China) - Coding Plan** (or **Z.ai (Global) - Coding
Plan** outside China). Each coding-plan preset ships two endpoints:

| Endpoint | Protocol |
|---|---|
| `https://open.bigmodel.cn/api/coding/paas/v4` | OpenAI Chat Completions |
| `https://open.bigmodel.cn/api/anthropic` | **Anthropic Messages** |

Pick the Anthropic Messages one. Paste your BigModel key into **API key**, then
use **Search models** or **Custom models** to select `glm-5.3`, `glm-5-turbo`,
`glm-4.7`.

To also front your local CLIProxyAPI, add a second provider: **Other / custom
API endpoint**, endpoint `http://127.0.0.1:8317`, protocol **Anthropic
Messages**.

**Check Connection** sends real model requests and costs real tokens. Worth
running once; just don't leave it on a loop.

#### Step 3 — copy the **Local Gateway** key (not a profile key)

The **API Keys** page lists more than one kind of key, and only one works here:

| Name in the UI | Use for our launcher? |
| --- | --- |
| `Local Gateway` — `sk-ccr-…` | **Yes.** This is the one. |
| `Profile: <agent>` — `ccr-profile-…` | **No.** Scoped to CCR's own `ccr <profile>` launch path. |

Paste the `sk-ccr-…` value into `.env.ANTHROPIC_AUTH_TOKEN` of
`~/.claude/profiles/ccr.json`.

Getting this wrong fails in a way that does not look like an auth problem. A
`ccr-profile-…` key returns **401 on `GET /v1/models`** — exactly the request
gateway model discovery makes at startup — so Claude Code comes up with no model
metadata at all and greets you with *"Context limit reached"* before you have
typed anything. Check yours:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $KEY" http://127.0.0.1:3456/v1/models   # want 200
```

**Add API key** also offers an expiration and per-minute/hour/day request or
token limits under **Advanced settings**. A new key is displayed **once**.

> Three distinct secrets live in CCR and none are interchangeable: this gateway
> key, the `ccr_web_token` in the UI URL, and your upstream provider key
> (BigModel, etc.).

#### Step 4 — start the gateway, then launch

Under **Server**, click **Start**. A reachable UI does *not* mean the gateway is
up — verify with:

```bash
curl http://127.0.0.1:3456/health     # expect 200 "running"
cl_ccr
```

`/model` now lists every provider's models in one place.

#### Step 5 — let the installer fill the model slots

Re-run `./install.sh` once the gateway is up and the key is in place. It queries
`GET /v1/models` and offers to map `opus` / `sonnet` / `haiku` / `fable` onto
real ids:

```
[OK]   gateway published 12 model(s)
      1) Codex API/gpt-5.6-sol
     10) Zhipu AI (China) - Coding Plan/glm-5.3
     opus [1-12, Enter=skip]:
```

Those ids embed the **provider display name you typed into the UI**, so no
template can ship them and no installer can guess them — the running gateway is
the only source of truth. That is why this is a step rather than more static keys
in `profiles/ccr.json`. Whatever you pick lands in the profile's
`credentialKeys`, so later `./install.sh` runs preserve it.

Skipping `opus` / `sonnet` / `haiku` is fine. With those slots empty, `cl_ccr`
deliberately passes **no `--model`** and you choose per session with `/model` —
because `--model opus` against a gateway that publishes `provider/model` ids
would name a model it has never heard of.

> **`fable` is the exception — do not skip it.** Claude Code never lists fable
> under `/model`; it is the background slot (`/compact`, session titles, quota
> probes). While it is empty those requests go out as the literal id
> `claude-fable-5`, which a gateway publishing `provider/model` ids cannot
> resolve, so every one of them comes back `400 All target providers failed`.
> The foreground model still works, so the symptom is an occasional context-free
> *"API Error: 400"* mid-session and nothing pointing at the cause. Map it to a
> cheap model.

> **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is mandatory here, not a tuning knob.** CCR
> reports every model with `context_length: null`, so discovery never supplies a
> context window and Claude Code falls back to a small default — which, with a
> large startup context, is an instant *"Context limit reached"*. The profile
> ships `1000000` to match `glm-5.3`. It is **one client-wide value, not
> per-slot**: the Codex models (`gpt-5.6-*`, ~272K) and `glm-4.7` /
> `glm-5-turbo` (200K) are far smaller, and a session routed to those will grow
> past what the server accepts and fail mid-run — auto-compact will not rescue
> you. Lower it to `200000` if you route to them often.

#### Optional: Agent Profiles and routing

**Agent Profiles is optional — and for Claude Code, leave it alone.** You only
need it for `ccr <profile>` launches or to have CCR write an agent's settings
file for you. Our launcher uses neither — it sets `ANTHROPIC_BASE_URL` itself.

> **Do not bind/register Claude Code as a client in CCR's Agent Profiles.** Doing
> so makes CCR write and manage the very settings (`ANTHROPIC_BASE_URL`, the
> model slots, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`) that
> `~/.claude/profiles/ccr.json` and the `cl_ccr` launcher already control. The
> two fight, and you end up with duplicated or overwritten config, broken
> `/model` discovery, or the wrong context window. Point Claude Code at the
> gateway the documented way — launch with `cl_ccr` — and keep CCR's Agent
> Profiles empty.

Routing in v3 is **not** the old v1 `default` / `background` / `think` /
`longContext` block; that is gone. v3 has per-profile built-in routes (**Use
enhanced route**), a **Routing** page of ordered custom rules, and optional
Node.js script rules. Subagent routing works by injecting
`<CCR-SUBAGENT-MODEL>provider/model</CCR-SUBAGENT-MODEL>`, and only activates
once at least one model has a **Description** filled in on the **Models** page.

## Quota in the statusline

`hooks/statusline.sh` renders a 5-hour quota bar for the backend the terminal is
actually on. It picks the backend from `$ANTHROPIC_BASE_URL`, which the launcher
exports per shell, so two terminals on two backends show two different numbers at
the same time without interfering:

| `$ANTHROPIC_BASE_URL`            | Label    | Source                                              | Refresh |
| -------------------------------- | -------- | --------------------------------------------------- | ------- |
| unset (the `claude` profile)     | `5h`     | `api.anthropic.com/api/oauth/usage`, OAuth token     | 60s     |
| `*bigmodel.cn*` / `*z.ai*`       | `glm 5h` | `{host}/api/monitor/usage/quota/limit`, `$ANTHROPIC_AUTH_TOKEN` | 600s |
| anything else (`or`, `gpt`, `ccr`, …) | —   | no quota endpoint; the segment is not rendered       | —       |

The bar shows the **used** percentage, and the trailing time is when the window
resets. GLM's window is rolling — it resets five hours after the request that
opened it, not on a clock boundary — so the reset time comes from the API rather
than being computed locally.

Notes:

- **OpenRouter (`or`) has no quota bar, and cannot meaningfully have one.** Two
  independent reasons: the `case` in `hooks/statusline.sh` that picks a quota
  source from `$ANTHROPIC_BASE_URL` only knows `bigmodel.cn` and `z.ai`, and —
  more fundamentally — OpenRouter has no 5h rolling window at all. What it
  exposes is a credit balance at `/api/v1/credits`, which is money, not a
  percentage of a window with a reset time. Rendering it in this bar would
  produce a semantically wrong progress bar, so the segment stays absent.
- **GLM is polled at 1/10th the rate of the native API.** The statusline fires on
  every render, and Zhipu applies undisclosed rate-limit and risk-control rules,
  so a 600s TTL keeps an active session well clear of them. The cost is that the
  first render in a fresh terminal usually has no quota segment; the next one does.
- **Every backend gets its own cache file** under `$TMPDIR`, and on GLM every
  credential does too (`claude-usage-cache-anthropic.json`,
  `claude-usage-cache-glm-<checksum>.json`). Running the mainland and
  international GLM keys side by side is therefore safe. The checksum is of the
  token; the token itself is never written to disk. **The native Anthropic path
  is not split per credential** — its fingerprint is just `anthropic`, because
  the OAuth token is read from the keychain inside the background fetch and is
  not available when the filename is computed. Two Anthropic accounts on one
  machine share `claude-usage-cache-anthropic.json`, so after switching accounts
  the bar can show the previous account's figure for up to one refresh interval.
- **Credentials are never passed to `curl` on the command line.** Both fetch
  paths hand their headers to `curl -K -` on stdin, so no token appears in `ps`
  output for other users on the machine.
- **`export CL_NO_USAGE=1` disables quota entirely** — no fetch on any backend,
  no quota segment. It must be exported from `~/.zshrc`; a one-shot
  `CL_NO_USAGE=1 cl_glm` prefix does not reach the statusline's process.
- **The network fetch never blocks a render.** The statusline only ever reads the
  cache; a stale cache triggers a background refresh for the *next* render. Any
  failure — no credential, unreachable host, unexpected schema — silently drops
  the quota segment and leaves every other segment intact.

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

If the gateway you are pointing at authenticates with `Authorization: Bearer`
rather than `x-api-key`, add `"ANTHROPIC_API_KEY": ""` to `env` — Claude Code
sends the bearer header only while that variable is falsy, and any value at all
flips it to `x-api-key`. Put it in `env` with an empty value rather than in
`unset[]`, and keep it out of `credentialKeys` so re-installs restore it.
`profiles/or.json` is a working example.

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

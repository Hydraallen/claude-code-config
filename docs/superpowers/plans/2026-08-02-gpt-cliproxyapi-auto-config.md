# GPT CLIProxyAPI Auto-Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely create or normalize CLIProxyAPI configuration, reuse or generate its API key, synchronize the GPT profile, and replace misleading 25-second startup failures with immediate evidence-based diagnostics.

**Architecture:** `install.sh` owns installation-time reconciliation through small pure helpers plus one side-effecting coordinator. `profiles/gpt.json` declares its required config path so `claude.zsh` can perform a generic prerequisite check. Existing configs are parsed only enough to recover the first common-form key, backed up, then atomically normalized; CLIProxyAPI config is authoritative over the profile.

**Tech Stack:** Bash 3.2-compatible shell, Zsh, jq, openssl or `/dev/urandom`, JSON profile metadata, YAML text rendering, existing shell test runner.

## Global Constraints

- Bash/macOS implements automatic configuration; PowerShell only reports that no Windows `cl_gpt` runtime exists.
- Key precedence is: first valid `config.yaml` key, concrete GPT profile token, then generated key.
- Generated keys are exactly 32 random bytes encoded as 64 lowercase hexadecimal characters.
- Normalized CLIProxyAPI values are `host: "127.0.0.1"`, `port: 8317`, and `auth-dir: "~/.cli-proxy-api"`.
- Existing non-normalized config is backed up before replacement; config-file key wins conflicts.
- Key material must never be printed, logged, embedded in filenames, or generated during `--dry-run`.
- `~/.cli-proxy-api` is mode `700`; config, profile, baseline, and secret-bearing backups are mode `600`.
- File replacement is atomic and preserves the original on backup, permission, parse, or write failure.
- OAuth stays manual through `cliproxyapi --codex-login`; installation must not start the proxy or browser.
- No new YAML parser dependency is introduced.
- Tests use temporary HOME directories and never inspect real user configuration.

---

## File Map

- Modify: `install.sh` — key extraction/generation, normalized rendering, backup/atomic write, profile sync, coordinator, invocation, permissions, and setup hints.
- Modify: `profiles/gpt.json` — add generic `service.configFile` metadata.
- Modify: `claude.zsh` — prerequisite validation, early process-exit detection, and evidence-based login hints.
- Create: `tests/test_gpt_config.sh` — installer helper and integration tests using temporary HOME.
- Create: `tests/test_gpt_runtime.zsh` — Zsh service diagnostics tests.
- Modify: `install.ps1` — Windows limitation notice only.
- Modify: `docs/BACKENDS.md` — automatic config workflow, security and remaining OAuth step.
- Modify: `docs/BACKENDS.zh-CN.md` — Chinese mirror.
- Modify: `CHANGELOG.md` — version-level feature rationale and caveats.
- Modify: `VERSION` — bump `2.14.0` to `2.15.0`.
- No change: `tests/run.sh` — existing `test_*.sh` discovery picks up the Bash suite; the Bash suite invokes the Zsh suite.

---

### Task 1: Pure Key Resolution and YAML Rendering

**Files:**
- Modify: `install.sh` near the profile helpers before `install_profiles()` (`install.sh:1686-1706`)
- Create: `tests/test_gpt_config.sh`

**Interfaces:**
- Produces: `gpt_generate_key() -> stdout key, status 0|1`
- Produces: `gpt_extract_config_key <path> -> stdout first key, status 0|1`
- Produces: `gpt_extract_profile_token <path> -> stdout token, status 0|1`
- Produces: `gpt_resolve_key <config> <profile> -> stdout key, status 0|1`; sets `GPT_KEY_SOURCE` to `config`, `profile`, or `generated` only when called without command substitution by the coordinator
- Produces: `gpt_render_config <key> -> stdout normalized YAML`
- Consumes: `jq`, `openssl`, `/dev/urandom`

- [ ] **Step 1: Create the Bash test harness and failing key-generation tests**

Use the same source guard pattern as `tests/test_plugin_resolution.sh`. Add assertions equivalent to:

```bash
key=$(gpt_generate_key)
assert_match "$key" '^[0-9a-f]{64}$' "generated key is 32-byte lowercase hex"
second=$(gpt_generate_key)
assert_ne "$key" "$second" "successive generated keys differ"
```

The harness must track pass/fail counts, create fixtures only under `mktemp -d`, install an EXIT trap, and never print fixture key values.

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
bash tests/test_gpt_config.sh
```

Expected: non-zero with `gpt_generate_key: command not found` or the harness's equivalent failed assertion.

- [ ] **Step 3: Implement the minimal CSPRNG helper**

Add Bash 3.2-compatible logic:

```bash
gpt_generate_key() {
    local key=""
    if command -v openssl >/dev/null 2>&1; then
        key=$(openssl rand -hex 32 2>/dev/null) || key=""
    elif [[ -r /dev/urandom ]]; then
        key=$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n') || key=""
    fi
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$key"
}
```

Do not add logging inside this helper.

- [ ] **Step 4: Run the focused test and confirm GREEN**

Run `bash tests/test_gpt_config.sh`.

Expected: key generation cases pass.

- [ ] **Step 5: Add failing extraction fixtures**

Cover these synthetic files without printing the recovered values:

```yaml
api-keys:
  - "block-first"
  - "block-second"
```

```yaml
api-keys: ["inline-first", "inline-second"]
```

Also cover: unquoted scalar, empty list, comments, nested `api-keys`, `YOUR_CLIPROXYAPI_KEY`, aliases/anchors, mappings, and missing file. Assert only the first valid top-level scalar is accepted.

Add profile fixtures for concrete, missing, empty, and `YOUR_*` tokens.

- [ ] **Step 6: Run extraction tests and confirm RED**

Run `bash tests/test_gpt_config.sh`.

Expected: failures for undefined extraction functions.

- [ ] **Step 7: Implement constrained extraction**

Implement `gpt_extract_config_key` with `awk`/shell parsing limited to a top-level `api-keys:` block or inline sequence. Reject empty values and advanced YAML tokens (`{}`, `&`, `*`, aliases, nested objects). Strip matching single/double quotes and inline whitespace, but do not treat ambiguous syntax as a key.

Implement:

```bash
gpt_extract_profile_token() {
    local path=$1 token
    [[ -r "$path" ]] || return 1
    token=$(jq -er '.env.ANTHROPIC_AUTH_TOKEN // empty' "$path" 2>/dev/null) || return 1
    [[ -n "$token" && "$token" != YOUR_* ]] || return 1
    printf '%s' "$token"
}
```

- [ ] **Step 8: Add failing precedence and rendering tests**

Assert:

- Config `config-key` + profile `profile-key` resolves to `config-key`.
- Missing valid config + profile `profile-key` resolves to `profile-key`.
- Neither source resolves to a generated 64-character key.
- Rendering is byte-for-byte:

```yaml
host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "synthetic-key"
```

- [ ] **Step 9: Implement resolution and rendering**

`gpt_resolve_key` must try config, profile, generation in that order and identify the source without printing it. Because command substitution runs in a subshell, the coordinator must obtain source and key through an explicit delimiter-free protocol or two variables in the current shell; choose one implementation and test it. Do not print source and key on the same stdout stream.

`gpt_render_config` must reject an empty key and render only the five normalized lines above.

- [ ] **Step 10: Run tests and shell syntax checks**

Run:

```bash
bash tests/test_gpt_config.sh
bash -n install.sh
```

Expected: all Task 1 tests pass; syntax check exits 0.

- [ ] **Step 11: Commit Task 1**

```bash
git add install.sh tests/test_gpt_config.sh
git commit -m "feat(installer): add GPT key resolution helpers"
```

---

### Task 2: Atomic Configuration Reconciliation

**Files:**
- Modify: `install.sh` near Task 1 helpers and `install_shell_wrapper()` (`install.sh:1638-1679`)
- Modify: `tests/test_gpt_config.sh`

**Interfaces:**
- Consumes: Task 1 helpers
- Produces: `gpt_backup_file <path> -> stdout backup path, status 0|1`
- Produces: `gpt_atomic_write <path> <content> -> status 0|1`
- Produces: `gpt_sync_profile_token <profile> <key> -> status 0|1`
- Produces: `configure_gpt_backend -> status 0|1`

- [ ] **Step 1: Add failing atomic-write and backup tests**

Using a temporary HOME, test:

- Backup name matches `config.yaml.YYYYMMDDHHMMSS.bak` and mode is `600`.
- Atomic write produces exact content and mode `600`.
- A forced backup failure leaves original bytes unchanged.
- A forced temp-write/rename failure leaves original bytes unchanged and no temp file.

Use a portable mode helper:

```bash
file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}
```

Inject failures through test-only function stubs or unwritable fixture directories rather than touching real paths.

- [ ] **Step 2: Run the focused suite and confirm RED**

Run `bash tests/test_gpt_config.sh`.

Expected: undefined backup/atomic helpers fail.

- [ ] **Step 3: Implement restrictive backup and atomic replacement**

Requirements:

- Temporarily set `umask 077` and restore it before return.
- Create temp files in the target directory with `mktemp "${path}.tmp.XXXXXX"`.
- Write and `chmod 600` before `mv -f`.
- Remove temp file on every failure.
- For backup, `cp -p` then `chmod 600`; return its path only after success.
- Never include key material in path or log text.

- [ ] **Step 4: Add failing profile-sync tests**

Start with the full `profiles/gpt.json` fixture. Assert only `.env.ANTHROPIC_AUTH_TOKEN` changes and these remain identical: `service`, `credentialKeys`, model slots, `ANTHROPIC_BASE_URL`, `unset`, `note`. Invalid JSON and failed atomic replacement must preserve original bytes.

- [ ] **Step 5: Implement `gpt_sync_profile_token`**

Use:

```bash
updated=$(jq --arg key "$key" '.env.ANTHROPIC_AUTH_TOKEN = $key' "$profile" 2>/dev/null) || return 1
```

Validate `updated` with `jq -e .`, skip the write if normalized JSON is unchanged, otherwise call `gpt_atomic_write`.

- [ ] **Step 6: Add failing coordinator integration cases**

Run each case in a subshell with isolated `HOME`, `CLAUDE_DIR`, `GPT_CONFIG_DIR`, and copied GPT profile:

1. Fresh install creates directory `700`, config/profile share generated key, files are `600`.
2. Second run preserves key and creates no backup.
3. Existing block/inline key is reused.
4. Multiple keys are backed up then normalized to the first.
5. Config/profile conflict uses config key.
6. Config lacks key but profile has a concrete token; profile token is used.
7. Malformed/custom config is backed up and normalized.
8. `DRY_RUN=true` creates nothing, generates nothing, and emits no secret.
9. Backup failure records failure and preserves config/profile.
10. Captured stdout/stderr does not contain the synthetic resolved key.

- [ ] **Step 7: Run coordinator cases and confirm RED**

Run `bash tests/test_gpt_config.sh`.

Expected: undefined coordinator or failed state assertions.

- [ ] **Step 8: Implement `configure_gpt_backend`**

Behavior:

```text
if gpt not selected -> return 0
if DRY_RUN -> report planned reconciliation, return 0
require readable installed gpt profile and jq
resolve key
render target config
mkdir/chmod config directory 700
if existing config differs -> backup first
write normalized config atomically
sync profile atomically
chmod secret-bearing profile/baseline/backup files 600
report source category only
```

Before the first write, compute and validate both target contents so a parse failure cannot leave only one file updated. If the config write succeeds but profile sync fails, restore config from the just-created backup; for a new config, remove it. Increment `INSTALL_CRITICAL` and return non-zero on random, backup, permission, parse, or write failure.

- [ ] **Step 9: Wire coordinator after profile installation**

In `install_shell_wrapper()`, preserve this order:

```bash
install_profiles
configure_gpt_backend
configure_ccr_profile
choose_default_profile
```

The coordinator itself checks whether `gpt` is selected.

- [ ] **Step 10: Secure all profile artifacts that may contain credentials**

After copies/writes in `install_profiles()`, apply mode `600` to installed profile JSON, `.baseline/*.json`, and timestamped profile backups. Do not recursively chmod unrelated files.

- [ ] **Step 11: Run Task 2 verification**

```bash
bash tests/test_gpt_config.sh
bash tests/run.sh
bash -n install.sh
```

Expected: complete Bash suite passes; existing plugin tests remain green.

- [ ] **Step 12: Commit Task 2**

```bash
git add install.sh tests/test_gpt_config.sh
git commit -m "feat(installer): auto-configure CLIProxyAPI securely"
```

---

### Task 3: Fast-Fail Runtime Diagnostics

**Files:**
- Modify: `profiles/gpt.json:5-14`
- Modify: `claude.zsh:132-142,276-370`
- Create: `tests/test_gpt_runtime.zsh`
- Modify: `tests/test_gpt_config.sh` to invoke the Zsh suite

**Interfaces:**
- Produces metadata: `.service.configFile = "$HOME/.cli-proxy-api/config.yaml"`
- Produces: `_cl_check_service_config <profile-file> -> status 0|1`
- Produces: `_cl_log_has_auth_failure <log-file> -> status 0|1`
- Modifies: `_cl_start_service` to detect dead child before full health timeout

- [ ] **Step 1: Add failing metadata and missing-config tests**

In `tests/test_gpt_runtime.zsh`, use temporary profiles and stub service functions. Assert:

- Repository `profiles/gpt.json` declares `.service.configFile`.
- A missing/unreadable declared path returns within one second.
- Error contains the expanded exact path and repair instruction.
- Output omits `not authorized`, `codex-login`, and the 25-second timeout message.
- Profiles without `service.configFile` return success and preserve CCR behavior.

- [ ] **Step 2: Run runtime suite and confirm RED**

```bash
zsh tests/test_gpt_runtime.zsh
```

Expected: metadata/helper assertions fail.

- [ ] **Step 3: Add config metadata and generic prerequisite check**

Add to `profiles/gpt.json`:

```json
"configFile": "$HOME/.cli-proxy-api/config.yaml"
```

Implement `_cl_check_service_config` by reading `.service.configFile`, expanding only the literal leading `$HOME` or `~`, and checking `-r`. Do not use `eval`. Call it from `_cl_ensure_service` before locking or starting.

- [ ] **Step 4: Run missing-config tests and confirm GREEN**

Run `zsh tests/test_gpt_runtime.zsh`.

Expected: prerequisite tests pass.

- [ ] **Step 5: Add failing early-exit and auth-evidence tests**

Fixtures:

- Start command exits `1` immediately; function returns within three seconds and prints log tail.
- Log contains `401 Unauthorized`; login hint appears.
- Log contains `failed to read config file`; login hint does not appear.
- Log contains `connection refused`; login hint does not appear.

Use a timeout guard in the test process so a regression cannot sleep 25 seconds.

- [ ] **Step 6: Implement early process-exit detection**

After spawning and writing the PID, poll for at most two seconds. If the service becomes healthy, continue success. If `kill -0 "$pid"` fails while still unhealthy, enter the common failure-reporting path immediately. Preserve the existing full `_cl_wait_healthy` path for a still-running process.

- [ ] **Step 7: Implement evidence-based login hints**

`_cl_log_has_auth_failure` must match explicit authorization evidence, for example:

```text
401|403|unauthorized|forbidden|oauth|login required|no codex credentials|authentication required
```

Do not use broad `token`, `auth`, or `codex` substrings alone because normal startup lines may contain them. Print `loginHint` only when this predicate succeeds.

- [ ] **Step 8: Run runtime and full regression suites**

```bash
zsh -n claude.zsh
zsh tests/test_gpt_runtime.zsh
bash tests/test_gpt_config.sh
bash tests/run.sh
```

Expected: all pass; immediate-exit case finishes under three seconds.

- [ ] **Step 9: Commit Task 3**

```bash
git add profiles/gpt.json claude.zsh tests/test_gpt_runtime.zsh tests/test_gpt_config.sh
git commit -m "fix(gpt): fail fast on CLIProxyAPI startup errors"
```

---

### Task 4: Installer Guidance and Cross-Platform Boundary

**Files:**
- Modify: `install.sh:2126-2215`
- Modify: `install.ps1` in its final next-steps output
- Modify: `tests/test_gpt_config.sh`

**Interfaces:**
- Consumes: coordinator outcome and profile setup hints
- Produces: user guidance that config/key sync is complete while OAuth remains manual

- [ ] **Step 1: Add failing output tests**

Capture `backend_setup_hints` for a configured GPT fixture and assert it:

- Does not tell the user to invent or paste an API key.
- Does tell the user to run `cliproxyapi --codex-login`.
- Does not print the key.

Add a static PowerShell assertion that the final output states GPT auto-configuration and `cl_gpt` runtime are macOS/Linux-only, while `install.ps1` contains no call that writes `.cli-proxy-api/config.yaml`.

- [ ] **Step 2: Run tests and confirm RED**

Run `bash tests/test_gpt_config.sh`.

Expected: old placeholder/manual-key guidance or missing Windows limitation causes failure.

- [ ] **Step 3: Update Bash setup hints**

When the profile token is concrete, report configuration as completed and retain only binary installation, OAuth, and guide steps. When reconciliation failed, print the exact config/profile paths and rerun instruction without exposing values.

- [ ] **Step 4: Add the PowerShell limitation notice**

Add one informational line to final next steps:

```powershell
Write-Info "GPT backend auto-configuration and the cl_gpt launcher are macOS/Linux only (bash/zsh). Windows has no cl_gpt runtime yet — see docs/BACKENDS.md."
```

Do not add profile installation, config creation, RNG, or launcher code to `install.ps1`.

- [ ] **Step 5: Verify scripts and tests**

```bash
bash tests/test_gpt_config.sh
bash -n install.sh
pwsh -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw ./install.ps1)); "PASS"'
```

Expected: tests pass, Bash syntax exits 0, PowerShell parser prints `PASS`. If `pwsh` is unavailable, record it as skipped rather than claiming validation.

- [ ] **Step 6: Commit Task 4**

```bash
git add install.sh install.ps1 tests/test_gpt_config.sh
git commit -m "docs(installer): clarify GPT setup and Windows boundary"
```

---

### Task 5: Backend Documentation and Version Release Notes

**Files:**
- Modify: `docs/BACKENDS.md:105-186`
- Modify: `docs/BACKENDS.zh-CN.md:97-180`
- Modify: `CHANGELOG.md` before the `2.14.0` entry
- Modify: `VERSION:1`
- Modify: `tests/test_gpt_config.sh` for static documentation assertions if appropriate

**Interfaces:**
- Documents the exact behavior implemented by Tasks 1–4
- Produces release version `2.15.0`

- [ ] **Step 1: Add failing documentation assertions**

Assert both guides mention:

- Automatic reuse/generation and config-first precedence.
- Timestamped backup then normalization.
- Loopback `127.0.0.1`, port `8317`, and non-empty `api-keys`.
- Directory `700` and secret files `600`.
- Manual `cliproxyapi --codex-login` remains required.
- Windows limitation.

Assert `VERSION` equals `2.15.0` and changelog has `## [2.15.0] - 2026-08-02`.

- [ ] **Step 2: Run tests and confirm RED**

Run `bash tests/test_gpt_config.sh`.

Expected: documentation/version assertions fail.

- [ ] **Step 3: Rewrite the English GPT setup section**

Replace the manual key creation/paste flow with:

1. Select GPT in the installer.
2. Installer reuses config key, otherwise profile token, otherwise generates key.
3. Existing config is backed up and normalized.
4. Run OAuth manually.
5. Run `cl_gpt` or `cl_gpt_auto`.

Retain the warning that `api-keys` and `remote-management.secret-key` are different.

- [ ] **Step 4: Mirror the content in Chinese**

Keep commands, paths, precedence, permission numbers, and caveats exactly aligned with the English guide.

- [ ] **Step 5: Add the changelog entry and bump version**

Add:

```markdown
## [2.15.0] - 2026-08-02
### Features
- Automatically reuse or generate a CLIProxyAPI key, normalize its loopback-only config, and synchronize the GPT profile.
- Fail immediately on missing config or early proxy exit, and show OAuth guidance only for authorization failures.

### Design Rationale
- Treat CLIProxyAPI config as authoritative and back up existing YAML before normalization, preventing key drift and fail-open/LAN exposure.

### Notes & Caveats
- OAuth remains manual through `cliproxyapi --codex-login`.
- GPT auto-configuration and `cl_gpt` remain Bash/Zsh-only; PowerShell reports this limitation.
```

Set `VERSION` to `2.15.0`.

- [ ] **Step 6: Run documentation and full tests**

```bash
bash tests/test_gpt_config.sh
bash tests/run.sh
rg -n 'YOUR_CLIPROXYAPI_KEY|pick-any-long-random-string' docs/BACKENDS.md docs/BACKENDS.zh-CN.md
```

Expected: tests pass; `rg` finds no remaining instruction that asks users to manually invent/paste the key. References explaining old placeholders are acceptable only if clearly historical.

- [ ] **Step 7: Commit Task 5**

```bash
git add docs/BACKENDS.md docs/BACKENDS.zh-CN.md CHANGELOG.md VERSION tests/test_gpt_config.sh
git commit -m "docs(gpt): document automatic proxy configuration"
```

---

### Task 6: Final Verification and Adversarial Review

**Files:**
- Review all files modified in Tasks 1–5
- No new production files expected

**Interfaces:**
- Consumes: complete implementation
- Produces: verified release candidate with review findings resolved

- [ ] **Step 1: Run syntax and full test suites**

```bash
bash -n install.sh
zsh -n claude.zsh
bash tests/run.sh
zsh tests/test_gpt_runtime.zsh
```

Expected: every command exits 0.

- [ ] **Step 2: Run isolated end-to-end installer verification**

Use a temporary HOME and a repository copy or installer test mode that cannot affect the real home directory. Verify fresh install, repeated install, conflict normalization, backup contents, exact permissions, and no secret in captured stdout/stderr. Do not run OAuth or start CLIProxyAPI.

- [ ] **Step 3: Verify the dry run**

```bash
./install.sh --all --dry-run
```

Expected: no key is generated or displayed; no `.cli-proxy-api` path is created under the isolated HOME.

- [ ] **Step 4: Check diffs and secret exposure**

```bash
git diff --check
git diff --stat
rg -n 'api-keys:|ANTHROPIC_AUTH_TOKEN' tests docs profiles install.sh claude.zsh
```

Inspect every match to ensure only placeholders/synthetic fixtures appear in tracked files and no generated key was committed.

- [ ] **Step 5: Invoke the required adversarial review**

Run the `adversarial-review` skill over the complete diff with lenses for Bash correctness, secret handling, atomic rollback, YAML edge cases, and runtime timeout behavior. Fix every confirmed CRITICAL/HIGH issue and MEDIUM issues where practical.

- [ ] **Step 6: Re-run verification after fixes**

Repeat Step 1 and the affected isolated scenarios. Report skipped checks explicitly.

- [ ] **Step 7: Commit review fixes if needed**

```bash
git add install.sh install.ps1 claude.zsh profiles/gpt.json tests docs CHANGELOG.md VERSION
git commit -m "fix(gpt): address auto-configuration review findings"
```

Skip this commit when review produces no code changes.

## Completion Criteria

- Fresh GPT selection creates matching non-empty keys in normalized config and profile without printing the key.
- Existing config key wins, is backed up before normalization, and survives reruns without rotation.
- Permission, backup, parse, and write failures preserve prior files and mark installation critical.
- Missing config fails in under one second; early process exit fails within three seconds.
- OAuth hint appears only for explicit authorization evidence.
- Bash/Zsh tests and existing regression suite pass.
- English/Chinese docs, changelog, Windows limitation, and version are consistent.

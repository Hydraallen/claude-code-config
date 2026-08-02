# Remove Redundant Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Work directly in the current `main` checkout as requested. Do not create a branch or worktree, do not push, and do not make intermediate commits. After implementation and main-session verification, invoke `adversarial-review`, fix confirmed findings, rerun all verification, and create one final conventional commit.

**Goal:** Remove the Matt Pocock 17-Skill bundle, the `frontend-design` plugin, and the vendored `harness-workflow` Skill from the repository’s active product surface while safely cleaning up only installer-owned legacy copies.

**Architecture:** Delete all active catalogue, selection, installation, default, and documentation paths for the three retired components. Preserve narrowly scoped tombstones: Matt cleanup trusts only safe leaf-directory entries recorded in the legacy ownership manifest; `frontend-design` remains only in exact retired/removed plugin tombstones; `harness-workflow` cleanup deletes an installed copy only when its `SKILL.md` has the byte-exact digest of the former repository-managed source. Bash and PowerShell must expose equivalent cleanup behavior and retain `superpowers@claude-plugins-official` and `ecc@ecc` under their current selection policies.

**Tech Stack:** Bash 3.2+, PowerShell 5+/PowerShell Core, plain-Bash test harness, `jq` where already required by installer settings reconciliation, SHA-256 (`shasum -a 256` / `sha256sum` / `Get-FileHash`), Markdown documentation.

## Global Constraints

- Remove the Matt Pocock state, fixed 17-Skill list, menu item, selection handling, network installer, manifest creation, default/all behavior, tests, and reader-facing documentation.
- Remove `frontend-design` from plugin catalogues, menu mappings, default settings, tests, and reader-facing documentation.
- Delete `skills/harness-workflow/` and remove its Bash and PowerShell menu and selection handling.
- Retain `superpowers@claude-plugins-official`.
- Retain `ecc@ecc`.
- The retired Matt cleanup may read `~/.claude/.mattpocock-skills`, remove only safe skill directories explicitly recorded there, and then remove the manifest.
- Do not retain or reconstruct the former 17-name Matt installation array.
- Never delete a Matt-related Skill merely because its name is familiar.
- Keep the exact former plugin ID `frontend-design@claude-plugins-official` only in retired-plugin and removed-plugin tombstones, cleanup tests, and the approved design/implementation records.
- Re-running either installer must remove `frontend-design@claude-plugins-official` from installed plugin state and from `enabledPlugins`.
- Delete the vendored `skills/harness-workflow/` source.
- The former managed `harness-workflow/SKILL.md` SHA-256 digest is exactly `d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba`.
- Delete an installed `harness-workflow` copy only when its `SKILL.md` digest exactly matches that former managed digest.
- Preserve a same-named user-authored or modified `harness-workflow` Skill and emit a warning.
- Cleanup must run during a normal installer re-run as well as full uninstall.
- Dry-run must report intended cleanup without changing files, plugin state, settings, or manifests.
- Bash and PowerShell catalogue resolution, non-interactive defaults, `--all` / `-All` behavior, menu counts, selected summaries, and cleanup behavior must remain aligned.
- Reader-facing documentation must not advertise or recommend retired components.
- Legacy names may remain only in isolated cleanup tombstones, tests proving cleanup safety, the approved design, and this implementation plan.
- Rewrite unrelated architectural examples that currently name retired installer functions into generic descriptions.
- Preserve historical changelog chronology, but rewrite entries so retired components are not presented as current capabilities.
- Do not bump `VERSION`; this cleanup is added to the existing `2.17.0` release entry dated `2026-08-02`.
- Do not change unrelated image-generation, CLIProxyAPI, launcher, MCP, rule, agent, or plugin behavior.
- Work directly on `main`; do not create a branch or worktree.
- Do not make task-level commits. Create one final conventional commit only after verification and adversarial review.

---

## File Map

### Installer implementation

- Modify `install.sh`
  - Remove Matt state, fixed array, menu item, dispatch, npx installer, manifest creation, defaults, and execution.
  - Remove active `frontend-design` catalogue and menu mappings.
  - Add its exact ID to retired and removed plugin tombstones.
  - Remove active `harness-workflow` menu and dispatch.
  - Add normal-install and uninstall cleanup coordinators for the legacy Matt manifest and former managed harness copy.
  - Remove obsolete handoff/teach migration commentary tied to Matt replacement.
- Modify `install.ps1`
  - Implement exact behavioral parity with `install.sh`.
- Modify `settings.json`
  - Remove the default `frontend-design@claude-plugins-official` entry.
- Delete `skills/harness-workflow/SKILL.md`
  - Remove the vendored retired Skill source.

### Tests

- Create `tests/test_redundant_skill_cleanup.sh`
  - Exercise Bash legacy ownership cleanup, digest safety, dry-run behavior, plugin tombstones, settings cleanup, current defaults, and PowerShell parity.
- Modify `tests/test_plugin_resolution.sh`
  - Remove `frontend-design` from the real-world installed fixture and add explicit retained-policy assertions for Superpowers and ECC.
- Modify `tests/test_image_gen_install.sh`
  - Remove stale Matt installer function/state scaffolding while preserving image-gen coverage.
- Modify `tests/run.sh` only if the new `tests/test_redundant_skill_cleanup.sh` is not automatically discovered.
  - The current `tests/test_*.sh` glob should discover it without modification.

### Reader-facing documentation and historical records

- Modify `README.md`
- Modify `README.zh-CN.md`
- Modify `plugins/README.md`
- Modify `CHANGELOG.md`
- Modify `CHANGELOG.zh-CN.md`
- Modify `docs/superpowers/plans/2026-08-02-image-gen-cliproxyapi-integration.md`
- Modify `docs/superpowers/specs/2026-08-02-image-gen-cliproxyapi-integration-design.md`
- Retain `docs/superpowers/specs/2026-08-02-remove-redundant-skills-design.md` as the approved design record.
- Retain this plan, `docs/superpowers/plans/2026-08-02-remove-redundant-skills.md`, as the implementation record.

## Shared Interfaces

### Bash cleanup interfaces

```bash
readonly RETIRED_HARNESS_WORKFLOW_SHA256="d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba"

is_safe_retired_skill_name <name>
# Return 0 only for one non-empty leaf component:
#   [A-Za-z0-9][A-Za-z0-9._-]*
# Return non-zero for ".", "..", slashes, backslashes, whitespace,
# control characters, empty strings, and absolute/relative paths.

sha256_file <path>
# Print one lowercase SHA-256 digest.
# Prefer `shasum -a 256`; fall back to `sha256sum`.
# Return non-zero without printing file contents when neither is available.

cleanup_retired_mattpocock_skills
# Read $CLAUDE_DIR/.mattpocock-skills if present.
# For every safe, non-empty manifest line, remove only:
#   $CLAUDE_DIR/skills/<exact-line>
# Unsafe lines are skipped with a warning and never interpolated into rm.
# Remove the manifest after processing.
# In DRY_RUN, report safe removals and manifest removal without writing.

cleanup_retired_harness_workflow
# Inspect $CLAUDE_DIR/skills/harness-workflow/SKILL.md.
# Remove the harness-workflow directory only when the digest exactly equals
# RETIRED_HARNESS_WORKFLOW_SHA256.
# Preserve and warn on a different digest, a missing SKILL.md, or unavailable
# digest tooling.
# In DRY_RUN, report only what would be deleted.

cleanup_retired_skills
# Call both cleanup functions once during normal installation and once from
# uninstall, without duplicating deletion logic.
```

### PowerShell cleanup interfaces

```powershell
$RETIRED_HARNESS_WORKFLOW_SHA256 =
    "d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba"

function Test-SafeRetiredSkillName {
    param([string]$Name)
    # Return [bool] with the same accepted language as Bash.
}

function Remove-RetiredMattpocockSkills {
    # Same manifest, safe-leaf, deletion, warning, and DryRun contract as Bash.
}

function Remove-RetiredHarnessWorkflow {
    # Use Get-FileHash -Algorithm SHA256 and the same exact digest contract.
}

function Remove-RetiredSkills {
    # Invoke both retired-skill cleanup paths.
}
```

### Plugin tombstones

Both installers must retain these exact concepts:

```text
RETIRED_PLUGINS:
  frontend-design@claude-plugins-official

PLUGINS_REMOVED:
  frontend-design@claude-plugins-official
```

`RETIRED_PLUGINS` authorizes uninstalling a previously installed plugin. `PLUGINS_REMOVED` authorizes stripping the exact key from merged `enabledPlugins`. Neither array makes the plugin installable or part of the current catalogue.

---

### Task 1: Add Failing Legacy Cleanup Tests

**Files:**
- Create: `tests/test_redundant_skill_cleanup.sh`
- Read for test conventions: `tests/test_plugin_resolution.sh`
- Read for installer-isolation conventions: `tests/test_image_gen_install.sh`
- Test target: `install.sh`

**Interfaces:**
- Consumes: current sourceable `install.sh`, `CLAUDE_DIR`, `DRY_RUN`, `info`, `warn`.
- Produces: executable specification for `is_safe_retired_skill_name`, `sha256_file`, `cleanup_retired_mattpocock_skills`, `cleanup_retired_harness_workflow`, and `cleanup_retired_skills`.

- [ ] **Step 1: Create the plain-Bash test harness and assertions**

Start the file with the repository’s normal source-and-relax pattern:

```bash
#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$DIR/install.sh"
set +euo pipefail

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

assert_exists() {
    local desc="$1" path="$2"
    if [[ -e "$path" ]]; then pass "$desc"; else fail "$desc"; fi
}

assert_not_exists() {
    local desc="$1" path="$2"
    if [[ ! -e "$path" ]]; then pass "$desc"; else fail "$desc"; fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s\n' "$haystack" | grep -Fq "$needle"; then
        pass "$desc"
    else
        fail "$desc"
        printf '  missing: %s\n' "$needle"
    fi
}
```

End the file with:

```bash
echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Add a failing Matt manifest ownership test**

Use a subshell and isolated temporary home:

```bash
test_matt_manifest_removes_only_recorded_safe_entries() {
(
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    HOME="$tmp"
    CLAUDE_DIR="$HOME/.claude"
    DRY_RUN=false

    mkdir -p \
        "$CLAUDE_DIR/skills/recorded-skill" \
        "$CLAUDE_DIR/skills/unrecorded-skill" \
        "$CLAUDE_DIR/skills/tdd"

    printf 'recorded-skill\n' > "$CLAUDE_DIR/.mattpocock-skills"

    cleanup_retired_mattpocock_skills

    [[ ! -e "$CLAUDE_DIR/skills/recorded-skill" ]] &&
    [[ -e "$CLAUDE_DIR/skills/unrecorded-skill" ]] &&
    [[ -e "$CLAUDE_DIR/skills/tdd" ]] &&
    [[ ! -e "$CLAUDE_DIR/.mattpocock-skills" ]]
)
}
```

Assert that a manifest-owned directory is removed, an unrecorded arbitrary directory is preserved, an unrecorded familiar name such as `tdd` is preserved, and the manifest is removed.

- [ ] **Step 3: Add failing Matt manifest path-safety cases**

Create a sentinel outside `skills/` and a manifest containing:

```text
../outside-sentinel
/absolute/path
nested/name
nested\name
.
..
safe-owned-skill
```

Assert:

- `safe-owned-skill` is removed.
- The sentinel outside `skills/` remains.
- No nested or absolute target is touched.
- Unsafe entries emit a warning containing `unsafe retired skill manifest entry`.
- The manifest is removed after processing.

Also add a no-manifest case proving same-named user Skills are untouched.

- [ ] **Step 4: Add a failing Matt dry-run test**

With a valid manifest and owned directory, set `DRY_RUN=true`, capture output from `cleanup_retired_mattpocock_skills`, and assert:

- The directory still exists.
- The manifest still exists.
- Output contains both `Would remove retired manifest-owned skill:` and `Would remove retired skill manifest:`.

- [ ] **Step 5: Add failing harness digest tests**

Use the former managed bytes from Git rather than copying a stale fixture into the repository:

```bash
git -C "$DIR" show \
    385532d^:skills/harness-workflow/SKILL.md \
    > "$CLAUDE_DIR/skills/harness-workflow/SKILL.md"
```

If the implementation commit ancestry no longer makes `385532d^` available, use the last commit that contains `skills/harness-workflow/SKILL.md`; before continuing, verify:

```bash
shasum -a 256 "$CLAUDE_DIR/skills/harness-workflow/SKILL.md"
```

Expected digest:

```text
d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba
```

Test these cases independently:

1. Exact former bytes: directory is removed.
2. Exact former bytes with one appended newline/comment: directory is preserved and warning contains `modified or user-authored`.
3. Same-named directory with no `SKILL.md`: directory is preserved and warning contains `cannot verify ownership`.
4. Dry-run with exact bytes: directory remains and output contains `Would remove retired managed skill: harness-workflow`.

Do not add the former 9 KB `SKILL.md` as a tracked test fixture.

- [ ] **Step 6: Run the focused test to verify RED**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
```

Expected: FAIL because the cleanup functions and digest constant do not yet exist.

---

### Task 2: Implement Ownership-Safe Bash Retired-Skill Cleanup

**Files:**
- Modify: `install.sh` state/constants section, install helpers, normal-install orchestration, and `uninstall()`
- Test: `tests/test_redundant_skill_cleanup.sh`

**Interfaces:**
- Consumes: exact contracts in “Shared Interfaces.”
- Produces: Bash retired cleanup callable from both normal installation and uninstall.

- [ ] **Step 1: Remove active Matt state and fixed installation inventory**

Delete:

```bash
INSTALL_MATTPOCOCK=false
MATTPOCOCK_SKILLS=(...)
```

Also delete every assignment or read of `INSTALL_MATTPOCOCK`.

Run:

```bash
git grep -n -E 'INSTALL_MATTPOCOCK|MATTPOCOCK_SKILLS' -- install.sh
```

Expected: no output.

- [ ] **Step 2: Remove the Matt network installer**

Delete the complete active installation surface:

```bash
_mattpocock_npx_cmd
_mattpocock_npx
install_mattpocock_skills
```

Delete its successful-install manifest-writing path. Do not delete the legacy manifest cleanup being introduced.

Run:

```bash
git grep -n -E '_mattpocock_npx|install_mattpocock_skills' -- install.sh
```

Expected: no output.

- [ ] **Step 3: Implement safe manifest-entry validation**

Add:

```bash
is_safe_retired_skill_name() {
    local name="${1-}"
    [[ -n "$name" ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}
```

Do not broaden this to slash-containing paths.

- [ ] **Step 4: Implement portable SHA-256 calculation**

Add:

```bash
sha256_file() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | cut -d ' ' -f 1 | tr '[:upper:]' '[:lower:]'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | cut -d ' ' -f 1 | tr '[:upper:]' '[:lower:]'
    else
        return 1
    fi
}
```

Keep the digest as a scalar tombstone, not a copy of former source:

```bash
RETIRED_HARNESS_WORKFLOW_SHA256="d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba"
```

- [ ] **Step 5: Implement Matt manifest cleanup**

Implement `cleanup_retired_mattpocock_skills` with these exact decisions:

```bash
cleanup_retired_mattpocock_skills() {
    local manifest="$CLAUDE_DIR/.mattpocock-skills"
    [[ -f "$manifest" ]] || return 0

    local skill_name skill_path
    while IFS= read -r skill_name || [[ -n "$skill_name" ]]; do
        [[ -n "$skill_name" ]] || continue

        if ! is_safe_retired_skill_name "$skill_name"; then
            warn "Skipping unsafe retired skill manifest entry"
            continue
        fi

        skill_path="$CLAUDE_DIR/skills/$skill_name"
        [[ -d "$skill_path" ]] || continue

        if $DRY_RUN; then
            info "Would remove retired manifest-owned skill: $skill_name"
        else
            rm -rf -- "$skill_path"
            ok "Removed retired manifest-owned skill: $skill_name"
        fi
    done < "$manifest"

    if $DRY_RUN; then
        info "Would remove retired skill manifest: $manifest"
    else
        rm -f -- "$manifest"
        ok "Removed retired skill manifest"
    fi
}
```

Do not log unsafe entry contents; an entry may contain control characters.

- [ ] **Step 6: Implement exact-digest harness cleanup**

Implement `cleanup_retired_harness_workflow` so that:

- It returns silently if `skills/harness-workflow/` is absent.
- It preserves and warns if `SKILL.md` is absent.
- It preserves and warns if SHA-256 tooling is unavailable or hashing fails.
- It removes the directory only on exact digest equality.
- It preserves and warns on any mismatch.
- It never prints file contents.

- [ ] **Step 7: Add the shared cleanup coordinator**

Implement:

```bash
cleanup_retired_skills() {
    cleanup_retired_mattpocock_skills
    cleanup_retired_harness_workflow
}
```

Call it once during a normal re-run after `$CLAUDE_DIR` can safely exist and before `install_skills`, so retired directories do not survive merely because the user did not select the Skills group.

In dry-run, the function must remain read-only.

- [ ] **Step 8: Replace duplicate uninstall cleanup**

Inside `uninstall()`:

- Delete the old inline `.mattpocock-skills` loop.
- Call `cleanup_retired_skills` instead.
- Ensure this call occurs before generic cleanup can remove or obscure the relevant ownership evidence.
- Keep normal uninstall confirmation and dry-run semantics unchanged.

- [ ] **Step 9: Remove obsolete handoff/teach migration commentary**

Replace comments that say handoff/teach are intentionally preserved for Matt overwrite with a generic statement that only explicitly provenance-backed retired content is deleted. Do not add name-based deletion for handoff or teach.

- [ ] **Step 10: Run focused tests and syntax validation**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
bash -n install.sh
```

Expected:

```text
all cleanup tests pass
bash -n exits 0 with no output
```

---

### Task 3: Remove Active Bash Catalogue and Selection Paths

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_redundant_skill_cleanup.sh`
- Test: `tests/test_plugin_resolution.sh`

**Interfaces:**
- Consumes: current menu arrays, `_plug_id_to_pkg`, `PLUGINS_ESSENTIAL`, `PLUGINS_OPTIONAL`, `RETIRED_PLUGINS`, `PLUGINS_REMOVED`.
- Produces: a current catalogue without the three retired choices and exact tombstones for former frontend plugin cleanup.

- [ ] **Step 1: Add static failing assertions before editing the catalogue**

In `tests/test_redundant_skill_cleanup.sh`, inspect only the active Bash regions or source the relevant arrays/functions. Assert:

- `build_plugin_catalogue` does not emit `frontend-design@claude-plugins-official`.
- `PLUGINS_ESSENTIAL` does not contain it.
- `PLUGINS_OPTIONAL` does not contain it.
- `RETIRED_PLUGINS` contains it exactly once.
- `PLUGINS_REMOVED` contains it exactly once.
- `PLUGINS_ESSENTIAL` or `PLUGINS_OPTIONAL` still exposes both:
  - `superpowers@claude-plugins-official`
  - `ecc@ecc`
- Active menu data contains no retired component labels or IDs.

Use array membership helpers instead of substring matching where possible.

- [ ] **Step 2: Verify these assertions fail**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
```

Expected: FAIL because the active menu and catalogue still contain retired entries and the frontend tombstones are incomplete.

- [ ] **Step 3: Remove the three active menu entries**

From the Workflow group, delete the Matt and harness rows. From Design & Content, delete the frontend row.

Recalculate the group totals through the existing derived menu logic; do not hard-code replacement totals in installer code.

- [ ] **Step 4: Remove retired selection dispatch**

Delete:

```bash
skill-harness-workflow) ...
skill-mattpocock) ...
```

Delete:

```bash
plug-frontend-design) echo "frontend-design@claude-plugins-official" ;;
```

Do not leave dead compatibility aliases in `_plug_id_to_pkg`.

- [ ] **Step 5: Remove active frontend catalogue membership**

Delete `frontend-design@claude-plugins-official` from `PLUGINS_ESSENTIAL` and any other active group.

Add the exact ID once to each tombstone list:

```bash
RETIRED_PLUGINS+=(
    "frontend-design@claude-plugins-official"
)

PLUGINS_REMOVED+=(
    "frontend-design@claude-plugins-official"
)
```

Follow the existing array literal style rather than using runtime `+=` if surrounding code uses one declaration.

- [ ] **Step 6: Remove Matt defaults and execution**

Delete:

- `INSTALL_MATTPOCOCK=true` in implicit/default and explicit-all paths.
- Comments describing Matt as default.
- The main call to `install_mattpocock_skills`.

- [ ] **Step 7: Keep Superpowers and ECC policies unchanged**

Do not move either retained plugin between tiers. Add test assertions for their exact current tier so a cleanup patch cannot accidentally change policy.

At the current `e085cb7` baseline, expected source membership is:

```text
superpowers@claude-plugins-official: PLUGINS_ESSENTIAL
ecc@ecc: PLUGINS_OPTIONAL, plus an explicitly default-on interactive menu item
```

Preserve these exact policies. Do not move either plugin between groups, and do not change ECC's interactive default-on menu selection.

- [ ] **Step 8: Run focused catalogue tests**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
bash tests/test_plugin_resolution.sh
bash -n install.sh
```

Expected: all pass.

---

### Task 4: Verify Bash Frontend Plugin Upgrade Cleanup

**Files:**
- Modify: `tests/test_redundant_skill_cleanup.sh`
- Modify only if required by RED test: `install.sh`

**Interfaces:**
- Consumes: `RETIRED_PLUGINS`, `PLUGINS_REMOVED`, `prune_retired_plugins`, `install_settings`.
- Produces: proof that a normal installer rerun removes former installed and enabled plugin state without making the plugin selectable.

- [ ] **Step 1: Add a failing retired installed-plugin test**

Create an isolated fixture:

```json
{
  "plugins": {
    "frontend-design@claude-plugins-official": {},
    "superpowers@claude-plugins-official": {},
    "user-plugin@example": {}
  }
}
```

Stub `claude` to record invocations. Run the retired-plugin cleanup and assert:

```text
claude plugin uninstall frontend-design@claude-plugins-official
```

is called exactly once, while no uninstall is issued for Superpowers or the user plugin.

In dry-run, assert no stubbed mutation occurs and output contains the exact retired ID.

- [ ] **Step 2: Add a failing enabledPlugins merge test**

Use an existing settings file containing:

```json
{
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "superpowers@claude-plugins-official": true,
    "user-plugin@example": true
  }
}
```

Run the same settings reconciliation path a normal installer run uses. Assert:

- `frontend-design@claude-plugins-official` is absent.
- `superpowers@claude-plugins-official` remains according to selection.
- `user-plugin@example` is preserved.
- JSON remains valid.

- [ ] **Step 3: Run tests to determine whether tombstones are sufficient**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
```

Expected after Task 3: preferably PASS through existing retired and removed plugin machinery.

If the enabled key survives because settings reconciliation is bypassed in the exercised normal path, minimally extend the existing retired-plugin/settings cleanup rather than creating a second competing catalogue.

- [ ] **Step 4: Preserve no-jq behavior**

Do not overwrite settings with regex or `sed`. If `jq` is unavailable, preserve the file and emit the existing settings reconciliation warning. Tests must not claim successful JSON mutation without a JSON parser.

- [ ] **Step 5: Rerun focused tests**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
bash tests/test_plugin_resolution.sh
```

Expected: all pass; no retained plugin is pruned.

---

### Task 5: Implement Equivalent PowerShell Removal and Cleanup

**Files:**
- Modify: `install.ps1`
- Modify: `tests/test_redundant_skill_cleanup.sh`

**Interfaces:**
- Consumes: PowerShell menu result object, plugin groups, `Remove-RetiredPlugins`, settings merge, `Invoke-Uninstall`.
- Produces: `Test-SafeRetiredSkillName`, `Remove-RetiredMattpocockSkills`, `Remove-RetiredHarnessWorkflow`, and `Remove-RetiredSkills`, with Bash-equivalent behavior.

- [ ] **Step 1: Add static PowerShell parity assertions**

In the shell test, read `install.ps1` and assert the absence of active symbols and IDs:

```text
$MATTPOCOCK_SKILLS
Install-MattpocockSkills
doMattpocock
skill-mattpocock
skill-harness-workflow
plug-frontend-design
```

Assert the exact digest exists once.

Assert the exact frontend plugin ID exists only in retired/removed declarations or cleanup code, not in active plugin arrays or menu rows.

- [ ] **Step 2: Add optional PowerShell behavioral tests**

If `pwsh` exists, invoke the installer definitions in an isolated `USERPROFILE` and test:

1. Safe manifest-owned directory removed.
2. Unrecorded same-named directory preserved.
3. `../` manifest entry cannot escape `skills`.
4. Manifest removed after processing.
5. Exact harness digest removed.
6. Modified harness content preserved with warning.
7. `-DryRun` changes nothing.
8. Former frontend plugin ID is absent from active catalogue.
9. Superpowers and ECC retain existing policies.

If `pwsh` is absent, print one explicit `SKIP:` line and let the shell suite pass.

- [ ] **Step 3: Run the new test to verify RED**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
```

Expected: FAIL on PowerShell static assertions until the active paths are removed.

- [ ] **Step 4: Remove active Matt PowerShell state and installation**

Delete:

- `$MATTPOCOCK_SKILLS`.
- `Mattpocock` from menu result state.
- Matt menu row.
- Matt selection dispatch.
- `Install-MattpocockSkills`.
- `$doMattpocock`.
- All default/fallback/`-All` assignments.
- The call to `Install-MattpocockSkills`.
- Successful-install manifest creation.

Retain only legacy manifest cleanup.

- [ ] **Step 5: Remove active harness and frontend paths**

Delete:

- Harness menu row and selection dispatch.
- Frontend active plugin array membership.
- Frontend menu row.
- Frontend plug-ID mapping.

Add `frontend-design@claude-plugins-official` once to each corresponding PowerShell retired/removed tombstone.

- [ ] **Step 6: Implement PowerShell safe manifest cleanup**

Use the exact regular expression:

```powershell
'^[A-Za-z0-9][A-Za-z0-9._-]*$'
```

Also explicitly reject `"."` and `".."`.

Build deletion targets only with:

```powershell
Join-Path (Join-Path $CLAUDE_DIR "skills") $skillName
```

Never call `Remove-Item` with a raw manifest line.

- [ ] **Step 7: Implement PowerShell harness digest cleanup**

Use:

```powershell
(Get-FileHash -Algorithm SHA256 -LiteralPath $skillFile).Hash.ToLowerInvariant()
```

Delete only on exact equality with:

```text
d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba
```

Use `-LiteralPath` for all checks and deletion. Preserve and warn on mismatch or hashing failure.

- [ ] **Step 8: Call the coordinator in both execution paths**

Call `Remove-RetiredSkills`:

- During normal installation before `Install-Skills`.
- From `Invoke-Uninstall` instead of any duplicate inline Matt cleanup.

Respect `$DryRun` in both locations.

- [ ] **Step 9: Preserve plugin/settings behavior**

Verify `Remove-RetiredPlugins` uninstalls the exact frontend ID when installed and PowerShell settings reconciliation strips the exact ID via `$PLUGINS_REMOVED`.

Do not alter Superpowers or ECC tier membership.

- [ ] **Step 10: Validate parser and parity**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
```

When PowerShell is available, also run:

```bash
pwsh -NoLogo -NoProfile -Command \
  '$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "./install.ps1"), [ref]$null, [ref]$errors); if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }'
```

Expected: test suite PASS; parser exits 0.

---

### Task 6: Delete Vendored Source and Repair Existing Test Fixtures

**Files:**
- Delete: `skills/harness-workflow/SKILL.md`
- Modify: `tests/test_plugin_resolution.sh`
- Modify: `tests/test_image_gen_install.sh`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: current test runner’s automatic `tests/test_*.sh` discovery.
- Produces: no active vendored harness source and no tests expecting removed installation state.

- [ ] **Step 1: Delete the vendored harness source**

Run:

```bash
git rm skills/harness-workflow/SKILL.md
```

Expected:

```text
rm 'skills/harness-workflow/SKILL.md'
```

Confirm the now-empty directory is absent from Git:

```bash
git ls-files 'skills/harness-workflow/**'
```

Expected: no output.

- [ ] **Step 2: Update the real-world plugin resolution fixture**

In `tests/test_plugin_resolution.sh`:

- Remove `frontend-design@claude-plugins-official` from `INSTALLED_PLUGINS`.
- Keep Superpowers and ECC fixture entries.
- Preserve the existing assertion that ECC is pruned when it is optional, installed, and not selected.
- Add an assertion that Superpowers is not pruned when selected under its existing policy.
- Do not weaken the third-party plugin preservation assertion.

- [ ] **Step 3: Remove stale image-gen Matt scaffolding**

In `tests/test_image_gen_install.sh`:

- Remove `install_mattpocock_skills` from any stubbed function list.
- Remove `INSTALL_MATTPOCOCK=false` setup.
- Do not change image-gen command, wrapper, ownership, augmentation, or uninstall expectations.
- If a call-order expectation included Matt, remove only that element and retain the relative ordering of all remaining operations.

- [ ] **Step 4: Confirm the new test is auto-discovered**

Run:

```bash
bash tests/run.sh
```

Expected: output contains:

```text
=== Running test_redundant_skill_cleanup.sh ===
```

Do not modify `tests/run.sh` if this occurs.

- [ ] **Step 5: Run all focused suites**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
bash tests/test_plugin_resolution.sh
bash tests/test_image_gen_install.sh
```

Expected: all pass.

---

### Task 7: Remove Active Reader-Facing References and Recalculate Counts

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `plugins/README.md`
- Modify: `settings.json`

**Interfaces:**
- Consumes: final installer menu and catalogue after Tasks 3 and 5.
- Produces: bilingual current-product documentation matching actual menu groups and defaults.

- [ ] **Step 1: Remove the frontend default setting**

Delete exactly:

```json
"frontend-design@claude-plugins-official": true
```

Repair any trailing comma and validate:

```bash
jq empty settings.json
```

Expected: exit 0 with no output.

- [ ] **Step 2: Update the English README product summary**

Remove the Matt collection from the opening product summary. Keep the always-installed `image-gen` description intact.

Recalculate:

- Curated plugin count.
- Marketplace count only if the removed plugin was the final user of its marketplace.
- Bundled Skill count after deleting harness.
- Workflow menu selected/total count.
- Design & Content selected/total count.

Derive counts from the post-change installer and tracked files; do not decrement prose blindly.

Useful commands:

```bash
find skills -mindepth 1 -maxdepth 1 -type d | sort
git grep -n 'GROUP_ITEMS+=' -- install.sh
```

Expected current-product rows do not mention any retired component.

- [ ] **Step 3: Remove English README catalogue rows**

Delete the Matt Skill row and frontend plugin row. Do not replace them with promotional alternatives.

Ensure Superpowers and ECC remain documented according to current defaults.

- [ ] **Step 4: Mirror all changes in Chinese**

Make the same structural edits to `README.zh-CN.md`:

- Same counts.
- Same rows.
- Same defaults.
- Same group totals.
- Same retained Superpowers/ECC policy.
- Natural Chinese wording without adding claims absent from English.

- [ ] **Step 5: Update the plugin catalogue README**

Delete the `frontend-design` row from `plugins/README.md`.

Keep table formatting valid.

- [ ] **Step 6: Run bilingual sync checks**

Run:

```bash
bash scripts/check-readme-sync.sh
```

Expected: PASS with English and Chinese structure/count checks aligned.

- [ ] **Step 7: Run active documentation searches**

Run:

```bash
git grep -n -i -E 'mattpocock|matt pocock|frontend-design|harness-workflow' -- \
  README.md README.zh-CN.md plugins/README.md settings.json
```

Expected: no output.

---

### Task 8: Rewrite Historical and Architectural Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-CN.md`
- Modify: `docs/superpowers/plans/2026-08-02-image-gen-cliproxyapi-integration.md`
- Modify: `docs/superpowers/specs/2026-08-02-image-gen-cliproxyapi-integration-design.md`
- Do not modify unless correcting an implementation-discovered contradiction: `docs/superpowers/specs/2026-08-02-remove-redundant-skills-design.md`

**Interfaces:**
- Consumes: approved removal design and existing `2.17.0` release entries.
- Produces: accurate history without advertising retired components as current features.

- [ ] **Step 1: Replace the image-gen implementation example**

In the image-gen implementation plan, replace the reference to installing “next to” the retired Matt installer with a generic description such as:

```text
Implement bounded network installation alongside the existing network-Skill helper patterns, with warning accounting.
```

The sentence must remain actionable without naming a removed function.

- [ ] **Step 2: Replace the image-gen design example**

Rewrite the design sentence that says image-gen uses the same architecture as the retired installer. Describe the architecture directly:

```text
The installer invokes the `skills` CLI through an argument-array helper, detached stdin, bounded retry, telemetry suppression, and warning accounting.
```

Do not alter the approved image-gen behavior.

- [ ] **Step 3: Add the cleanup to the existing 2.17.0 changelog entry**

Under `## [2.17.0] - 2026-08-02`, add matching English and Chinese bullets covering:

- Removed active Matt bundle integration.
- Removed active frontend plugin integration.
- Removed vendored harness Skill.
- Preserved legacy Matt manifest cleanup.
- Exact frontend retired/removed tombstones.
- Exact-digest harness cleanup.
- User-authored or modified same-named harness preservation.
- Bash/PowerShell parity.
- No version bump beyond `2.17.0`.

- [ ] **Step 4: Rewrite older promotional Matt entries**

For old releases that currently promote the Matt bundle or handoff/teach as active capabilities, retain chronology but convert the content into neutral historical wording. Each rewritten section must make clear that the integration described there was later retired in `2.17.0`.

Remove implementation detail that would encourage current use, including the former 17-name installation surface, default recommendation, and current install commands.

- [ ] **Step 5: Rewrite older frontend catalogue entries**

Where old changelog inventories list frontend as part of the current essential/design catalogue:

- Preserve that it belonged to that historical release only.
- Add or use wording making clear it was retired in `2.17.0`.
- Do not leave a standalone current recommendation.

- [ ] **Step 6: Keep English and Chinese changelog structure aligned**

The two 2.17.0 cleanup entries must convey the same behavior and limitations. Do not backfill unrelated missing Chinese releases.

- [ ] **Step 7: Verify document-only occurrences**

Run:

```bash
git grep -n -i -E 'mattpocock|matt pocock|frontend-design|harness-workflow' -- \
  CHANGELOG.md CHANGELOG.zh-CN.md \
  docs/superpowers/plans/2026-08-02-image-gen-cliproxyapi-integration.md \
  docs/superpowers/specs/2026-08-02-image-gen-cliproxyapi-integration-design.md
```

Expected:

- No occurrence in the image-gen plan or design.
- Changelog occurrences, if retained for historical accuracy, explicitly state retirement and do not advertise current installation.
- No current-product count or menu claim includes the retired items.

---

### Task 9: Cross-Installer Catalogue and Cleanup Verification

**Files:**
- Modify only if a verification test fails: `install.sh`, `install.ps1`, `tests/test_redundant_skill_cleanup.sh`
- Test: all installer and test files

**Interfaces:**
- Consumes: completed Bash and PowerShell changes.
- Produces: parity evidence and search-based enforcement of the allowed legacy-reference boundary.

- [ ] **Step 1: Verify Bash syntax**

Run:

```bash
bash -n install.sh
```

Expected: exit 0 with no output.

- [ ] **Step 2: Verify PowerShell parsing when available**

Run:

```bash
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -Command \
    '$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "./install.ps1"), [ref]$tokens, [ref]$errors); if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }'
else
  echo "SKIP: pwsh not installed; PowerShell parser validation unavailable"
fi
```

Expected: parser exits 0, or one explicit SKIP.

- [ ] **Step 3: Verify no active installer identifiers remain**

Run:

```bash
git grep -n -E \
  'INSTALL_MATTPOCOCK|MATTPOCOCK_SKILLS|Install-MattpocockSkills|install_mattpocock_skills|skill-mattpocock|skill-harness-workflow|plug-frontend-design' \
  -- install.sh install.ps1 tests
```

Expected: no output.

- [ ] **Step 4: Verify current catalogues exclude retired items**

Run tests that source both catalogue implementations and assert:

```text
frontend-design@claude-plugins-official is absent from active catalogue
superpowers@claude-plugins-official remains present
ecc@ecc remains present
harness-workflow is absent from selectable Skills
Matt bundle is absent from selectable Skills
```

Expected: PASS in `tests/test_redundant_skill_cleanup.sh`.

- [ ] **Step 5: Verify the frontend ID is tombstone-only**

Run:

```bash
git grep -n -F 'frontend-design@claude-plugins-official' -- \
  install.sh install.ps1 settings.json tests
```

Expected matches are limited to:

- Retired plugin tombstones.
- Removed plugin tombstones.
- Tests proving removal.

There must be no match in active plugin arrays, menu rows, mappings, or `settings.json`.

- [ ] **Step 6: Verify Matt references are cleanup-only**

Run:

```bash
git grep -n -i -E 'mattpocock|matt pocock' -- \
  install.sh install.ps1 settings.json skills tests
```

Expected matches are limited to:

- The legacy manifest filename and cleanup function names.
- Cleanup tests.

There must be no fixed 17-name list, network source, npx command, menu label, install function, or default flag.

- [ ] **Step 7: Verify harness references are digest-cleanup-only**

Run:

```bash
git grep -n -F 'harness-workflow' -- \
  install.sh install.ps1 settings.json skills tests
```

Expected matches are limited to:

- Exact-digest retired cleanup.
- Tests proving exact-copy deletion and modified-copy preservation.

There must be no tracked `skills/harness-workflow/SKILL.md` and no active menu or dispatch entry.

- [ ] **Step 8: Verify retained components were not removed**

Run:

```bash
git grep -n -F 'superpowers@claude-plugins-official' -- install.sh install.ps1 settings.json README.md README.zh-CN.md
git grep -n -F 'ecc@ecc' -- install.sh install.ps1 settings.json README.md README.zh-CN.md
```

Expected: both have active installer/documentation matches consistent with their pre-change policies.

---

### Task 10: Full Verification

**Files:**
- No planned production modifications.
- Fix only verified failures caused by this change.

**Interfaces:**
- Consumes: entire implementation.
- Produces: reproducible evidence that removal, compatibility cleanup, tests, docs, and syntax are correct.

- [ ] **Step 1: Run focused cleanup tests**

Run:

```bash
bash tests/test_redundant_skill_cleanup.sh
```

Expected: all tests pass; PowerShell behavior either passes or reports one explicit SKIP when `pwsh` is unavailable.

- [ ] **Step 2: Run focused plugin resolution tests**

Run:

```bash
bash tests/test_plugin_resolution.sh
```

Expected: all assertions pass, including retained Superpowers/ECC behavior.

- [ ] **Step 3: Run image-gen regression suites**

Run:

```bash
bash tests/test_image_gen_install.sh
bash tests/test_image_gen_wrapper.sh
```

Expected: both pass; removal of stale Matt scaffolding does not change image-gen behavior.

- [ ] **Step 4: Run GPT regression suites**

Run:

```bash
bash tests/test_gpt_config.sh
zsh tests/test_gpt_runtime.zsh
```

Expected: both pass.

- [ ] **Step 5: Run the aggregate suite**

Run:

```bash
bash tests/run.sh
```

Expected final line:

```text
SUITE: PASS
```

- [ ] **Step 6: Run syntax and documentation validation**

Run:

```bash
bash -n install.sh
zsh -n claude.zsh
jq empty settings.json
bash scripts/check-readme-sync.sh
```

Expected: all exit 0.

Run the PowerShell parser command from Task 9 when `pwsh` is available.

- [ ] **Step 7: Run repository hygiene checks**

Run:

```bash
git diff --check
git status --short
git diff --stat
```

Expected:

- `git diff --check` exits 0.
- Only planned files are modified/deleted.
- `skills/harness-workflow/SKILL.md` is recorded as deleted.
- No unrelated generated, temporary, credential, or cache files appear.

- [ ] **Step 8: Inspect the complete diff**

Run:

```bash
git diff -- \
  install.sh install.ps1 settings.json \
  skills/harness-workflow/SKILL.md \
  tests/test_redundant_skill_cleanup.sh \
  tests/test_plugin_resolution.sh \
  tests/test_image_gen_install.sh \
  README.md README.zh-CN.md plugins/README.md \
  CHANGELOG.md CHANGELOG.zh-CN.md \
  docs/superpowers/plans/2026-08-02-image-gen-cliproxyapi-integration.md \
  docs/superpowers/specs/2026-08-02-image-gen-cliproxyapi-integration-design.md
```

Expected: every hunk maps to a requirement in this plan.

---

### Task 11: Adversarial Review and Confirmed-Finding Fixes

**Files:**
- Review all modified/deleted files.
- Modify only files required to address confirmed findings.

**Interfaces:**
- Consumes: verified implementation and complete diff.
- Produces: adversarially reviewed implementation with all confirmed blocking findings fixed.

- [ ] **Step 1: Invoke the required review skill**

Invoke:

```text
/adversarial-review
```

Provide the approved design and this plan. Ask reviewers to challenge these lenses independently:

1. **Deletion authorization**
   - Can a malformed Matt manifest escape `~/.claude/skills/`?
   - Can an arbitrary same-named user Skill be deleted?
   - Is the manifest removed without broad name-based deletion?
2. **Digest correctness**
   - Is the exact former harness digest correct?
   - Do line-ending, encoding, extra-byte, missing-file, and no-hasher cases preserve user content?
3. **Plugin retirement**
   - Is frontend absent from every active catalogue and setting?
   - Does re-running the installer remove installed and enabled state?
   - Can a tombstone accidentally make it installable?
4. **Bash/PowerShell parity**
   - Do both installers clean the same artifacts at the same lifecycle points?
   - Do dry-run and uninstall behave equivalently?
5. **Retained product behavior**
   - Are Superpowers and ECC still selected under existing policies?
   - Are menu counts, defaults, summaries, and all/non-interactive modes aligned?
6. **Documentation truthfulness**
   - Are retired components absent from current promotion?
   - Does historical wording remain accurate without implying current support?
7. **Regression scope**
   - Did cleanup alter unrelated image-gen, GPT, plugin prune, or settings behavior?

- [ ] **Step 2: Triage every finding against code and tests**

For each finding:

- Reproduce it with a focused command or test.
- Mark unsupported claims as not reproducible with evidence.
- Add a failing regression test before fixing every confirmed behavior defect.
- Do not broaden scope for style-only observations unrelated to the removal.

- [ ] **Step 3: Fix all confirmed CRITICAL and HIGH findings**

No CRITICAL or HIGH finding may remain open.

- [ ] **Step 4: Fix feasible confirmed MEDIUM findings**

Fix MEDIUM findings when they affect cleanup safety, parity, catalogue accuracy, docs truthfulness, or regression confidence. Document why any remaining MEDIUM is not applicable or outside scope.

- [ ] **Step 5: Rerun the complete verification matrix**

Repeat every command from Task 10.

Expected:

```text
SUITE: PASS
all syntax/parser checks pass or explicitly skip pwsh
README sync passes
git diff --check passes
```

- [ ] **Step 6: Re-run the allowed-reference searches**

Repeat all searches from Task 9 and inspect every surviving match manually.

Expected surviving legacy references are limited to:

- Executable retired cleanup tombstones.
- Tests proving cleanup safety.
- Explicitly historical changelog statements.
- The approved removal design.
- This implementation plan.

---

### Task 12: Final Direct-on-Main Commit

**Files:**
- Stage exactly the implementation and documentation files in this plan.
- No push or PR.

**Interfaces:**
- Consumes: clean verification evidence and resolved adversarial review.
- Produces: one conventional commit directly on `main`.

- [ ] **Step 1: Confirm branch and worktree state**

Run:

```bash
git branch --show-current
git status --short
```

Expected:

```text
main
```

Status must contain only intended changes.

If the branch is not `main`, stop and report the mismatch; do not create or switch branches automatically.

- [ ] **Step 2: Run final evidence commands immediately before staging**

Run:

```bash
bash tests/run.sh
bash -n install.sh
zsh -n claude.zsh
jq empty settings.json
bash scripts/check-readme-sync.sh
git diff --check
```

Run the PowerShell parser command when available.

Expected: all pass.

- [ ] **Step 3: Stage exact files**

Run:

```bash
git add \
  install.sh \
  install.ps1 \
  settings.json \
  skills/harness-workflow/SKILL.md \
  tests/test_redundant_skill_cleanup.sh \
  tests/test_plugin_resolution.sh \
  tests/test_image_gen_install.sh \
  README.md \
  README.zh-CN.md \
  plugins/README.md \
  CHANGELOG.md \
  CHANGELOG.zh-CN.md \
  docs/superpowers/plans/2026-08-02-image-gen-cliproxyapi-integration.md \
  docs/superpowers/specs/2026-08-02-image-gen-cliproxyapi-integration-design.md \
  docs/superpowers/plans/2026-08-02-remove-redundant-skills.md
```

If `tests/run.sh` required no change, do not stage it. If another planned file was legitimately changed to fix a confirmed review finding, add it explicitly and explain why in the final summary.

- [ ] **Step 4: Inspect the staged patch**

Run:

```bash
git diff --cached --check
git diff --cached --stat
git status --short
```

Expected:

- No whitespace errors.
- No unplanned file is staged.
- Vendored harness source appears as deleted.
- The new cleanup test and plan appear as added.

- [ ] **Step 5: Create the single final conventional commit**

Run:

```bash
git commit -m "refactor(installer): remove redundant skills"
```

Expected: one successful commit on `main`.

- [ ] **Step 6: Verify the commit without pushing**

Run:

```bash
git status --short
git log -1 --oneline
```

Expected:

- Working tree is clean.
- Latest commit subject is:

```text
refactor(installer): remove redundant skills
```

Do not push and do not open a PR unless the user separately requests it.

---

## Acceptance Criteria

- Matt has no active state flag, fixed 17-name array, menu choice, dispatch, default/all behavior, npx installer, or manifest writer.
- The legacy Matt manifest cleanup removes only safe leaf directories explicitly recorded in the manifest and then removes the manifest.
- A missing Matt manifest does not authorize deletion of any Skill.
- Unsafe Matt manifest lines cannot escape `~/.claude/skills/`.
- `frontend-design` is absent from active Bash and PowerShell catalogues, menus, mappings, settings defaults, tests, READMEs, and plugin documentation.
- Its exact former plugin ID remains only in retired/removed tombstones, cleanup tests, and governance/history records.
- A normal installer re-run removes its installed plugin state and strips it from `enabledPlugins`.
- `skills/harness-workflow/` is no longer tracked.
- An installed harness copy is deleted only when `SKILL.md` hashes to `d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba`.
- Modified, user-authored, unverifiable, or missing-file harness directories are preserved with a warning.
- Normal install, uninstall, and dry-run have Bash/PowerShell parity.
- Superpowers and ECC retain their pre-change selection policies.
- Menu counts, catalogue counts, defaults, summaries, and bilingual documentation match the final implementation.
- Historical changelog structure remains accurate without presenting retired items as current features.
- Existing image-gen, GPT, plugin resolution, README sync, and aggregate tests pass.
- Adversarial review has no unresolved confirmed CRITICAL or HIGH findings.
- `VERSION` remains `2.17.0`.
- One final conventional commit is created directly on `main`; no branch, worktree, push, or PR is created.

### Critical Files for Implementation

- `/Users/hydraallen/Desktop/Github/PublicRepo/claude-code-config/install.sh`
- `/Users/hydraallen/Desktop/Github/PublicRepo/claude-code-config/install.ps1`
- `/Users/hydraallen/Desktop/Github/PublicRepo/claude-code-config/tests/test_redundant_skill_cleanup.sh`
- `/Users/hydraallen/Desktop/Github/PublicRepo/claude-code-config/README.md`
- `/Users/hydraallen/Desktop/Github/PublicRepo/claude-code-config/CHANGELOG.md`

# CLIProxyAPI Image Generation Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Work directly in the current `main` checkout; do not create a branch/worktree, commit, or push.

**Goal:** Network-install `sinedied/agent-skills:image-gen` as an always-installed component and make it use ChatGPT/Codex OAuth through local CLIProxyAPI from every `cl*` launcher.

**Architecture:** The installers fetch the upstream Skill with `npx skills add`; no upstream image-generation source is vendored. A repository-owned Bash wrapper starts or reuses CLIProxyAPI, reads its local client key securely, injects child-only `OPENAI_*` variables, and delegates unchanged arguments to upstream `image_gen.py`. Installer-managed markers augment the downloaded `SKILL.md` idempotently.

**Tech Stack:** Bash 3.2+, Zsh, PowerShell, Python 3 standard-library test fixtures, `npx skills`, CLIProxyAPI OpenAI-compatible Images endpoints.

## Global Constraints

- Exact source: `sinedied/agent-skills`, exact Skill: `image-gen`.
- Exact image model: `gpt-image-2`; never call it `image2` in user-facing configuration.
- Minimum direct Images-compatible CLIProxyAPI release: `v7.2.17`.
- Exact local base URL: `http://127.0.0.1:8317/v1`.
- Never vendor upstream `SKILL.md`, `image_gen.py`, prompts, samples, or license.
- Always install; do not add a selectable menu item.
- Never print or pass the proxy key in argv; inject it only into the delegated process environment.
- Bash/macOS is the supported end-to-end runtime. PowerShell installs the network Skill and assets but must not claim native Windows runtime support.
- No real credentials, paid image requests, or external image traffic in tests.
- No commit, push, branch, or worktree creation.

---

## File Map

- Create `scripts/image-gen-cliproxyapi.sh`: secure service/version/key/delegation wrapper.
- Create `tests/test_image_gen_wrapper.sh`: wrapper unit and integration tests.
- Create `tests/test_image_gen_install.sh`: installer, augmentation, manifest, uninstall, and PowerShell parity tests.
- Create `tests/fixtures/mock_images_server.py`: loopback-only OpenAI Images mock; not upstream Skill code.
- Modify `install.sh`: unconditional network install, wrapper copy, instruction augmentation, ownership manifest, uninstall.
- Modify `install.ps1`: matching network installation/ownership behavior and explicit Windows limitation.
- Modify `README.md`, `README.zh-CN.md`, `docs/BACKENDS.md`, `docs/BACKENDS.zh-CN.md`.
- Modify `CHANGELOG.md`, `CHANGELOG.zh-CN.md`, `VERSION` to `2.17.0`.
- Leave `claude.zsh` unchanged unless a failing launcher-independence test proves a generic path defect.

## Shared Interfaces

Wrapper invocation: `~/.claude/scripts/image-gen-cliproxyapi.sh <all upstream image_gen.py arguments>`.

Test overrides: `IMAGE_GEN_CLIPROXYAPI_CONFIG`, `IMAGE_GEN_UPSTREAM_SCRIPT`, `IMAGE_GEN_CLIPROXYAPI_HEALTH_URL`, `IMAGE_GEN_CLIPROXYAPI_LOG`, `IMAGE_GEN_CLIPROXYAPI_TIMEOUT`.

Managed markers:

```text
<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->
<!-- END claude-code-config CLIProxyAPI image-gen integration -->
```

Ownership manifest `~/.claude/.image-gen-sinedied`:

```text
skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-cliproxyapi.sh
```

Exact network command:

```bash
npx -y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen
```

---

### Task 1: Secure Wrapper Validation Helpers

**Files:** Create `scripts/image-gen-cliproxyapi.sh`; create `tests/test_image_gen_wrapper.sh`.

**Produces:** `image_gen_find_binary`, `image_gen_parse_version`, `image_gen_version_at_least`, `image_gen_read_binary_version`, `image_gen_extract_config_key`.

- [ ] Write failing tests for three binary names, missing binary, accepted version formats/suffixes, versions below `7.2.17`, malformed output, and `version`/`--version` fallback.
- [ ] Run `bash tests/test_image_gen_wrapper.sh`; confirm RED.
- [ ] Implement Bash 3.2-compatible parsing/comparison without `sort -V`, with one production floor `7.2.17`.
- [ ] Add failing constrained YAML key-parser tests equivalent to `gpt_extract_config_key`, including nested/placeholder/mapping/alias/anchor/control/whitespace rejection.
- [ ] Implement a self-contained parser; never source `install.sh` at runtime.
- [ ] Run focused tests and `bash -n scripts/image-gen-cliproxyapi.sh`; confirm GREEN.

### Task 2: Service Lifecycle and Child-Only Delegation

**Files:** Modify wrapper and wrapper tests.

**Produces:** `image_gen_service_healthy`, `image_gen_wait_ready`, `image_gen_start_service`, `image_gen_main`.

- [ ] Add failing distinct sanitized diagnostics for missing upstream script, `python3`, `curl`, config, binary, valid version, and key.
- [ ] Implement deterministic prerequisite order; old versions mention `7.2.17` and `brew upgrade cliproxyapi`.
- [ ] Add failing healthy-service tests proving no duplicate start, exact argument forwarding, child-only environment override, and exit-code preservation.
- [ ] Implement child assignments for loopback `/v1`, local key, and `gpt-image-2` immediately before `python3`.
- [ ] Add failing successful-start, early-exit, timeout, restrictive-log-directory, config-only argv, and reuse tests.
- [ ] Implement `<binary> --config <path>`, existing log, 25-second timeout, and `kill -0` early-exit checks without dumping logs.
- [ ] Add a `bash -x` sentinel-key regression test covering stdout, stderr, argv, and filenames.
- [ ] Disable xtrace before secrets, unset secret locals before restoring trace state, and preserve delegated status.
- [ ] Run focused tests and syntax check; confirm GREEN.

### Task 3: Local Generation/Edit Protocol Test

**Files:** Create `tests/fixtures/mock_images_server.py`; modify wrapper tests.

- [ ] Build a loopback ephemeral-port stdlib server with health, generation, and edit routes; record no secrets.
- [ ] Generate a temporary test-only protocol probe that reads injected env, decodes synthetic `b64_json`, and emits `image[]` multipart. Do not track upstream code.
- [ ] Add failing tests requiring `gpt-image-2`, correct paths, saved generation output, edit multipart, and no external host.
- [ ] Wire EXIT cleanup and confirm GREEN.

### Task 4: Bash Network Installer and Augmentation

**Files:** Create `tests/test_image_gen_install.sh`; modify `install.sh`.

**Produces:** `_image_gen_npx_cmd`, `_image_gen_npx`, `image_gen_render_integration_block`, `image_gen_augment_skill`, `install_image_gen`.

- [ ] Create temporary-HOME/fake-npx tests for exact command, `DO_NOT_TRACK=1`, detached stdin, three attempts, transient recovery, and final warning.
- [ ] Add failing full dry-run tests proving no network/HOME writes; fix top-level directory creation if required.
- [ ] Add failing augmentation cases: insert, replace once, preserve outside bytes and upstream changes, reject missing layout and malformed/duplicate markers, support spaced paths, atomic replacement.
- [ ] Implement bounded network installation next to `install_mattpocock_skills` with warning accounting.
- [ ] Implement canonical managed instructions: invoke wrapper, forward arguments, no OpenAI Platform key, `gpt-image-2`, Windows limitation.
- [ ] Add the wrapper to installer-managed user scripts with executable permissions and accurate output.
- [ ] Write mode-600 manifest atomically only after all installation and augmentation steps succeed.
- [ ] Call `install_image_gen` unconditionally after scripts; add no menu flag. Test interactive-all-off, normal, essential, and all exactly once.
- [ ] Run installer tests and `bash -n install.sh`; confirm GREEN.

### Task 5: Ownership-Safe Bash Uninstall

**Files:** Modify `install.sh` and installer tests.

- [ ] Add failing cases for valid ownership deletion, stale manifest, untracked directory, malformed/wrong manifest, wrapper removal, and dry-run.
- [ ] Validate all fixed manifest fields before recursively deleting only `skills/image-gen`.
- [ ] Add uninstall preview for Skill, wrapper, and manifest.
- [ ] Run installer tests and syntax check; confirm GREEN.

### Task 6: PowerShell Installer Parity

**Files:** Modify `install.ps1` and installer tests.

**Produces:** `Get-ImageGenNpxArgs`, `Get-ImageGenIntegrationBlock`, `Update-ImageGenSkillInstructions`, `Install-ImageGen`.

- [ ] Add static failing assertions for source/flags, three-attempt retry, manifest, markers, wrapper, unconditional call, and native-Windows limitation.
- [ ] If `pwsh` exists, add temporary-`USERPROFILE` behavior tests; otherwise report a skip.
- [ ] Implement array-based npx invocation, `DO_NOT_TRACK` restoration, sanitized dry-run, retry, layout validation, atomic augmentation, and post-success manifest.
- [ ] Install the Bash wrapper asset as Bash/WSL-only.
- [ ] Call `Install-ImageGen` after `Install-Scripts`, independent of selectable skills; align nothing-selected behavior.
- [ ] Validate manifest fields during uninstall and ensure cleanup is within `Invoke-Uninstall`.
- [ ] Accurately state that native Windows `cl_*`/CLIProxyAPI lifecycle is unsupported.
- [ ] Run installer tests and PowerShell parser when available.

### Task 7: Launcher Independence

**Files:** Modify wrapper tests; modify `claude.zsh` only if tests prove a generic defect.

- [ ] Prove `cl`, all named profiles, and `_auto` variants share global Skill/wrapper paths.
- [ ] Prove hostile/incompatible `ANTHROPIC_BASE_URL` never changes child `OPENAI_BASE_URL`.
- [ ] Leave launcher production code unchanged when tests pass.
- [ ] Run wrapper tests and `zsh -n claude.zsh`.

### Task 8: Bilingual Documentation and Release Metadata

**Files:** Modify both READMEs, both backend guides, both changelogs, and `VERSION`.

- [ ] Document network source, `gpt-image-2`, minimum `v7.2.17`, OAuth login, Homebrew upgrade, image routes, wrapper/config paths, key boundaries, all-launcher behavior, direct port-8317 routing, and native-Windows limitation.
- [ ] Keep English/Chinese structure and claims aligned.
- [ ] List image-gen as always-installed network Skill, distinct from vendored `skills/`; update scripts tree entry.
- [ ] Set `VERSION` to `2.17.0`.
- [ ] Add matching `2.17.0` Features, Design Rationale, Notes & Caveats without overclaims.
- [ ] Run `bash scripts/check-readme-sync.sh`.

### Task 9: Verification and Adversarial Review

- [ ] Run both focused suites and `bash tests/run.sh`.
- [ ] Run Bash/Zsh syntax, README sync, and PowerShell parser if present.
- [ ] Assert no tracked upstream image-gen source/instructions/prompts/license.
- [ ] Search consistency for `v7.2.17`, `gpt-image-2`, wrapper, manifest, source, base URL, and markers.
- [ ] Invoke `adversarial-review` for delete authorization, marker overreach, injection, xtrace/argv leakage, dry-run writes, Windows claims, unconditional paths, and real-HOME/network test leakage.
- [ ] Fix all CRITICAL/HIGH and feasible MEDIUM findings, then rerun verification.
- [ ] Run `git diff --check`, inspect status/diff, and do not commit or push.

## Acceptance Criteria

- Every install mode attempts the exact network command once; no upstream implementation is tracked.
- Dry-run is network/write free; retry, augmentation, ownership, and uninstall are tested.
- Wrapper requires CLIProxyAPI `v7.2.17+`, starts/reuses it, and never leaks the key.
- Only the delegated process receives loopback `/v1`, local key, and `gpt-image-2`.
- Local mock generation/edit and all launcher-independence tests pass.
- Existing tests, syntax checks, and bilingual docs remain green.
- Version is `2.17.0`; no commit, push, branch, or worktree is created.

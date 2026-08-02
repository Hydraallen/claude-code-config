# Image Generation via CLIProxyAPI Integration Design

## Goal

Make `sinedied/agent-skills:image-gen` available after a normal one-click installation and let Claude Code sessions launched through `cl`, `cl_claude`, `cl_glm`, `cl_ccr`, or `cl_gpt` generate and edit images through the user's local CLIProxyAPI and ChatGPT/Codex OAuth subscription.

The public image model identifier is `gpt-image-2`. The integration must not require an OpenAI Platform API key and must not vendor upstream Skill source.

## Scope

### Included

- Network installation of `image-gen` from `sinedied/agent-skills`
- Default, unconditional installation whenever the installer performs its standard component installation
- Bash/macOS and PowerShell installer parity for downloading the Skill
- A small repository-owned runtime wrapper that supplies CLIProxyAPI service and environment integration
- Installation-time augmentation of the downloaded Skill instructions to use the wrapper
- CLIProxyAPI version and configuration checks
- Uninstall ownership tracking
- Automated tests, backend documentation, README updates, and a version-level changelog entry

### Excluded

- Vendoring or forking the upstream `image-gen` source
- Reimplementing OpenAI Images request or response handling
- Automatically performing browser-based `cliproxyapi --codex-login`
- Shipping OAuth tokens or OpenAI API keys
- Routing image generation through CCR, GLM, or Anthropic endpoints
- Supporting CLIProxyAPI releases that predate direct Images routes

## Upstream Dependency

The installer invokes the `skills` CLI through an argument-array helper, detached stdin, bounded retry, telemetry suppression, and warning accounting:

```bash
npx -y skills@latest add sinedied/agent-skills \
  --global \
  --agent claude-code \
  --copy \
  --yes \
  --skill image-gen
```

The installed Skill remains an upstream-managed dependency under `~/.claude/skills/image-gen/`. The repository contains no copy of `SKILL.md`, `image_gen.py`, sample prompts, or the upstream license.

The installer applies bounded retries and supports dry-run mode. Missing Node.js/`npx` or a failed download produces a clear installation failure while allowing unrelated components to finish. The final installation summary reports the failure.

## Installation Policy

`image-gen` is an always-installed standard component rather than a selectable menu item. Interactive users cannot deselect it, and `--essential`, `--all`, and the normal non-interactive path all attempt the same installation.

The installer records ownership in a dedicated manifest after successful installation. Uninstall removes `~/.claude/skills/image-gen/` only when the manifest proves this installer installed it. It never deletes an untracked user-authored directory with the same name.

## Architecture

### Upstream Skill

The upstream Python implementation remains unchanged. It already supports:

- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`
- `OPENAI_IMAGE_MODEL`
- `POST /v1/images/generations`
- `POST /v1/images/edits`
- OpenAI-compatible `data[].b64_json` and URL responses

### Repository-Owned Wrapper

A focused wrapper installed under `~/.claude/scripts/` prepares the runtime environment and delegates to the downloaded `image_gen.py`. Its interface mirrors the upstream script arguments, so the Skill can pass `generate`, `edit`, prompts, file paths, and optional image parameters without translation.

The wrapper performs only these responsibilities:

1. Locate a supported CLIProxyAPI executable.
2. Validate that `~/.cli-proxy-api/config.yaml` exists and is readable.
3. Validate that the CLIProxyAPI version supports direct Images routes.
4. Reuse a healthy service on `127.0.0.1:8317` or start it with the existing config.
5. Extract the first valid local `api-keys` entry without printing it.
6. Execute the upstream script with process-local environment values:
   - `OPENAI_BASE_URL=http://127.0.0.1:8317/v1`
   - `OPENAI_API_KEY=<local CLIProxyAPI key>`
   - `OPENAI_IMAGE_MODEL=gpt-image-2`
7. Preserve the upstream process exit status and output.

The wrapper does not mutate shell-global environment variables and does not change the active Claude Code backend.

### Skill Instruction Augmentation

After a successful network install, the installer adds a clearly delimited, idempotent local integration section to the installed `SKILL.md`. That section tells Claude Code to call the repository-owned wrapper instead of invoking `image_gen.py` directly or requesting an OpenAI API key.

Re-running the installer replaces the managed section rather than duplicating it. Content outside the managed markers remains upstream-controlled.

If the upstream layout is missing the expected `SKILL.md` or script, augmentation fails visibly instead of leaving a partially configured integration that asks for the wrong credentials.

## Launcher Independence

All launch modes execute the same Claude Code binary and discover global Skills from `~/.claude/skills/`. The wrapper is therefore available in:

- `cl`
- `cl_claude`
- `cl_glm`
- `cl_ccr`
- `cl_gpt`
- generated `_auto` variants

Image traffic always goes directly to CLIProxyAPI on port 8317. It does not inherit or reuse the active profile's `ANTHROPIC_BASE_URL`. This prevents `cl_glm` and `cl_ccr` from accidentally sending OpenAI Images requests to incompatible gateways.

## Configuration and Credential Boundaries

`~/.cli-proxy-api/config.yaml` remains the authority for the client-facing proxy key and service configuration. The wrapper reads the key at invocation time, so installer key reconciliation and later key changes remain effective without rewriting the Skill.

Secrets must never appear in:

- Installer status output
- Dry-run output
- Wrapper diagnostics
- Process command lines
- Log file names
- Test snapshots

OAuth credentials remain private to CLIProxyAPI. The wrapper sees only the local proxy key.

## CLIProxyAPI Compatibility

The minimum supported CLIProxyAPI version is the first stable release containing direct `/v1/images/generations` and `/v1/images/edits` routes. The implementation will encode and test a concrete minimum after verifying upstream tags during development.

When the installed binary is too old, the wrapper exits before sending a request and reports an actionable upgrade command such as:

```bash
brew upgrade cliproxyapi
```

Version parsing must tolerate the executable names already accepted by `profiles/gpt.json` and common `version` output prefixes. An unparseable version fails safely with a diagnostic rather than assuming support.

## Error Handling

The integration distinguishes these failures:

- `npx` unavailable
- Upstream Skill download failure
- Installed Skill layout incompatible with augmentation
- CLIProxyAPI executable unavailable
- CLIProxyAPI version too old or unparseable
- Config missing or unreadable
- No valid local proxy key
- Service start failure or readiness timeout
- Missing/expired Codex OAuth authorization
- Upstream image request failure

Diagnostics identify the failed layer and give one next action. They never include secrets. The wrapper preserves CLIProxyAPI logs in the existing logs directory and reuses the launcher service lifecycle conventions where practical.

## Bash and PowerShell Boundaries

Both installers perform the network Skill installation, retries, dry-run behavior, manifest tracking, and instruction augmentation.

The repository's current CLIProxyAPI launcher and config reconciliation are Bash/Zsh-only. PowerShell installs the Skill and wrapper assets but must state the runtime limitation accurately unless the implementation adds a native Windows CLIProxyAPI service wrapper. It must not claim end-to-end Windows support without tests.

## Tests

Automated tests use temporary HOME directories, fake `npx`, fake CLIProxyAPI executables, fixture configs, and a local mock Images server. They never inspect the operator's real credentials or make paid/external image requests.

Required coverage:

1. Exact `npx skills add` source, agent, copy mode, and `--skill image-gen` arguments.
2. Standard, essential, all, and interactive installations all attempt image-gen installation.
3. Dry-run performs no network call or filesystem write.
4. Bounded retry succeeds after transient failures and reports final failure.
5. Successful installation writes the ownership manifest.
6. Uninstall removes only an installer-owned image-gen directory.
7. Instruction augmentation is idempotent and preserves upstream content.
8. Missing or changed upstream layout fails visibly.
9. Wrapper reuses a healthy CLIProxyAPI process.
10. Wrapper starts an unavailable service and waits for readiness.
11. Missing binary, old version, missing config, and missing key produce distinct errors.
12. Proxy key never appears in stdout, stderr, or process arguments.
13. Wrapper injects the loopback `/v1` base and `gpt-image-2` only into the delegated process.
14. Mock generation returns and saves `data[].b64_json` successfully.
15. Mock edit accepts the upstream multipart request shape.
16. `cl`, `cl_claude`, `cl_glm`, `cl_ccr`, and `cl_gpt` share the same installed Skill and wrapper path.
17. Bash syntax, PowerShell syntax, existing installer tests, and documentation synchronization checks pass.

## Documentation and Release Notes

Update English and Chinese backend documentation to explain:

- ChatGPT/Codex OAuth image generation
- Exact model name `gpt-image-2`
- Skill installation source
- CLIProxyAPI version requirement
- Port and key boundaries
- Login and upgrade commands
- Availability across all `cl_*` launchers
- Windows limitations, if any remain

Add a version-level `CHANGELOG.md` entry describing the feature, design rationale, and compatibility caveats.

## Success Criteria

After a normal one-click installation on a supported Bash/macOS system with current CLIProxyAPI and completed Codex OAuth, any Claude Code session launched through the repository's `cl*` commands can invoke the globally installed `image-gen` Skill. The wrapper starts or reuses CLIProxyAPI, supplies the local proxy key without exposing it, requests `gpt-image-2`, and delegates unchanged image generation or editing behavior to the upstream Skill.

Re-running the installer updates the network-installed Skill and managed instructions idempotently. Uninstall removes only installer-owned artifacts. No upstream source is committed to this repository.

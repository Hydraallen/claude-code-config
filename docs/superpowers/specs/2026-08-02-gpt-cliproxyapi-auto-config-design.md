# GPT CLIProxyAPI Auto-Configuration Design

## Goal

Make the Bash/macOS one-click installer safely configure the GPT backend without requiring users to invent and manually synchronize a proxy API key.

After installation, these files must contain the same key:

- `~/.cli-proxy-api/config.yaml` → first `api-keys` entry
- `~/.claude/profiles/gpt.json` → `.env.ANTHROPIC_AUTH_TOKEN`

The installer must reuse an existing key when possible, generate one only when necessary, and never expose the key in terminal output or logs.

## Scope

### Included

- Bash/macOS installer support in `install.sh`
- Safe creation and normalization of `~/.cli-proxy-api/config.yaml`
- Synchronization with `~/.claude/profiles/gpt.json`
- Immediate and accurate startup diagnostics in `claude.zsh`
- Automated tests
- English and Chinese backend documentation
- Version-level changelog entry

### Excluded

- Running `cliproxyapi --codex-login` automatically
- Starting CLIProxyAPI during installation
- Implementing a Windows `cl_gpt` launcher
- Automatically deleting proxy credentials during uninstall
- Synchronizing `remote-management.secret-key`, which protects a different API

The PowerShell installer will only state that automated GPT launcher/configuration is not available on Windows yet. It will not create a configuration that the current Windows installation cannot use.

## Existing Architecture

The current `main` branch already provides:

- `profiles/gpt.json`, including CLIProxyAPI service metadata
- GPT selection in the Bash installer menu
- Profile installation and credential-preserving upgrades
- Dynamic `cl_gpt` and `cl_gpt_auto` commands
- Lazy CLIProxyAPI startup and health checking

The missing layer is installation-time creation and synchronization of the CLIProxyAPI API key and config file.

## Authority and Conflict Rules

The resolved key is selected deterministically:

1. Use the first valid `api-keys` entry found in the existing `config.yaml`.
2. Otherwise, use a non-empty, non-`YOUR_*` token already present in `profiles/gpt.json`.
3. Otherwise, generate a new cryptographically secure 32-byte key encoded as 64 lowercase hexadecimal characters.

When `config.yaml` and `gpt.json` contain different concrete values, `config.yaml` wins. CLIProxyAPI is the component that validates requests, so its key list is the authoritative source.

Multiple existing API keys are reduced to the first valid key when the file is normalized. The backup preserves the original list.

## Configuration Flow

The GPT configuration step runs only when the `gpt` profile was selected and after `install_profiles` has completed.

1. Inspect `~/.cli-proxy-api/config.yaml` without printing its contents.
2. Extract the first valid key from common block or inline `api-keys` YAML forms.
3. Inspect `.env.ANTHROPIC_AUTH_TOKEN` in the installed GPT profile.
4. Resolve the authoritative key using the conflict rules above.
5. If no key exists, generate one with a CSPRNG:
   - Prefer `openssl rand -hex 32`.
   - Fall back to 32 bytes from `/dev/urandom`, encoded as hexadecimal.
   - Fail the GPT configuration step if neither source is available.
6. If an existing `config.yaml` differs from the normalized target, create a timestamped backup before overwriting it.
7. Atomically write this normalized configuration:

   ```yaml
   host: "127.0.0.1"
   port: 8317
   auth-dir: "~/.cli-proxy-api"
   api-keys:
     - "<resolved-key>"
   ```

8. Atomically update `.env.ANTHROPIC_AUTH_TOKEN` in `profiles/gpt.json` with the same key.
9. Report whether the installer reused or generated a key without displaying the key.

If the normalized output is already present and the profile matches, the step is a no-op. A repeated installation does not rotate the key or create another backup.

## Existing YAML Handling

The installer will not add `yq` or attempt a lossless general YAML round trip.

It will recognize the common CLIProxyAPI representations needed to reuse an existing key, including:

- A top-level block sequence under `api-keys:`
- A top-level inline sequence such as `api-keys: ["key"]`
- Quoted or unquoted scalar values that do not use advanced YAML constructs

Unknown fields, comments, additional keys, and advanced YAML syntax do not need to survive in the normalized file because the user selected the backup-and-normalize policy. They remain available in the timestamped backup.

If the parser cannot recover an existing key, the installer falls back to the concrete profile token, then generates a new key. It must never copy an ambiguous or malformed scalar into the normalized configuration.

## Backup and File Safety

Before changing an existing `config.yaml`, the installer creates a timestamped backup in the same directory. The backup is required before replacement; backup failure aborts the GPT configuration step.

Security and durability requirements:

- `~/.cli-proxy-api` mode: `700`
- `config.yaml`, its backups, and GPT profile files containing tokens: `600`
- Generated keys never appear in stdout, stderr, dry-run output, command traces, or filenames
- Temporary files are created in the destination directory
- Temporary files receive restrictive permissions before content is written
- Replacement uses an atomic rename
- Failed writes remove temporary files and preserve the original target
- Existing profile backups and baseline files containing credentials also receive mode `600`

In `--dry-run` mode, the installer does not generate a key, create directories, read secrets into output, make backups, or modify files. It reports only the planned action.

## Error Handling

The GPT configuration step is installation-critical when it has started modifying or reconciling GPT configuration. The installer records a critical issue and leaves actionable instructions when any of these operations fail:

- Secure random generation
- Existing key extraction needed for reconciliation
- Backup creation
- Directory or file permission changes
- Temporary-file creation or atomic replacement
- JSON parsing or profile update

No failure path may leave a fail-open CLIProxyAPI configuration with an empty `api-keys` list or a non-loopback host.

OAuth remains a separate manual step. After configuration, the installer instructs the user to run:

```bash
cliproxyapi --codex-login
```

## Runtime Diagnostics

`claude.zsh` will validate the GPT service prerequisites before launching CLIProxyAPI:

- If the configured file is missing or unreadable, fail immediately with its exact path and a repair instruction.
- Do not wait for the 25-second health timeout when process startup has already failed.
- Show `loginHint` only when the failure evidence indicates missing OAuth credentials or authorization, not for every health-check timeout.
- Preserve the log path and relevant process output for other startup failures.

`cl_gpt` and `cl_gpt_auto` share this service behavior. Their only intended difference remains Claude Code permission handling.

## Components

### Bash installer helpers

Small, independently testable helpers will handle:

- Secure key generation
- Existing YAML key extraction
- Concrete profile-token extraction
- Key-source resolution
- Normalized YAML rendering
- Restrictive backup and atomic replacement
- GPT profile synchronization

A coordinator function will run these helpers only for the selected GPT backend.

### Shell runtime

The service startup path will gain prerequisite and early-process-exit checks. This logic remains generic where practical, using service metadata rather than hard-coding the `gpt` profile name.

### PowerShell installer

No partial Windows implementation will be added. User-facing output and documentation will clarify that the current PowerShell installer has no `cl_gpt` runtime counterpart.

## Tests

Automated Bash tests must cover:

1. Fresh configuration generates a 64-character hexadecimal key.
2. The same key appears in normalized YAML and the GPT profile.
3. `host` is exactly `127.0.0.1`, `port` is `8317`, and `api-keys` is non-empty.
4. A repeated run is idempotent: no key rotation, no rewrite, and no new backup.
5. Existing block-list YAML reuses the first key.
6. Existing inline-list YAML reuses the first key.
7. Multiple keys normalize to the first key after preserving the original backup.
8. A config/profile conflict uses the config key.
9. Missing config key with a concrete profile token reuses the profile token.
10. No usable key in either source generates a new key.
11. Comments, unknown fields, and advanced or malformed YAML are backed up before normalization.
12. Backup failure leaves the original config and profile unchanged.
13. Write or permission failure leaves the original target unchanged.
14. `--dry-run` performs no writes and emits no key.
15. Config directory, files, profile backups, and baseline files receive restrictive permissions.
16. Logs and status messages do not contain the resolved key.
17. Missing runtime config fails immediately instead of waiting 25 seconds.
18. A missing config does not produce the authorization hint.
19. An authorization-specific failure still produces the login hint.
20. Existing profile model slots, service metadata, and unrelated fields remain unchanged when the token is synchronized.

Tests must use temporary HOME directories and fixtures. They must never inspect or modify the operator's real configuration.

## Documentation and Release Notes

Update both backend guides to describe automatic key creation/reuse, backup-and-normalize behavior, file locations, permissions, OAuth as a remaining manual step, and the config-first conflict rule.

Add a version-level `CHANGELOG.md` entry covering:

- Automatic GPT proxy configuration
- Security rationale for loopback binding and non-empty API keys
- Existing-config normalization and backups
- Immediate startup diagnostics
- Windows limitation

## Success Criteria

A fresh Bash/macOS installation with the GPT backend selected creates a secure, internally consistent CLIProxyAPI configuration without exposing the key. Re-running the installer preserves the key. Existing configurations are backed up and normalized according to the selected policy. After the user completes OAuth, `cl_gpt` and `cl_gpt_auto` can start the proxy without manual key editing.

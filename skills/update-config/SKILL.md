---
name: update-config
description: Update Hydraallen/claude-code-config (script-installer setup) to the latest version. Checks the remote VERSION on main, then re-runs install.sh with the interactive selector. Use when user types /update-config or asks to update their Claude Code configuration.
---

# Update — Hydraallen/claude-code-config

## Overview

Check for updates and upgrade the configuration installed by this fork's script installer
(`install.sh`; `install.ps1` on Windows) to the latest version of
`https://github.com/Hydraallen/claude-code-config` on `main`. To inspect, add, remove or
repair individual catalog items, use the `edit-config` skill; both share
`~/.claude/agent-config/selection.json`.

## Workflow

Run the following steps **in order**. Stop immediately if a step fails. Do NOT ask for
confirmation between steps — just execute.

### Step 1: Check versions

```bash
# Installed version
INSTALLED="$(cat ~/.claude/.awesome-claude-code-config-version 2>/dev/null || echo 'not installed')"

# Remote version
REMOTE="$(curl -fsSL https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/VERSION 2>/dev/null | tr -d '[:space:]')"

echo "Installed: $INSTALLED"
echo "Remote:    $REMOTE"
```

If `INSTALLED` equals `REMOTE`, tell the user they are already on the latest version and stop.

If the remote fetch fails, warn the user and stop.

### Step 2: Run the installer (remote mode)

Download and execute the latest installer interactively:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.sh)
```

On Windows (PowerShell) the equivalent is:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Hydraallen/claude-code-config/main/install.ps1)))
```

This launches the interactive component selector (without a terminal it falls back to the
default selection, which only adds and never removes). The selector opens with what is
installed already checked; anything the user unchecks is removed on submit (installer-owned
items only, edited files backed up to `~/.claude/agent-config/backups/`). Tell the user this
before running it. The installer handles:
- Smart merging of `settings.json` (preserves user customizations)
- Version stamping
- Font and dependency installation
- Plugin updates, and removal of retired plugins (GitHub, claude-mem, PUA)
- The `agent-config/selection.json` record edit-config reads

### Step 3: Report result

After the installer finishes, confirm the new version:

```bash
cat ~/.claude/.awesome-claude-code-config-version 2>/dev/null
```

Tell the user the update is complete with the new version number.

## Notes

- The installer's smart merge preserves existing `settings.json` customizations
- `lessons.md` is never overwritten if it already exists
- Plugins are re-installed (idempotent — existing ones are skipped)
- User should restart Claude Code after updating for changes to take effect

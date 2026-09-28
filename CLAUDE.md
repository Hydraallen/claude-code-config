# Repository instructions

Read [AGENTS.md](AGENTS.md) for repository work.
For installation, follow [INSTALL.md](INSTALL.md): show only the target agent's supported options directly in the conversation and use its [selection procedure](INSTALL.md#choose-options), preferring native multi-select questions. Export a selection document only when requested.
For configuration queries and changes, invoke [edit-config](skills/edit-config/SKILL.md); it routes installed changes to INSTALL.md and repository changes to MAINTAIN.md.
For changes to this repository's skills, catalogue or templates, follow [MAINTAIN.md](MAINTAIN.md).
Deployable global instructions live under `platforms/claude/templates/`.
Fork note: this fork (Hydraallen/claude-code-config) also ships the script installers `install.sh` / `install.ps1` as a supported Claude Code install path; catalogue changes must update both installers and pass `scripts/check-catalog-sync.sh` and `scripts/check-readme-sync.sh` (see [MAINTAIN.md](MAINTAIN.md)).

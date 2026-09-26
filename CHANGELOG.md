# Changelog

## [4.1.0] - 2026-09-27

### Features
- Claude lessons hooks: Claude Code (checked on 2.1.220 and 2.1.280) sends the model only a 2,000-character preview of SessionStart hook output longer than 10,000 characters. The startup and compaction commands in `platforms/claude/templates/lessons-hooks.json` now print `lessons.md` only when it is smaller than 9,000 bytes; otherwise they print its path and size and ask the model to read it with the Read tool (the whole file at session start, the entries relevant to the current task after compaction). The hooks no longer ask the model to confirm that lessons were loaded.
- Codex AGENTS template: global and project lessons are appended to by default; a correction that restates an existing rule extends that entry, and entries are merged or deleted only when the user asks. The self-correction steps follow the same rule. The Rule Set line drops "This repository does not install additional language skills implicitly": once the template is deployed as the global AGENTS.md, "this repository" is read as whichever project is open.
- `platforms/claude/README.md` records the hook-output and skill-listing limits and how to check them after deploying lessons, skills or plugins.

### Bug Fixes
- `storage-analyzer`: on Linux the HTML report used the macOS file-manager name 访达 in every button, note, confirmation and status message, and a `system.os` of `Darwin` would have produced the Windows name 资源管理器. The report template now picks the name from `system.platform`, which `scan.py` writes from `sys.platform`: 访达 on macOS, 资源管理器 on Windows, 文件管理器 on Linux and other platforms. Analysis JSON without `platform` falls back to whole-word matching on `system.os`.
- `storage-analyzer`: on Linux the root filesystem appeared a second time under 其他磁盘, because `disk_name` used the device (`/dev/nvme0n1p2 (/)`) while the matching `system.disks` entry used the mount point (`/`). The root entry now has the same name as `disk_name`; macOS and Windows already matched.
- Claude settings template: remove `env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING`. Claude Code reads it only for Opus 4.6 and Sonnet 4.6; the template's `opus` alias resolves to Claude Opus 5.5, where thinking is always on and `effortLevel` sets its depth. Both README default tables drop the row.
- Claude global instructions template: remove `Extended thinking: ultrathink` (Claude Code recognizes the keyword only in the user's message), the rule to enter Plan Mode for every task of three or more steps, the "Highest Priority" heading label and "When in doubt, treat it as a correction". The lessons line now describes the hook behaviour.
- `adversarial-review` (Claude): start Codex reviewers with an explicit read-only sandbox (`-s workspace-write` only for a reviewer that runs tests) and stdin from `/dev/null`; each reviewer returns its findings as the final message that `codex exec -o` captures and does not edit the reviewed code or write a findings file; an output containing only a plan or an acknowledgement counts as a failed reviewer. Remove the `TaskOutput` polling instruction (Claude Code 2.1.280 no longer provides the tool) and the unrecognized `schedule` frontmatter field; `brain/principles.md` is optional. `UPSTREAM.md` records the changes.
- `storage-analyzer`: correct the snap advice in `references/linux.md` and the `scan.py` hint (`refresh.retain=2` does not reduce retention on classic systems; remove disabled revisions instead) and add conditional `/var/tmp` guidance; the read-only rule covers the analysed data and excludes the skill's own output and local server; describe the `server.py` path allowlists and the `app_paths` rules as implemented (Windows apps under `Program Files` get no `app_paths`); the platform status section points to the verification status in `UPSTREAM.md`; group the trigger description by intent. `UPSTREAM.md` records the changes.
- `paper-reading`: remove wording in SKILL.md, the references and the validator message that compared the skill with an earlier version (such as "original technical template" and "original list template"), the mandatory diagram-audit table (section 7 is now "Choose and render visuals"), and run evidence from the evidence coordinates, since the workflow runs no experiments; quick-overview requests use the same depth.
- Documentation: `AGENTS.md` states how to read the project `lessons.md` (a later entry replaces an earlier one on the same subject, retired installer and branch entries are provenance, and the current files take precedence); the project `lessons.md` header names each agent's global lessons file and drops the template example block; wording corrections in catalog.md, docs/agent-setup-spec.md, docs/migration.md, scripts/README.md and the TypeScript hooks rule (a Stop hook runs at the end of every response).

### Design Rationale
- Apart from the two storage-analyzer fixes of 2026-09-17 (file-manager name and root disk), the template, skill and documentation changes come from Claude Code's `/claude-api prompt-audit` run against this repository for Claude Fable 5.1 and Claude Opus 5.5. Each change is tied to a finding; findings about Claude Code behaviour were checked against the Claude Code 2.1.280 binary and the claude-api migration guides. Environment facts, user preferences, exact commands and project history are kept.
- Claude Code sets the limit, so the hook chooses its output by file size; users can keep complete lessons files, and their content is not cut to the 2,000-character preview.
- The removals from the Claude template were checked against Claude models only. The Codex AGENTS template keeps its "(Highest Priority)" heading and planning line, and the historical Codex copy of `adversarial-review` is unchanged.
- The project `lessons.md` keeps its original entries, as MAINTAIN.md requires; AGENTS.md explains which entries take precedence instead of rewriting them.

### Notes & Caveats
- Installed CLAUDE.md and AGENTS.md keep their previous text until edit-config merges the new templates; the ultrathink and Plan Mode lines stay until then. `scripts/managed_files.py merge` only adds or updates keys and appends hook entries, so merging the new settings and lessons-hooks templates leaves an installed `env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` in place and keeps the previous SessionStart `startup` and `compact` entries next to the new ones; remove them from settings.json separately, with the user's confirmation.
- When `lessons.md` is 9,000 bytes or larger, its content reaches the model only through the Read call that the hook output asks for, and that call adds the whole file to context at the start of every session; keeping it under 9,000 bytes restores direct injection.
- The storage-analyzer disk fix changes the scanner output, so an analysis JSON produced before it still lists `/` twice; scanning again resolves it. The file-manager name and root-disk fixes were verified on Ubuntu 24.04.4 with a static report and a server-mode render; macOS and Windows were checked only by rendering representative `system` blocks. The storage-analyzer changes in this version are not part of khazix-skills#50; `skills/storage-analyzer/UPSTREAM.md` records them.
- Behavioural comparisons on real tasks were not run for the prompt changes.

## [4.0.0] - 2026-09-17

### Features
- Rename the repository to **awesome-agent-config** and publish the unified Claude/Codex configuration on **main**. Preserve the former Claude main as `archive/legacy-claude` and move the other retained branches under `archive/legacy-`; keep their commit histories and existing tags/releases.
- Replace the separate installers with agent-guided setup. The current agent detects its environment, presents every supported option by category directly in chat, and collects choices through native multi-select questions or numbered replies.
- Keep the full bilingual README, its 11 categories and usage tables. The shared catalogue contains 39 active IDs and the accepted author recommendations: 20 for Claude, 18 for Codex.
- Prefer compatible native plugins and upstream installation methods. Keep author-owned and customized skills here with attribution; offer AI Research as one 31-skill bundle and handoff only within Matt.
- Use shared `edit-config` for configuration inspection, additions, edits, removals, repairs and updates. Point it and both global templates to the new repository's main; recognize the old repository name and preserve explicit source policies.
- Keep each agent's instructions and lessons independent. Claude's complete English writing rule replaces the former Common rules; language rules remain selectable. Codex setup disables external-agent auto-import and uses native subagents without custom role presets.

### Design Rationale
- One catalogue and conversational workflow let agents maintain platform-specific recipes without another installer framework or duplicated third-party payloads.
- The unified main is the current installation and development source. Archive branches and historical provenance remain available for reference without becoming runtime dependencies.
- Recommendations explain the author's preferences; each user's actual selections, ownership and customizations determine what is installed or changed.

### Notes & Caveats
- **Breaking installation change:** `install.sh` / `install.ps1` now only explain the agent entry point and exit with code 2. Use the README request and INSTALL.md instead of legacy menu flags.
- Lark/Feishu MCP, Claude-Mem, all PUA variants, GitHub MCP and its plugin alternative, the old Common rules and Codex role presets are retired from active installation. Old update skills migrate to edit-config. Existing installations, credentials, hooks, memory and modified files are preserved until an explicit, ownership-checked change.
- Repository renaming does not migrate an installed development branch, pinned revision, fork or local source to main. Follow the [source migration guidance](docs/migration.md#repository-identity); preserve previous source records and partial bundle selections.
- ResearchStudio Idea/Reel and PPT Master install source with necessary adaptation; runtime setup remains a first-use step. Plugin availability depends on the client/account. Isolated macOS checks cover the affected setup; native Windows/WSL and credentialed integrations still need their target environments.

## [4.0.0-dev.7] - 2026-09-17

### Features
- Retire GitHub MCP from both agents' installation scope. Remove the remaining catalogue/README entry, recommendation, MCP setup recipe and its GitHub plugin alternative.
- The catalogue now has 39 active IDs; recommendation drafts contain 20 Claude and 18 Codex items. Both platform guides route old GitHub selections to migration instructions.

### Design Rationale
- Removing the integration includes its alternative installation route so ordinary updates cannot restore the retired item through a plugin.

### Notes & Caveats
- Existing services, plugins, shared connections and credentials are preserved. Live removal requires an explicit target and ownership checks; ordinary Git/gh workflows and review skills remain available.
- Both agents' templates already contain no GitHub service configuration. Other MCP recipes, source revisions and historical records are unchanged.

## [4.0.0-dev.6] - 2026-09-17

### Features
- Retire the Codex explorer, reviewer and docs-researcher presets: remove their three role templates, registration patches, Core entries and recommendations.
- Align the catalogue, bilingual README and platform instructions. The catalogue now has 40 active IDs; recommendation drafts contain 20 Claude and 19 Codex items.

### Design Rationale
- Use native subagents and selected skills for task-specific work without installing legacy fixed-model roles or their concurrency and depth settings.

### Notes & Caveats
- Native multi-agent support remains enabled. Existing custom agents and shared settings are preserved until an explicit, ownership-checked uninstall; migration guidance covers registrations, files and prior setting values.
- Historical provenance and changelog entries remain intact. Other installation choices and recommendation markers are unchanged.

## [4.0.0-dev.5] - 2026-09-17

### Features
- Present the target agent's complete installation options, descriptions, recommendations and installed status directly in the conversation.
- Prefer the host's actual multi-select question tool, with numbered chat selections when only single-choice/text questions or no question tool are available. Align README prompts, repository entry points and edit-config with this interaction.

### Design Rationale
- Users should be able to choose and install in the same conversation. A generated selection document does not complete that interaction; the catalogue remains the shared source for both agents.

### Notes & Caveats
- Tool capabilities and limits depend on the current client and mode. Reuse explicit choices; missing replies and preselected values do not authorize installation. Export selection documents or installation reports only when requested; installation receipts are still maintained.
- Catalogue entries, recommendation drafts and installation recipes are unchanged.

## [4.0.0-dev.4] - 2026-09-13

### Features
- Retire Lark/Feishu MCP, Claude-Mem and all three PUA skills from the active catalogue, recipes and templates.
- Replace Claude's eight common rules with one complete English writing rule, including every supplied editing example. Keep the language rules independent and remove references to missing common files or assumed skills/hooks.
- Replace both update skills with shared edit-config for configuration queries, additions, edits, removals, repairs and updates. Global templates route to it; it follows agent-config-for-agents and keeps queries read-only.
- Align the Context7 reference template with its HTTP recipe and synchronize configuration entry points. Propose 20 Claude and 22 Codex recommendations from the current release-branch installer defaults, pending the author's final confirmation.

### Design Rationale
- One configuration skill avoids platform-specific update instructions diverging. Explicit source checks preserve deliberate forks, pins and local policies during migration.
- Writing requirements belong in a dedicated rule; language guidance remains independently selectable. Recommendation mappings are recorded in the current catalogue without creating legacy-branch installation dependencies.

### Notes & Caveats
- The catalogue has 43 active IDs. Retired entries, old common rules and update skill paths have explicit migration guidance; existing installations, customizations and memory are not automatically deleted.
- Recommendations use matching Bash/PowerShell menu defaults. Permissions split from old base config and the new writing rule are identified as mapping decisions; recommendation markers do not authorize installation or higher permissions.
- Source changes are verified in isolated homes. Windows/WSL execution and authenticated integrations still require their target environments.

## [4.0.0-dev.3] - 2026-09-12

### Features
- Combine AI Research into one selection with six upstream plugins and the same 31 skills on Claude and Codex. Keep all members visible; the catalogue now has 46 active IDs.
- Prefer verified Codex plugins for AI Research, Anthropic's document suite and frontend-slides. Discover OpenAI official/curated plugins from the account's actual directory, including equivalent document tools, Superpowers and GitHub where available.
- Add a focused Codex plugin reference that distinguishes publishers, records native selectors and explains source/MCP fallback decisions. Verify actual skill loading as well as installed state.

### Design Rationale
- Keep the conversational installer and existing README categories while reducing top-level choices. Native plugins own their lifecycle; agents maintain upstream recipes and selection records.
- Preserve real compatibility, selected scope and pinned revisions. A successful plugin command alone does not prove that its skills load.

### Notes & Caveats
- Existing six-group IDs and Codex's old 24-member selection retain their scope until an explicit migration. The new bundle adds seven skills; component ownership and partial failures remain traceable.
- Codex CLI 0.153.4 ignores Humanizer and PPT Master's root skill entries; PPT Master's nested Git source also bypasses the outer revision pin. Both keep upstream source installation. Matt, examples, PUA and Playwright retain their documented constraints.
- Validation used isolated macOS Codex homes, real plugin loading and resource comparison. OAuth integrations, other operating systems and business runtime dependencies are not covered by those checks. The IDE extension currently lacks plugin support.

## [4.0.0-dev.2] - 2026-09-12

### Features
- Restore the full bilingual README, including the original 11 categories, usage guidance, tables, showcases, settings and customization. Align all 51 active catalogue entries with the same category order.
- Make installation and updates independent of legacy branches. Record the repository source and its branch, default-branch, pinned or local update policy; both update skills follow that record.
- Add MAINTAIN.md so agents maintain skill payloads, upstream recipes, recommendations and both READMEs together, including explicit handling of retired IDs.
- Split Claude and Codex blank lessons templates and require an explicit agent when seeding a log. Keep their global instructions and project memory conventions independent.
- Replace vendored Humanizer, Humanizer-zh and neat-freak originals with upstream installation recipes. Keep author-owned and intentionally customized skills here with attribution.
- Fold handoff into the Matt bundle, using its upstream version; remove the independent option and local copy. Codex's selected Matt bundle now has 20 members.

### Design Rationale
- The current repository is the authority for ongoing development. Historical mappings prove the initial consolidation and remain available for provenance without freezing future skill changes.
- Preserve the detailed user-facing guide while letting the agent own platform detection, explanations and installation commands.

### Notes & Caveats
- Existing lessons remain untouched. Direct helper callers must use `seed-lessons --agent claude` or `--agent codex`.
- Older selection receipts need a verified repository source before updates; a missing or incompatible source is not replaced with a guessed legacy branch.
- Existing standalone handoff and third-party copies remain until the user chooses a migration. Humanizer's current upstream is 3.0.0; explain the change from the previously bundled 2.2.0 before migrating.
- No branch archival or remote default-branch change is performed. During the transition, share the current README page URL with its ref or open its checkout.

## [4.0.0-dev.1] - 2026-09-12

### Features
- Introduce one agent-guided setup flow for Claude and Codex: detect the environment, show the complete classified catalogue with numbers and author recommendations, then install the user's choices.
- Preserve main v3.2.0 and codex v2.11.0 skills in one repository. Share five identical payloads, retain five platform variants, and document the external plugin/skill sources and pinned selections.
- Prefer native plugin/MCP management. Add small helpers for protected copies, partial JSON/TOML merges, backups, source adaptation and MCP initialization checks.
- Separate base settings, permissions, status lines, lessons hooks and subagents. Disable Codex external-agent import independently of optional base settings.

### Design Rationale
- Let the existing agent explain platform differences and resolve user choices. A second menu, binary distribution or package resolver would duplicate its role.
- Keep one Markdown catalogue with separate Claude/Codex recommendation columns. Recommendations remain empty until the author provides them.
- Preserve selected membership and revisions during native migration, especially Codex's Matt v1.1.0 snapshot and custom handoff.

### Notes & Caveats
- This development branch starts from main; neither release branch is merged or replaced. See [migration notes](docs/migration.md) and [source mappings](docs/source-provenance.json).
- install.sh/install.ps1 now show the agent entry point and exit with code 2. Previous menu flags no longer mutate configuration.
- Existing custom files, credentials, lessons and memory databases are preserved. Updating a selection never removes omitted items; uninstall requires an explicit request and ownership checks.
- ResearchStudio Idea/Reel and PPT Master install complete source with necessary adaptations only. Runtime dependencies remain a first-use step.
- Replace only the exact legacy model_instructions_file = "lessons.md" setting after deploying explicit lessons-reading instructions.
- Native Windows/WSL execution, credentialed integrations and the complete Claude-Mem lifecycle need platform-specific validation. New development checks remain outside the published tree; relevant existing skill tests remain.

Earlier releases: [Claude history](platforms/claude/CHANGELOG.previous.md) · [Codex history](platforms/codex/CHANGELOG.previous.md).

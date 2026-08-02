# Redundant Skills Removal Design

## Goal

Remove the Matt Pocock 17-Skill bundle, the `frontend-design` plugin, and the vendored `harness-workflow` Skill from the repository's current product surface while retaining Superpowers and ECC. Preserve narrowly scoped upgrade cleanup so previous installer users do not retain retired managed components.

## Scope

### Remove

- Matt Pocock state, fixed Skill list, menu item, selection handling, network installer, manifest creation, default/all behavior, tests, and reader-facing documentation
- `frontend-design` from plugin catalogues, menu mappings, default settings, tests, and reader-facing documentation
- `skills/harness-workflow/` and its Bash/PowerShell menu and selection handling
- Promotional and architectural references to these active components in README, plugin documentation, plans, specs, and changelog entries

### Retain

- `superpowers@claude-plugins-official`
- `ecc@ecc`
- Minimal retired-component tombstones required to identify and remove earlier installer-managed copies
- Accurate historical release structure where it can be expressed without presenting retired components as current features

## Compatibility Cleanup

### Matt Pocock bundle

The retired cleanup reads the legacy ownership manifest and removes only directories recorded there. It then removes the manifest. It does not keep the 17-name installation array and does not delete Skills merely because they have familiar names.

### frontend-design plugin

The exact former plugin ID remains only in retired-plugin and removed-plugin tombstones. Re-running the installer removes it from installed plugin state and `enabledPlugins` without exposing it as an installable option.

### harness-workflow

The vendored source is deleted. Cleanup removes an old installed copy only when its `SKILL.md` matches the former repository-managed content digest. A same-named user-authored or modified Skill is preserved with a warning.

## Bash and PowerShell Parity

Both installers receive equivalent changes:

- Delete active selection and installation paths
- Preserve equivalent retired cleanup behavior
- Keep catalogue resolution and non-interactive/all defaults aligned
- Update summaries and counts derived from selections

## Documentation Policy

Reader-facing documentation must no longer advertise or recommend the retired components. Legacy names are permitted only inside isolated executable tombstones and tests that prove cleanup safety. Existing design documents that used a retired installer function as an architectural example are rewritten generically.

## Testing

Verification includes:

1. Bash syntax validation
2. PowerShell parser validation when PowerShell is available
3. Existing installer test suite
4. Updated plugin catalogue expectations
5. Matt legacy-manifest cleanup deletes only manifest-owned directories
6. `frontend-design` is removed from installed/enabled plugin state
7. `harness-workflow` cleanup deletes only an exact former managed copy
8. Searches confirm no active menu, install, settings, documentation, or vendored-source references remain
9. Superpowers and ECC remain selected according to their existing policies

## Delivery

Implementation is performed by a subagent, followed by main-session verification and adversarial review. Confirmed findings are fixed before creating the final conventional commit directly on `main`.

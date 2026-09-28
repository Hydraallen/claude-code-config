# Plugins and skills

The complete platform-aware catalogue is [catalog.md](../catalog.md).
Configuration queries and changes use [edit-config](../skills/edit-config/SKILL.md); installed changes follow [INSTALL.md](../INSTALL.md).
Changes to repository entries and upstream recipes follow [MAINTAIN.md](../MAINTAIN.md).

This fork also keeps the script installers: `./install.sh` (macOS/Linux) or `.\install.ps1` (Windows) open an interactive selector for the same plugin groups.

## Plugins that need configuration

### playwright — do not also enable the standalone Playwright MCP

The plugin and the standalone MCP server in [`../mcp/`](../mcp/README.md) both
register under the name `playwright`. A user-scope MCP entry shadows the
plugin's, so enabling both leaves the plugin one silently never started. The
standalone server is default-off in the installer for this reason; if you
already have the duplicate, drop it with `claude mcp remove playwright`.

### context7 — optional `CONTEXT7_API_KEY`

Its header is `${CONTEXT7_API_KEY:-}`, so an unset key is not an error: the
server connects anonymously and is rate-limited. Set the variable only if you
hit throttling.

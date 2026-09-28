# MCP Servers

> **Note**: Context7 and Playwright now have official plugin equivalents. Use plugins instead — see [`plugins/README.md`](../plugins/README.md). Lark-MCP remains here as a standalone MCP server; upstream retired it, this fork keeps it. The agent-guided path registers the same servers with the recipes in [platforms/claude/README.md](../platforms/claude/README.md#mcp). The GitHub MCP server is retired; the script installers remove the old user-scope `github` entry when it points at `api.githubcopilot.com/mcp/`.

## Servers

| Server | Transport | Default | Purpose |
|--------|-----------|---------|---------|
| **playwright** | stdio | **off (opt-in)** | Browser automation via `@playwright/mcp` |
| **[Lark-MCP](https://github.com/larksuite/lark-openapi-mcp)** | stdio | **off (opt-in)** | Official Feishu/Lark OpenAPI — call Lark platform APIs from AI assistants |

Both are opt-in; a default install registers neither.

`playwright` is off because the official **playwright plugin** claims the same
server name. A user-scope MCP entry shadows the plugin's, so installing both
leaves the plugin one silently never started — `claude mcp list` shows a single
`playwright` and no hint that the other exists. Enable this standalone server
only if you deselect that plugin. To undo an existing duplicate:
`claude mcp remove playwright`.

Lark-MCP is off because it requires Feishu App credentials and each session it
runs costs roughly 1 GB of RAM.

Only `playwright` ships in the [`mcp-servers.json`](./mcp-servers.json) template,
which the `claude.zsh` wrapper auto-loads on each launch if you copy it to
`~/.claude/mcp/mcp-servers.json`. The wrapper passes it via `--mcp-config` per
launch rather than writing `~/.claude.json`, so a server added this way also
shadows a same-named plugin, and removing the `~/.claude.json` entry alone will
not stop it coming back.

## Installation

```bash
# Both servers are opt-in. Pick them in the interactive selector, or add one directly:
./install.sh --only mcp          # standalone Playwright MCP (skip the playwright plugin)
./install.sh --only mcp-lark     # Lark/Feishu MCP; prompts for App ID / Secret on a terminal

# Or add Lark/Feishu manually:
claude mcp add lark-mcp --scope user -- npx -y @larksuiteoapi/lark-mcp mcp -a YOUR_APP_ID -s YOUR_APP_SECRET -t preset.light
```

Replace `YOUR_APP_ID` and `YOUR_APP_SECRET` with your Feishu app credentials ([open.feishu.cn](https://open.feishu.cn/)).

Two details that bite people: the `--` is required, because `claude mcp add` also
uses `-s` (for `--scope`) and would otherwise swallow your app secret; and
`-t preset.light` keeps the exposed tool list small, since the package's default
preset is large enough that upstream's own FAQ lists "token limit exceeded" as a
known symptom.

**Getting credentials, granting permissions, app vs user identity, and the
common failure modes are covered step by step in
[docs/LARK-MCP.md](../docs/LARK-MCP.md) — 中文版见
[docs/LARK-MCP.zh-CN.md](../docs/LARK-MCP.zh-CN.md).**

To enable Lark via the always-on shell wrapper instead, add a `lark-mcp` entry to
`~/.claude/mcp/mcp-servers.json` with your real credentials.

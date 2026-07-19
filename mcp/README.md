# MCP Servers

> **Note**: Context7, GitHub, and Playwright now have official plugin equivalents. Use plugins instead — see [`plugins/README.md`](../plugins/README.md). Lark-MCP remains here as a standalone MCP server.

## Servers

| Server | Transport | Default | Purpose |
|--------|-----------|---------|---------|
| **playwright** | stdio | on | Browser automation via `@playwright/mcp` |
| **[Lark-MCP](https://github.com/larksuite/lark-openapi-mcp)** | stdio | **off (opt-in)** | Official Feishu/Lark OpenAPI — call Lark platform APIs from AI assistants |

Only `playwright` ships in the default [`mcp-servers.json`](./mcp-servers.json) template
(auto-loaded by the `claude.zsh` shell wrapper on each launch). Lark-MCP is **not**
enabled by default: it requires Feishu App credentials and each session it runs costs
roughly 1 GB of RAM. Add it explicitly only if you use it.

## Installation

```bash
# Default MCP servers (Playwright only):
./install.sh --mcp

# Lark/Feishu is opt-in — pick it in the interactive selector, or add manually:
claude mcp add --scope user --transport stdio lark-mcp -- npx -y @larksuiteoapi/lark-mcp mcp -a YOUR_APP_ID -s YOUR_APP_SECRET
```

Replace `YOUR_APP_ID` and `YOUR_APP_SECRET` with your Feishu app credentials ([open.feishu.cn](https://open.feishu.cn/)).

To enable Lark via the always-on shell wrapper instead, add a `lark-mcp` entry to
`~/.claude/mcp/mcp-servers.json` with your real credentials.

# MCP Servers

> **Note**: Context7, GitHub, and Playwright now have official plugin equivalents. Use plugins instead — see [`plugins/README.md`](../plugins/README.md). Lark-MCP and Codex CLI remain here as standalone MCP servers.

## Included Servers

| Server | Transport | Purpose |
|--------|-----------|---------|
| **[Lark-MCP](https://github.com/larksuite/lark-openapi-mcp)** | stdio | Official Feishu/Lark OpenAPI — call Lark platform APIs from AI assistants |
| **[Codex CLI](https://github.com/tuannvm/codex-mcp-server)** | stdio | OpenAI Codex as MCP server — code review, code generation, and AI-assisted development |

## Installation

```bash
./install.sh --mcp

# Or manually:
claude mcp add --scope user --transport stdio lark-mcp -- npx -y @larksuiteoapi/lark-mcp mcp -a YOUR_APP_ID -s YOUR_APP_SECRET
claude mcp add --scope user --transport stdio codex-cli -- npx -y codex-mcp-server
```

Replace `YOUR_APP_ID` and `YOUR_APP_SECRET` with your Feishu app credentials ([open.feishu.cn](https://open.feishu.cn/)).

Codex CLI requires an OpenAI API key — set `OPENAI_API_KEY` in your environment.

# Claude Code wrapper function
# Usage: _cl_run <tag> <skip_permissions> [args...]
_cl_run() {
  local tag="$1"
  local skip_permissions="$2"
  shift 2

  local claude_home="$HOME/.claude"

  setopt local_options null_glob

  local -a extra_args=(--model opus)
  if [[ "$skip_permissions" == "true" ]]; then
    extra_args+=(--dangerously-skip-permissions)
  fi

  # Build system prompt from system-prompt.txt
  local system_prompt=""
  if [ -f "$claude_home/system-prompt.txt" ]; then
    system_prompt=$(cat "$claude_home/system-prompt.txt")
    print -u2 "$tag: loaded system-prompt.txt"
  fi

  # Append project-level CLAUDE.md if exists
  if [ -f "$PWD/CLAUDE.md" ]; then
    system_prompt="${system_prompt}

$(cat "$PWD/CLAUDE.md")"
    print -u2 "$tag: appended project CLAUDE.md"
  fi

  if [ -n "$system_prompt" ]; then
    extra_args+=(--append-system-prompt "$system_prompt")
  fi

  # Load MCP config (supports both wrapped and flat formats)
  local mcp_config=""
  local mcp_source=""
  if [ -f "$claude_home/mcp_settings.json" ]; then
    mcp_source="$claude_home/mcp_settings.json"
  elif [ -f "$claude_home/mcp/mcp-servers.json" ]; then
    mcp_source="$claude_home/mcp/mcp-servers.json"
  fi

  if [ -n "$mcp_source" ] && command -v jq >/dev/null 2>&1; then
    mcp_config=$(jq -c 'if .mcpServers then .mcpServers else . end' "$mcp_source" 2>/dev/null)
    if [ "$mcp_config" = "{}" ]; then
      mcp_config=""
    else
      print -u2 "$tag: loaded MCP servers from $(basename "$mcp_source")"
    fi
  fi

  if [ -n "$mcp_config" ]; then
    local mcp_file="${TMPDIR:-/tmp}/claude-mcp-$$.json"
    printf '%s\n' "{\"mcpServers\": $mcp_config}" > "$mcp_file"
    extra_args+=(--mcp-config "$mcp_file")
    trap "rm -f '$mcp_file'" EXIT INT TERM
  fi

  claude "$@" "${extra_args[@]}"
  return $?
}

# Ensure skipDangerousModePermissionPrompt is not set in settings.json
_ensure_permissions_enabled() {
  local settings_file="$HOME/.claude/settings.json"
  if [[ -f "$settings_file" ]] && command -v jq >/dev/null 2>&1; then
    local has_skip
    has_skip=$(jq 'has("skipDangerousModePermissionPrompt")' "$settings_file" 2>/dev/null)
    if [[ "$has_skip" == "true" ]]; then
      local tmp_file="${settings_file}.tmp.$$"
      jq 'del(.skipDangerousModePermissionPrompt)' "$settings_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$settings_file"
      print -u2 "cl: removed skipDangerousModePermissionPrompt from settings.json"
    fi
  fi
}

# Main entry point (with permission prompts)
cl() {
  _ensure_permissions_enabled
  _cl_run "cl" "false" "$@"
}

# Auto mode (skip permissions)
cl_auto() {
  _cl_run "cl_auto" "true" "$@"
}

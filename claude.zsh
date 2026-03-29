# Claude Code wrapper function

# Read default profile: returns "claude" or "glm"
_cl_get_profile() {
  local profile_file="$HOME/.claude/default-profile"
  if [[ -f "$profile_file" ]]; then
    local profile
    profile=$(<"$profile_file")
    profile="${profile// /}"
    if [[ "$profile" == "glm" || "$profile" == "claude" ]]; then
      echo "$profile"
      return
    fi
  fi
  echo "claude"
}

# Switch or display default profile
cl_switch() {
  local profile_file="$HOME/.claude/default-profile"
  if [[ -z "$1" ]]; then
    print -u2 "Current profile: $(_cl_get_profile)"
    return
  fi
  case "$1" in
    claude|glm)
      echo "$1" > "$profile_file"
      print -u2 "Switched default profile to: $1"
      ;;
    *)
      print -u2 "Usage: cl_switch [claude|glm]"
      return 1
      ;;
  esac
}

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

# Main entry point — routes based on default profile
cl() {
  _ensure_permissions_enabled
  if [[ "$(_cl_get_profile)" == "glm" ]]; then
    _cl_glm_run "cl" "false" "$@"
  else
    _cl_run "cl" "false" "$@"
  fi
}

# Auto mode — routes based on default profile
cl_auto() {
  if [[ "$(_cl_get_profile)" == "glm" ]]; then
    _cl_glm_run "cl_auto" "true" "$@"
  else
    _cl_run "cl_auto" "true" "$@"
  fi
}

# Explicit Claude API (ignores default profile)
cl_claude() {
  _ensure_permissions_enabled
  _cl_run "cl_claude" "false" "$@"
}

cl_claude_auto() {
  _cl_run "cl_claude_auto" "true" "$@"
}

# GLM backend runner — injects GLM env vars for the duration of the call
_cl_glm_run() {
  local tag="$1"
  local skip_permissions="$2"
  shift 2

  local glm_config="$HOME/.claude/glm-env.json"
  if [[ ! -f "$glm_config" ]]; then
    print -u2 "$tag: ERROR — $glm_config not found"
    print -u2 "$tag: Create it with your GLM credentials. See claude.zsh for format."
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    print -u2 "$tag: ERROR — jq is required but not found"
    return 1
  fi

  # Save and override env vars from glm-env.json
  local -A _saved_env
  local key val
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    _saved_env[$key]="${(P)key-__unset__}"
    export "$key=$val"
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$glm_config" 2>/dev/null)

  print -u2 "$tag: using GLM backend ($(jq -r '.ANTHROPIC_BASE_URL // "unknown"' "$glm_config"))"

  _cl_run "$tag" "$skip_permissions" "$@"
  local rc=$?

  # Restore original env vars
  for key in "${(@k)_saved_env}"; do
    if [[ "${_saved_env[$key]}" == "__unset__" ]]; then
      unset "$key"
    else
      export "$key=${_saved_env[$key]}"
    fi
  done

  return $rc
}

# GLM mode (with permission prompts)
cl_glm() {
  _ensure_permissions_enabled
  _cl_glm_run "cl_glm" "false" "$@"
}

# GLM auto mode (skip permissions)
cl_glm_auto() {
  _cl_glm_run "cl_glm_auto" "true" "$@"
}

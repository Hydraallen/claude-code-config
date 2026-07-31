# Claude Code wrapper function
#
# Multi-backend launcher. Every backend is one JSON file in ~/.claude/profiles/:
#
#   { label, note, credentialKeys[], service|null, unset[], env{} }
#
# Adding a backend = dropping a JSON file in that directory. No code changes:
# cl_<name> and cl_<name>_auto are generated at source time from whatever is there.
#
#   cl              route via ~/.claude/default-profile
#   cl_auto         same, with --dangerously-skip-permissions
#   cl_claude       Claude official subscription (native OAuth)
#   cl_glm          GLM Coding Plan (Zhipu)
#   cl_gpt          ChatGPT subscription via CLIProxyAPI
#   cl_ccr          CCR gateway — GLM + GPT merged in one /model list
#   cl_switch NAME  change the default
#   cl_stop [NAME]  stop a backend service this launcher started (--all for every one)
#   cl_profiles     list backends and their status

_CL_PROFILE_DIR="$HOME/.claude/profiles"
_CL_LEGACY_GLM="$HOME/.claude/glm-env.json"
_CL_RUN_DIR="$HOME/.claude/run"

# Function names this file defines itself; a profile may not shadow them.
_CL_RESERVED_NAMES=(switch auto profiles stop run)

# Backend names, one per line. "claude" always sorts first — it is the only one
# that works with zero configuration.
#
# Names are restricted to [A-Za-z0-9_-] because they are interpolated into
# generated function definitions and split on whitespace by every caller. A
# profile file is user-authored, and this file is sourced from .zshrc, so one
# odd filename must not be able to break every new terminal.
_cl_list_profiles() {
  local -a names=()
  if [[ -d "$_CL_PROFILE_DIR" ]]; then
    local f n
    for f in "$_CL_PROFILE_DIR"/*.json(N); do
      n="${${f:t}:r}"
      if [[ ! "$n" =~ ^[A-Za-z0-9_-]+$ ]]; then
        print -u2 "cl: ignoring profile ${f:t} — name must match [A-Za-z0-9_-]+"
        continue
      fi
      names+=("$n")
    done
  fi
  # Legacy layout: no profiles dir, but the old flat glm-env.json is still there.
  if (( ${#names} == 0 )); then
    names=(claude)
    [[ -f "$_CL_LEGACY_GLM" ]] && names+=(glm)
  fi
  print -l -- claude ${(o)${names:#claude}}
}

_cl_profile_file() {
  local name="$1"
  if [[ -f "$_CL_PROFILE_DIR/$name.json" ]]; then
    print -- "$_CL_PROFILE_DIR/$name.json"
  elif [[ "$name" == "glm" && -f "$_CL_LEGACY_GLM" ]]; then
    print -- "$_CL_LEGACY_GLM"
  fi
}

_cl_profile_label() {
  local file="$1"
  [[ -n "$file" ]] && command -v jq >/dev/null 2>&1 || return
  jq -r '.label // empty' "$file" 2>/dev/null
}

# Read default profile; falls back to "claude" when unset or no longer valid.
_cl_get_profile() {
  local profile_file="$HOME/.claude/default-profile"
  if [[ -f "$profile_file" ]]; then
    local profile
    profile=$(<"$profile_file")
    profile="${profile//[[:space:]]/}"
    if [[ -n "$profile" ]] && print -l -- $(_cl_list_profiles) | grep -qxF -- "$profile"; then
      print -- "$profile"
      return
    fi
  fi
  print -- claude
}

# Switch or display the default profile
cl_switch() {
  local profile_file="$HOME/.claude/default-profile"
  if [[ -z "$1" ]]; then
    print -u2 "Current profile: $(_cl_get_profile)"
    print -u2 "Available: $(_cl_list_profiles | paste -sd' ' -)"
    return
  fi
  if print -l -- $(_cl_list_profiles) | grep -qxF -- "$1"; then
    print -- "$1" > "$profile_file"
    print -u2 "Switched default profile to: $1"
  else
    print -u2 "Unknown profile: $1"
    print -u2 "Available: $(_cl_list_profiles | paste -sd' ' -)"
    return 1
  fi
}

_cl_service_healthy() {
  local url="$1"
  [[ -z "$url" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time 2 "$url" >/dev/null 2>&1
}

_cl_wait_healthy() {
  local url="$1" limit="$2" waited=0
  while (( waited < limit )); do
    sleep 1
    (( waited++ ))
    if _cl_service_healthy "$url"; then
      print -- "$waited"
      return 0
    fi
  done
  return 1
}

# First binary from .service.bins[] that is actually installed.
_cl_service_bin() {
  local file="$1" candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if command -v "$candidate" >/dev/null 2>&1; then
      print -- "$candidate"
      return 0
    fi
  done < <(jq -r '.service.bins[]? // empty' "$file" 2>/dev/null)
  return 1
}

# Serialize the start path so two shells racing on the same profile do not both
# spawn a proxy. A plain mkdir is the lock: atomic everywhere, no modules. The
# holder's pid is recorded so a lock left behind by a killed shell cannot wedge
# every later start.
#
# `command` throughout this section: .zshrc aliases like `alias rm=trash` are
# expanded when this file is sourced, and a lock that cannot be released would
# wedge the launcher for the rest of the session.
_cl_lock_acquire() {
  local lockdir="$1" holder
  command mkdir -p "${lockdir:h}"
  if command mkdir "$lockdir" 2>/dev/null; then
    print -- $$ > "$lockdir/pid"
    return 0
  fi
  holder=$(cat "$lockdir/pid" 2>/dev/null)
  if [[ -z "$holder" ]] || ! kill -0 "$holder" 2>/dev/null; then
    command rm -rf "$lockdir"
    if command mkdir "$lockdir" 2>/dev/null; then
      print -- $$ > "$lockdir/pid"
      return 0
    fi
  fi
  return 1
}

_cl_lock_release() {
  command rm -rf "$1"
}

# Pids get recycled, so a recorded pid is only ours if the live command line
# still mentions the binary we launched.
_cl_pid_is_ours() {
  local pid="$1" bin="$2" cmd
  [[ -z "$pid" || -z "$bin" ]] && return 1
  cmd=$(ps -o command= -p "$pid" 2>/dev/null)
  [[ -n "$cmd" && "$cmd" == *"$bin"* ]]
}

_cl_stop_one() {
  local name="$1"
  local pidfile="$_CL_RUN_DIR/$name.pid"
  if [[ ! -f "$pidfile" ]]; then
    print -u2 "cl_stop: $name — no service started by this launcher"
    return 0
  fi

  local pid bin
  { read -r pid; read -r bin } < "$pidfile"

  if ! _cl_pid_is_ours "$pid" "$bin"; then
    print -u2 "cl_stop: $name — pid $pid is gone or no longer $bin, leaving it alone"
    command rm -f "$pidfile"
    return 0
  fi

  kill "$pid" 2>/dev/null
  local waited=0
  while (( waited < 10 )) && _cl_pid_is_ours "$pid" "$bin"; do
    sleep 1
    (( waited++ ))
  done

  if _cl_pid_is_ours "$pid" "$bin"; then
    print -u2 "cl_stop: $name — pid $pid ignored SIGTERM; stop it by hand"
    return 1
  fi
  command rm -f "$pidfile"
  print -u2 "cl_stop: stopped $name (was pid $pid)"
}

# Stop backend services. Only ever touches processes this launcher started —
# a proxy you run yourself has no pid file and is never signalled.
cl_stop() {
  local rc=0 f
  if [[ "$1" == "--all" ]]; then
    # Driven by the pid files, not the profile list: a service outlives the
    # deletion of the profile that started it.
    for f in "$_CL_RUN_DIR"/*.pid(N); do
      _cl_stop_one "${${f:t}:r}" || rc=1
    done
    return $rc
  fi
  _cl_stop_one "${1:-$(_cl_get_profile)}"
}

# Show every backend, its label, and whether it looks ready to use.
cl_profiles() {
  local current name file label token svc
  current=$(_cl_get_profile)
  for name in $(_cl_list_profiles); do
    file=$(_cl_profile_file "$name")
    label=$(_cl_profile_label "$file")
    [[ -z "$label" ]] && label="$name"

    local marker=" "
    [[ "$name" == "$current" ]] && marker="*"

    local state="ready"
    if [[ -n "$file" ]] && command -v jq >/dev/null 2>&1; then
      token=$(jq -r '(.env // .).ANTHROPIC_AUTH_TOKEN // empty' "$file" 2>/dev/null)
      if [[ "$token" == YOUR_* ]]; then
        state="needs credential — edit $file"
      else
        svc=$(jq -r '.service.health // empty' "$file" 2>/dev/null)
        if [[ -n "$svc" ]]; then
          if _cl_service_healthy "$svc"; then
            state="ready (service up)"
          else
            state="ready (service starts on first use)"
          fi
        fi
      fi
    fi
    printf '%s %-8s %-58s %s\n' "$marker" "$name" "$label" "$state"
  done
  print -u2 ""
  print -u2 "* = default. Change with: cl_switch <name>"
}

# Bring up the local proxy a profile depends on, if it declares one.
# Returns non-zero (and explains what to run) when it cannot.
_cl_ensure_service() {
  local file="$1" tag="$2" name="$3"
  command -v jq >/dev/null 2>&1 || return 0

  local health
  health=$(jq -r '.service.health // empty' "$file" 2>/dev/null)
  [[ -z "$health" ]] && return 0

  local svc_label timeout
  svc_label=$(jq -r '.service.label // "backend service"' "$file" 2>/dev/null)
  timeout=$(jq -r '.service.timeoutSec // 25' "$file" 2>/dev/null)

  if _cl_service_healthy "$health"; then
    print -u2 "$tag: $svc_label already running"
    return 0
  fi

  local lockdir="$_CL_RUN_DIR/$name.lock"
  if ! _cl_lock_acquire "$lockdir"; then
    print -u2 "$tag: another shell is starting $svc_label, waiting ..."
    local waited
    if waited=$(_cl_wait_healthy "$health" "$timeout"); then
      print -u2 "$tag: $svc_label up after ${waited}s"
      return 0
    fi
    print -u2 "$tag: ERROR — $svc_label did not become healthy within ${timeout}s"
    return 1
  fi

  local rc
  {
    _cl_start_service "$file" "$tag" "$name" "$health" "$svc_label" "$timeout"
    rc=$?
  } always {
    _cl_lock_release "$lockdir"
  }
  return $rc
}

# The locked half of _cl_ensure_service: resolve the binary, spawn it, record
# the pid so cl_stop can find it, and wait for the health endpoint.
_cl_start_service() {
  local file="$1" tag="$2" name="$3" health="$4" svc_label="$5" timeout="$6"

  # The shell that lost the lock race may have finished the start for us.
  if _cl_service_healthy "$health"; then
    print -u2 "$tag: $svc_label already running"
    return 0
  fi

  local bin hint
  bin=$(_cl_service_bin "$file")

  if [[ -z "$bin" ]]; then
    print -u2 "$tag: ERROR — $svc_label is not installed"
    hint=$(jq -r '.service.installHint // empty' "$file" 2>/dev/null)
    [[ -n "$hint" ]] && print -u2 "$tag:   install it with:  $hint"
    hint=$(jq -r '.service.loginHint // empty' "$file" 2>/dev/null)
    [[ -n "$hint" ]] && print -u2 "$tag:   then authorize:   ${hint//\{bin\}/<binary>}"
    return 1
  fi

  local start_tpl
  start_tpl=$(jq -r '.service.start // empty' "$file" 2>/dev/null)
  if [[ -z "$start_tpl" ]]; then
    print -u2 "$tag: ERROR — $svc_label is down and the profile declares no start command"
    return 1
  fi

  local log_name log_file
  log_name=$(jq -r '.service.logName // "backend.log"' "$file" 2>/dev/null)
  log_file="$HOME/.claude/logs/$log_name"
  mkdir -p "${log_file:h}"

  print -u2 "$tag: starting $svc_label ..."
  nohup sh -c "${start_tpl//\{bin\}/$bin}" >>"$log_file" 2>&1 &
  local pid=$!
  disown 2>/dev/null

  command mkdir -p "$_CL_RUN_DIR"
  print -l -- "$pid" "$bin" > "$_CL_RUN_DIR/$name.pid"

  local waited
  if waited=$(_cl_wait_healthy "$health" "$timeout"); then
    print -u2 "$tag: $svc_label up after ${waited}s (pid $pid, stop with: cl_stop $name)"
    return 0
  fi

  print -u2 "$tag: ERROR — $svc_label did not become healthy within ${timeout}s"
  print -u2 "$tag:   log: $log_file"
  [[ -s "$log_file" ]] && tail -n 5 "$log_file" >&2
  hint=$(jq -r '.service.loginHint // empty' "$file" 2>/dev/null)
  [[ -n "$hint" ]] && print -u2 "$tag:   not authorized yet? run:  ${hint//\{bin\}/$bin}"
  return 1
}

# A reachable service only proves the process is up, not that the backend is
# authorized — an un-logged-in proxy answers /healthz happily. A placeholder
# credential is the usual cause, and failing here beats failing inside Claude
# Code. Profiles with no credentials at all (native "claude") are unaffected.
_cl_check_credentials() {
  local file="$1" tag="$2" token
  token=$(jq -r '(.env // .).ANTHROPIC_AUTH_TOKEN // empty' "$file" 2>/dev/null)
  [[ "$token" != YOUR_* ]] && return 0

  print -u2 "$tag: ERROR — ANTHROPIC_AUTH_TOKEN is still the placeholder '$token'"
  print -u2 "$tag:   edit $file"
  local hint bin
  hint=$(jq -r '.service.loginHint // empty' "$file" 2>/dev/null)
  if [[ -n "$hint" ]]; then
    bin=$(_cl_service_bin "$file") || bin="<binary>"
    print -u2 "$tag:   authorize first:  ${hint//\{bin\}/$bin}"
  fi
  return 1
}

# Emit "KEY=VALUE" lines for a profile. Supports both the nested {env:{...}}
# schema and the legacy flat glm-env.json where every top-level key is a var.
# map() forces the whole object through before anything is printed, so a
# non-scalar value fails the profile outright instead of silently truncating
# the environment at the offending key.
_cl_profile_env_pairs() {
  jq -r '
    (if (.env | type) == "object"
      then .env
      else with_entries(select(.key | test("^(label|note|credentialKeys|service|unset|env)$") | not))
     end)
    | to_entries
    | map((.value | type) as $t
          | if $t == "array" or $t == "object"
            then error("\(.key) has type \($t); env values must be strings, numbers or booleans")
            else "\(.key)=\(.value)"
            end)
    | .[]
  ' "$1" 2>&1
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

# Save/restore of the vars a profile touches. Saved values carry a one-character
# marker: "s" followed by the old value, or a bare "u" when the var was unset.
# Without the marker a var whose value is literally the sentinel would be
# wrongly unset on the way out.
#
# Both helpers reach _saved_env through zsh's dynamic scoping — it is the local
# of _cl_profile_run, which is the only caller.
_cl_save_var() {
  local key="$1"
  # Never overwrite an earlier snapshot: `unset[]` may have captured this key.
  [[ -n "${_saved_env[$key]+set}" ]] && return
  if [[ -n "${(P)key+set}" ]]; then
    _saved_env[$key]="s${(P)key}"
  else
    _saved_env[$key]=u
  fi
}

_cl_restore_env() {
  local key saved
  for key in "${(@k)_saved_env}"; do
    saved="${_saved_env[$key]}"
    if [[ "$saved" == u ]]; then
      unset "$key"
    else
      export "$key=${saved#s}"
    fi
  done
  _saved_env=()
}

# Run Claude Code under a named backend: start its service if needed, inject its
# env for the duration of the call, then restore the environment exactly.
_cl_profile_run() {
  local name="$1"
  local tag="$2"
  local skip_permissions="$3"
  shift 3

  local file
  file=$(_cl_profile_file "$name")

  # "claude" with no profile file on disk is the plain native path.
  if [[ -z "$file" ]]; then
    if [[ "$name" == "claude" ]]; then
      _cl_run "$tag" "$skip_permissions" "$@"
      return $?
    fi
    print -u2 "$tag: ERROR — no profile named '$name' in $_CL_PROFILE_DIR"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    print -u2 "$tag: ERROR — jq is required but not found"
    return 1
  fi

  _cl_ensure_service "$file" "$tag" "$name" || return 1
  _cl_check_credentials "$file" "$tag" || return 1

  # Read and validate the whole environment before touching anything, so a
  # malformed profile aborts with the shell untouched.
  local pairs
  if ! pairs=$(_cl_profile_env_pairs "$file"); then
    print -u2 "$tag: ERROR — malformed profile $file"
    print -u2 "$tag:   ${pairs//$'\n'/$'\n'"$tag:   "}"
    return 1
  fi

  setopt local_options local_traps

  local -A _saved_env
  local key val

  # Vars this profile explicitly clears (e.g. the native Claude profile wiping a
  # gateway URL that leaked in from .zshrc).
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    _cl_save_var "$key"
    unset "$key"
  done < <(jq -r '.unset[]? // empty' "$file" 2>/dev/null)

  local injected=0
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    _cl_save_var "$key"
    export "$key=$val"
    (( injected++ ))
  done <<< "$pairs"

  if (( injected > 0 )); then
    local endpoint
    endpoint=$(jq -r '(.env // .).ANTHROPIC_BASE_URL // "native"' "$file" 2>/dev/null)
    print -u2 "$tag: backend '$name' ($endpoint)"
  fi

  # `always` covers every normal and failing return path; the traps cover a
  # signal arriving while claude runs, which would otherwise leave the backend's
  # token exported in this shell and silently redirect other Anthropic tooling.
  # Each trap re-raises the default action so signal semantics are unchanged.
  local sig
  for sig in TERM HUP; do
    trap "_cl_restore_env; trap - $sig; kill -$sig \$\$" $sig
  done

  local rc
  {
    _cl_run "$tag" "$skip_permissions" "$@"
    rc=$?
  } always {
    _cl_restore_env
  }

  return $rc
}

# Main entry point — routes based on default profile
cl() {
  _ensure_permissions_enabled
  _cl_profile_run "$(_cl_get_profile)" "cl" "false" "$@"
}

# Auto mode — routes based on default profile
cl_auto() {
  _cl_profile_run "$(_cl_get_profile)" "cl_auto" "true" "$@"
}

# Generate cl_<name> / cl_<name>_auto for every profile on disk.
() {
  local _p _fn
  for _p in $(_cl_list_profiles); do
    _fn="${_p//[^a-zA-Z0-9_]/_}"
    # This loop runs after cl_switch/cl_stop/cl_profiles are defined, so an
    # unlucky profile name would silently replace a core command.
    if (( ${_CL_RESERVED_NAMES[(Ie)$_fn]} )); then
      print -u2 "cl: skipping profile '$_p' — cl_${_fn} is a built-in command"
      continue
    fi
    eval "cl_${_fn}() { _ensure_permissions_enabled; _cl_profile_run ${(qq)_p} 'cl_${_fn}' 'false' \"\$@\"; }"
    eval "cl_${_fn}_auto() { _cl_profile_run ${(qq)_p} 'cl_${_fn}_auto' 'true' \"\$@\"; }"
  done
}

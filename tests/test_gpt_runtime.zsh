#!/usr/bin/env zsh
# ============================================================
# test_gpt_runtime.zsh — Task 3 runtime diagnostics.
#
# Exercises the three Task-3 contracts in claude.zsh:
#   1. profiles/gpt.json declares .service.configFile metadata.
#   2. _cl_check_service_config <profile> -> 0|1 (fast prerequisite check).
#   3. _cl_start_service detects an early-exiting child before the full
#      health timeout, and gates the login hint on explicit auth evidence
#      via _cl_log_has_auth_failure <log> -> 0|1.
#
# Hermetic: temporary HOME, no real proxy, no real network, no real user
# config. A background watchdog kills any runaway path so a regression
# that reintroduces the 25-second wait cannot stall CI.
# ============================================================
setopt extended_glob null_glob

PASS=0
FAIL=0

DIR="${0:A:h}"

# ------------------------------------------------------------------
# Minimal assert helpers (kept local; the suite is self-contained).
# ------------------------------------------------------------------
_pass() { print -- "PASS: $1"; PASS=$((PASS + 1)); }
_fail() { print -- "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" == "$b" ]]; then _pass "$desc"; else _fail "$desc (got '$a' want '$b')"; fi
}
assert_ne() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" != "$b" ]]; then _pass "$desc"; else _fail "$desc (both '$a')"; fi
}
assert_match() {
  local desc="$1" pat="$2" str="$3"
  if [[ "$str" == $~pat* ]] || print -- "$str" | grep -qE "$pat"; then
    _pass "$desc"
  else
    _fail "$desc (no match for /$pat/ in '$str')"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then _pass "$desc"; else _fail "$desc (missing '$needle')"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then _fail "$desc (unexpected '$needle')"; else _pass "$desc"; fi
}
assert_returns_within() {
  # <desc> <max_seconds> <command...>
  local desc="$1"; shift
  local max="$1"; shift
  local start end
  start=$(/bin/date +%s)
  "$@"
  local rc=$?
  end=$(/bin/date +%s)
  if (( end - start > max )); then
    _fail "$desc (took $((end - start))s, limit ${max}s)"
    return 1
  fi
  if (( rc == 0 )); then _pass "$desc (rc=0 in $((end - start))s)"; else _fail "$desc (rc=$rc)"; fi
  return $rc
}

# ------------------------------------------------------------------
# Hermetic harness: temp HOME, source claude.zsh fresh per group.
# ------------------------------------------------------------------
setup_home() {
  TMP=$(/usr/bin/mktemp -d)
  HOME="$TMP"
  mkdir -p "$HOME/.claude/profiles" "$HOME/.claude/logs" "$HOME/.claude/run"
}
teardown_home() { [[ -n "$TMP" && -d "$TMP" ]] && /bin/rm -rf "$TMP"; }

# Source claude.zsh under the current (temp) HOME so $_CL_* resolve there.
# Stub _cl_service_healthy so no curl/network is touched: always unhealthy,
# returning instantly. Individual tests override when they need a hit.
source_with_stubs() {
  _cl_service_healthy() { return 1; }
  source "$DIR/../claude.zsh"
}

# Run a snippet in a background subshell, kill it past a deadline, and
# report the wall-clock seconds. Echoes "<seconds> <rc>" on stdout so the
# caller can assert on both. Refuses to let a regression stall the suite.
run_under_watchdog() {
  local deadline="$1"; shift
  local outfile="$1"; shift
  local start end pid waited rc
  start=$(/bin/date +%s)
  ( eval "$@" ) >"$outfile" 2>&1 &
  pid=$!
  waited=0
  while (( waited < deadline )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    (( waited++ ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    end=$(/bin/date +%s)
    print -- "$((end - start)) TIMEOUT"
    return 1
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  end=$(/bin/date +%s)
  print -- "$((end - start)) $rc"
  return $rc
}

# ==================================================================
# Group 1: metadata + missing-config prerequisite
# ==================================================================
setup_home
source_with_stubs

# --- Repo profile metadata ---
REPO_GPT="$DIR/../profiles/gpt.json"
if [[ -f "$REPO_GPT" ]]; then
  cf=$(jq -r '.service.configFile // empty' "$REPO_GPT" 2>/dev/null)
  assert_ne "repo profiles/gpt.json declares service.configFile" "$cf" ""
  assert_contains "configFile points at CLIProxyAPI config path" '$HOME/.cli-proxy-api/config.yaml' "$cf"
else
  _fail "repo profiles/gpt.json exists for metadata check"
fi

# --- Prerequisite check: success path (file present & readable) ---
cfg_present="$TMP/present.json"
cat > "$cfg_present" <<'JSON'
{
  "service": {
    "label": "StubProxy",
    "configFile": "$HOME/.cli-proxy-api/config.yaml"
  }
}
JSON
mkdir -p "$HOME/.cli-proxy-api"
: > "$HOME/.cli-proxy-api/config.yaml"
assert_returns_within "readable declared config -> rc=0 (<1s)" 1 _cl_check_service_config "$cfg_present"
rc=$?
if (( rc == 0 )); then
  assert_eq "no output on success path" "$(_cl_check_service_config "$cfg_present" 2>/dev/null | tr -d '\n')" ""
fi

# --- Prerequisite check: missing path -> rc=1, <1s, expanded path + repair ---
cfg_missing="$TMP/missing.json"
cat > "$cfg_missing" <<'JSON'
{
  "service": {
    "label": "StubProxy",
    "configFile": "$HOME/.cli-proxy-api/config.yaml"
  }
}
JSON
rm -f "$HOME/.cli-proxy-api/config.yaml"
err=$(assert_returns_within "missing declared config -> rc=1 (<1s)" 1 _cl_check_service_config "$cfg_missing" 2>&1 >/dev/null)
expanded="$HOME/.cli-proxy-api/config.yaml"
# Re-run capturing stderr for content assertions.
out=$(_cl_check_service_config "$cfg_missing" 2>&1 >/dev/null)
assert_contains "error names the expanded path" "$expanded" "$out"
assert_contains "error gives a repair instruction" "installer" "$out"
assert_not_contains "missing-config error omits 'not authorized'" "not authorized" "$out"
assert_not_contains "missing-config error omits 'codex-login'" "codex-login" "$out"
assert_not_contains "missing-config error omits 25s timeout message" "25s" "$out"

# --- Prerequisite check: unreadable (exists but -r fails) -> rc=1 ---
if [[ "$(id -u)" != "0" ]]; then
  : > "$HOME/.cli-proxy-api/config.yaml"
  chmod 000 "$HOME/.cli-proxy-api/config.yaml"
  out=$(_cl_check_service_config "$cfg_present" 2>&1 >/dev/null); rc=$?
  assert_eq "unreadable declared config -> rc=1" "$rc" "1"
  chmod 600 "$HOME/.cli-proxy-api/config.yaml"
else
  _pass "unreadable declared config -> rc=1 (skipped under root)"
fi

# --- Prerequisite check: tilde expansion form ---
cfg_tilde="$TMP/tilde.json"
cat > "$cfg_tilde" <<'JSON'
{ "service": { "configFile": "~/.cli-proxy-api/config.yaml" } }
JSON
rm -f "$HOME/.cli-proxy-api/config.yaml"
out=$(_cl_check_service_config "$cfg_tilde" 2>&1 >/dev/null)
assert_contains "tilde form expands to HOME" "$expanded" "$out"

# --- Prerequisite check: profile WITHOUT configFile -> rc=0 (CCR unaffected) ---
cfg_none="$TMP/none.json"
cat > "$cfg_none" <<'JSON'
{ "service": { "label": "CCR", "health": "http://127.0.0.1:9/x" } }
JSON
assert_returns_within "no configFile declared -> rc=0 (CCR unaffected)" 1 _cl_check_service_config "$cfg_none"

# --- No eval injection via configFile value ---
# A malicious or accidental "$(...)" / backtick in configFile must NEVER be
# executed. Use a side-effect marker: if expansion happened, the marker file
# would exist. The literal text should also appear verbatim in the message.
_marker="$TMP/pwned-marker"
/bin/rm -f "$_marker"
cfg_inject="$TMP/inject.json"
cat > "$cfg_inject" <<JSON
{ "service": { "configFile": "\$(touch $_marker)/x" } }
JSON
out=$(_cl_check_service_config "$cfg_inject" 2>&1 >/dev/null)
if [[ -e "$_marker" ]]; then
  _fail "command substitution in configFile is not evaluated (marker file created)"
else
  _pass "command substitution in configFile is not evaluated"
fi
assert_contains "raw \$(...) value reported literally" '$(touch' "$out"

teardown_home

# ==================================================================
# Group 2: early process-exit detection + evidence-based login hint
# ==================================================================
setup_home
source_with_stubs

# Build a profile whose start command exits immediately. health stays
# unreachable (stub), so a regression to the full _cl_wait_healthy path
# would block ~25 seconds and trip the watchdog.
exit_profile="$TMP/exit.json"
cat > "$exit_profile" <<'JSON'
{
  "service": {
    "label": "StubProxy",
    "health": "http://127.0.0.1:1/healthz",
    "bins": ["true"],
    "start": "exit 1",
    "timeoutSec": 25,
    "logName": "stub.log",
    "loginHint": "{bin} --codex-login    # authorize"
  }
}
JSON

# Drive _cl_start_service under a watchdog. Must return rc=1 within 3s.
res=$(run_under_watchdog 6 "$TMP/early.out" \
  "_cl_start_service '$exit_profile' TAG stub 'http://127.0.0.1:1/healthz' StubProxy 25")
secs=${res%% *}
tag=${res##* }
if [[ "$tag" == "TIMEOUT" ]]; then
  _fail "early-exit returns within 3s (watchdog tripped at ${secs}s)"
else
  assert_eq "early-exit rc is non-zero (failure reported)" "$tag" "1"
  if (( secs <= 3 )); then
    _pass "early-exit returns within 3s (${secs}s)"
  else
    _fail "early-exit returns within 3s (took ${secs}s)"
  fi
fi
early_out=$(<"$TMP/early.out")
assert_contains "early-exit reports the log file path" "log:" "$early_out"
# The stub start writes nothing to the log, so it is empty -> no auth
# evidence -> login hint MUST NOT appear.
assert_not_contains "early-exit omits login hint without auth evidence" "codex-login" "$early_out"
assert_not_contains "early-exit omits 'not authorized' without evidence" "not authorized" "$early_out"

# --- _cl_log_has_auth_failure predicate (pure, on a log file) ---

mk_log() { print -r -- "$1" > "$TMP/probe.log"; }

mk_log "401 Unauthorized -- refresh your OAuth token"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "log with 401 -> auth failure detected" "$?" "0"

mk_log "403 forbidden for this account"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "log with 403 -> auth failure detected" "$?" "0"

mk_log "build 1401 completed; port 4030 ready"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "401/403 digit substrings are not auth failures" "$?" "1"

mk_log "oauth provider initialized"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "bare oauth provider is not auth failure" "$?" "1"

mk_log "oauth token expired; login required"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "log with oauth/login required -> auth failure detected" "$?" "0"

mk_log "no codex credentials found"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "log with 'no codex credentials' -> auth failure detected" "$?" "0"

mk_log "failed to read config file: /home/x/.cli-proxy-api/config.yaml"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "config-file error NOT classified as auth failure" "$?" "1"

mk_log "dial tcp connection refused"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "connection refused NOT classified as auth failure" "$?" "1"

mk_log ""; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "empty log NOT classified as auth failure" "$?" "1"

# Substring-trap guards: lines that contain 'auth'/'token'/'codex' but no
# explicit auth-failure phrase must NOT match (brief Step 7).
mk_log "loading auth middleware"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "bare 'auth middleware' NOT classified as auth failure" "$?" "1"

mk_log "token cache initialized"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "bare 'token cache' NOT classified as auth failure" "$?" "1"

mk_log "codex provider registered"; _cl_log_has_auth_failure "$TMP/probe.log"
assert_eq "bare 'codex provider' NOT classified as auth failure" "$?" "1"

teardown_home

# ==================================================================
# Group 3: login hint surfaces ONLY with explicit auth evidence
# ==================================================================
setup_home
source_with_stubs

# Reuse the early-exit profile, but pre-seed the log with 401 evidence so
# the failure path should now print the login hint.
auth_profile="$TMP/auth.json"
cat > "$auth_profile" <<'JSON'
{
  "service": {
    "label": "StubProxy",
    "health": "http://127.0.0.1:1/healthz",
    "bins": ["true"],
    "start": "sh -c 'echo 401 Unauthorized -- re-login; exit 1'",
    "timeoutSec": 25,
    "logName": "auth.log",
    "loginHint": "{bin} --codex-login    # authorize"
  }
}
JSON
: > "$HOME/.claude/logs/auth.log"  # exists; the stub start writes to it

res=$(run_under_watchdog 6 "$TMP/auth.out" \
  "_cl_start_service '$auth_profile' TAG stub 'http://127.0.0.1:1/healthz' StubProxy 25")
secs=${res%% *}; tag=${res##* }
assert_eq "auth-evidence early-exit rc is non-zero" "${tag##* }" "1"
auth_out=$(<"$TMP/auth.out")
assert_contains "login hint appears with 401 evidence" "codex-login" "$auth_out"
assert_contains "tail of log is printed on failure" "401 Unauthorized" "$auth_out"

teardown_home

# ==================================================================
# Group 4: only log bytes appended by this launch affect auth hints
# ==================================================================
setup_home
source_with_stubs

history_profile="$TMP/history.json"
cat > "$history_profile" <<'JSON'
{
  "service": {
    "label": "StubProxy",
    "health": "http://127.0.0.1:1/healthz",
    "bins": ["true"],
    "start": "sh -c 'echo dial tcp connection refused; exit 1'",
    "timeoutSec": 25,
    "logName": "history.log",
    "loginHint": "{bin} --codex-login"
  }
}
JSON
print -- '401 Unauthorized from an old launch' > "$HOME/.claude/logs/history.log"
res=$(run_under_watchdog 6 "$TMP/history.out" \
  "_cl_start_service '$history_profile' TAG stub 'http://127.0.0.1:1/healthz' StubProxy 25")
history_out=$(<"$TMP/history.out")
assert_not_contains "historical 401 does not trigger current login hint" "codex-login" "$history_out"

current_oauth_profile="$TMP/current-oauth.json"
cat > "$current_oauth_profile" <<'JSON'
{
  "service": {
    "label": "StubProxy",
    "health": "http://127.0.0.1:1/healthz",
    "bins": ["true"],
    "start": "sh -c 'echo OAuth token expired, login required; exit 1'",
    "timeoutSec": 25,
    "logName": "current-oauth.log",
    "loginHint": "{bin} --codex-login"
  }
}
JSON
print -- 'ordinary historical startup' > "$HOME/.claude/logs/current-oauth.log"
res=$(run_under_watchdog 6 "$TMP/current-oauth.out" \
  "_cl_start_service '$current_oauth_profile' TAG stub 'http://127.0.0.1:1/healthz' StubProxy 25")
current_oauth_out=$(<"$TMP/current-oauth.out")
assert_contains "current OAuth failure triggers login hint" "codex-login" "$current_oauth_out"

teardown_home

# ==================================================================
print -- "----"
print -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))

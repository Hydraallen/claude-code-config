#!/usr/bin/env bash
# ============================================================
# Unit + integration tests for scripts/image-gen-cliproxyapi.sh.
#
# Covers (Tasks 1-3 + reviewer fix rounds):
#   - image_gen_find_binary / parse_version / version_at_least
#   - image_gen_has_prerelease / image_gen_version_meets_floor (reject all rc)
#   - image_gen_read_binary_version (--help / -h bounded probe; never `version`)
#   - image_gen_extract_config_key (closed inline lists; malformed rejected)
#   - image_gen_service_healthy / image_gen_service_ready (auth capability)
#   - image_gen_wait_ready / image_gen_start_service (no PID on error path)
#   - image_gen_main diagnostics, forwarding, child-only env, exit code,
#     capability probe (ready + no-OAuth), xtrace safety, direct invocation
#   - Local generation/edit protocol via mock + probe (image[] asserted)
#
# No real HOME, credentials, or external image APIs. PIDs started are recorded
# and killed individually (never pkill). Mocks bind 127.0.0.1 only.
# ============================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK="$DIR/tests/fixtures/mock_images_server.py"
WRAPPER="$DIR/scripts/image-gen-cliproxyapi.sh"

# shellcheck source=/dev/null
source "$WRAPPER"
set +euo pipefail

PASS=0
FAIL=0
PIDS=""
TMP=""
MOCK_ROOT=""
MOCK_PORT=""

cleanup() {
    local p
    for p in $PIDS; do kill "$p" >/dev/null 2>&1; done
    [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
}
trap cleanup EXIT
TMP="$(mktemp -d)"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "PASS: $desc"; PASS=$((PASS+1))
    else echo "FAIL: $desc"; echo "  expected: [$expected]"; echo "  actual:   [$actual]"; FAIL=$((FAIL+1)); fi
}
assert_return() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "PASS: $desc"; PASS=$((PASS+1))
    else echo "FAIL: $desc"; echo "  expected exit: $expected"; echo "  actual exit:   $actual"; FAIL=$((FAIL+1)); fi
}
assert_match() {
    local desc="$1" actual="$2" pattern="$3"
    if [[ "$actual" =~ $pattern ]]; then echo "PASS: $desc"; PASS=$((PASS+1))
    else echo "FAIL: $desc"; echo "  value [$actual] !~ /$pattern/"; FAIL=$((FAIL+1)); fi
}
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

free_port() {
    python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

# Start the mock in the PARENT shell (no command substitution) so PIDS is
# preserved. Sets globals MOCK_ROOT / MOCK_PORT. fds redirected so no pipe
# is held open. Optional: records file, expect-key, no-oauth flag.
start_mock() {
    local port_file="$1" records_file="${2:-}" expect_key="${3:-}" models_mode="${4:-normal}"
    local args=(--port 0 --port-file "$port_file")
    [[ -n "$records_file" ]] && args+=(--records-file "$records_file")
    [[ -n "$expect_key" ]]   && args+=(--expect-key "$expect_key")
    [[ -n "$models_mode" && "$models_mode" != "normal" ]] && args+=(--models-mode "$models_mode")
    : > "$port_file"
    python3 "$MOCK" "${args[@]}" > /dev/null 2>&1 &
    local pid=$!
    PIDS="$PIDS $pid"
    local i
    for ((i=0; i<100; i++)); do [[ -s "$port_file" ]] && break; sleep 0.05; done
    MOCK_PORT="$(cat "$port_file" 2>/dev/null)"
    MOCK_ROOT="http://127.0.0.1:${MOCK_PORT}"
}

# ===========================================================================
# Task 1: pure validation helpers
# ===========================================================================

# --- image_gen_find_binary (three names; missing) --------------------------
BIN_DIR="$TMP/bin"; mkdir -p "$BIN_DIR"
for name in cliproxyapi cli-proxy-api cliproxy-api; do
    printf '#!/usr/bin/env bash\necho fake-%s\n' "$name" > "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
done
out=$(PATH="$BIN_DIR:/usr/bin:/bin" image_gen_find_binary); rc=$?
assert_return "find_binary: exits 0 when a candidate exists" 0 "$rc"
assert_match "find_binary: returns cliproxyapi" "$out" '/cliproxyapi$'
rm "$BIN_DIR/cliproxyapi"
out=$(PATH="$BIN_DIR:/usr/bin:/bin" image_gen_find_binary); rc=$?
assert_return "find_binary: falls back to second candidate" 0 "$rc"
assert_match "find_binary: second candidate" "$out" '/cli-proxy-api$'
rm "$BIN_DIR/cli-proxy-api"
out=$(PATH="$BIN_DIR:/usr/bin:/bin" image_gen_find_binary); rc=$?
assert_return "find_binary: falls back to third candidate" 0 "$rc"
assert_match "find_binary: third candidate" "$out" '/cliproxy-api$'
rm "$BIN_DIR/cliproxy-api"
out=$(PATH="$BIN_DIR:/usr/bin:/bin" image_gen_find_binary 2>/dev/null); rc=$?
assert_return "find_binary: missing exits 1" 1 "$rc"
assert_eq     "find_binary: missing prints nothing" "" "$out"

# --- image_gen_parse_version -----------------------------------------------
for raw in "7.2.17" "v7.2.17" "7.2.17-rc1" "7.2.17+meta" \
           "cliproxyapi 7.2.17" "cliproxyapi version 7.2.17" \
           "CLIProxyAPI v7.2.17 (darwin-arm64)"; do
    out=$(image_gen_parse_version "$raw"); rc=$?
    assert_return "parse_version: [$raw] exits 0" 0 "$rc"
    assert_eq     "parse_version: [$raw] -> 7.2.17" "7.2.17" "$out"
done
out=$(image_gen_parse_version "not-a-version" 2>/dev/null); rc=$?
assert_return "parse_version: malformed exits 1" 1 "$rc"
assert_eq     "parse_version: malformed prints nothing" "" "$out"
out=$(image_gen_parse_version "" 2>/dev/null); rc=$?
assert_return "parse_version: empty exits 1" 1 "$rc"
out=$(image_gen_parse_version "7.2"); rc=$?
assert_return "parse_version: two-component exits 0" 0 "$rc"
assert_eq     "parse_version: two-component -> 7.2.0" "7.2.0" "$out"

# --- image_gen_version_at_least (pure numeric core; suffix ignored) --------
assert_return "version_at_least: 7.2.17 >= 7.2.17" 0 "$(image_gen_version_at_least 7.2.17 7.2.17; echo $?)"
assert_return "version_at_least: 8.0.0 > 7.2.17"   0 "$(image_gen_version_at_least 8.0.0 7.2.17; echo $?)"
assert_return "version_at_least: 7.2.16 < 7.2.17"  1 "$(image_gen_version_at_least 7.2.16 7.2.17; echo $?)"
assert_return "version_at_least: 7.2.17-rc1 numeric-core >= 7.2.17" 0 "$(image_gen_version_at_least 7.2.17-rc1 7.2.17; echo $?)"

# --- image_gen_has_prerelease / meets_floor (policy: ANY hyphen suffix) ----
# Any non-empty hyphen suffix is a prerelease; build metadata +meta is stable.
for v in "7.2.17-rc1" "8.0.0-beta2" "9.0.0-alpha" "7.2.17-foo" "7.2.17-canary" \
         "7.2.17-milestone" "8.0.0-0" "7.2.17-x.y.z" "10.0.0-dev.3"; do
    assert_return "has_prerelease: $v" 0 "$(image_gen_has_prerelease "$v"; echo $?)"
done
for v in "7.2.17" "7.2.17+meta" "7.2.17+meta-dash" "9.0.0" "7.2"; do
    assert_return "has_prerelease: $v (stable)" 1 "$(image_gen_has_prerelease "$v"; echo $?)"
done

assert_return "meets_floor: 7.2.17 stable accepted"        0 "$(image_gen_version_meets_floor 7.2.17 7.2.17; echo $?)"
assert_return "meets_floor: 9.0.0 stable accepted"         0 "$(image_gen_version_meets_floor 9.0.0 7.2.17; echo $?)"
assert_return "meets_floor: 7.2.17+meta stable accepted"   0 "$(image_gen_version_meets_floor 7.2.17+meta 7.2.17; echo $?)"
for v in "7.2.17-rc1" "7.2.18-rc1" "8.0.0-beta" "7.2.17-foo" "7.2.17-canary" \
         "9.0.0-milestone" "8.0.0-1"; do
    assert_return "meets_floor: $v REJECTED (prerelease)" 1 "$(image_gen_version_meets_floor "$v" 7.2.17; echo $?)"
done
assert_return "meets_floor: 7.2.16 stable rejected (old)"  1 "$(image_gen_version_meets_floor 7.2.16 7.2.17; echo $?)"

# --- image_gen_read_binary_version -----------------------------------------
# REGRESSION (2026-08-02): the real CLIProxyAPI binary, when invoked as
# `cliproxyapi version`, STARTS THE SERVER AND NEVER EXITS (hangs the
# wrapper indefinitely). `--version` prints the version but exits 2; only
# `--help` / `-h` print the version banner AND exit 0. The probe MUST
# therefore prefer `--help` then `-h`, NEVER the bare `version` subcommand,
# and MUST bound each probe so a hanging binary cannot wedge us.
#
# (1) Real-style fake: `--help`/`-h` print an actual-style banner; the
#     `version` subcommand is a trap that records it was called and sleeps.
FAKE_BIN="$TMP/fakever"
FORBID_FLAG="$TMP/fakever-forbidden.flag"
cat > "$FAKE_BIN" <<SH
#!/usr/bin/env bash
case "\$1" in
  version)
    echo "FORBIDDEN-CALLED" > "$FORBID_FLAG"
    exec sleep 600
    ;;
  --help|-h)
    echo "CLIProxyAPI Version: 7.5.0 (darwin-arm64, commit abc123)"
    exit 0
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKE_BIN"
rm -f "$FORBID_FLAG"
t0=$(date +%s)
out=$(image_gen_read_binary_version "$FAKE_BIN"); rc=$?
t1=$(date +%s)
assert_return "read_version: real-style --help exits 0" 0 "$rc"
assert_eq     "read_version: parsed 7.5.0" "7.5.0" "$out"
# Must return promptly (well under the trap's 600s sleep); 15s is generous.
if [[ $((t1-t0)) -le 15 ]]; then pass "read_version: returns promptly (no hang)"; else fail "read_version: hung ($((t1-t0))s)"; fi
# The forbidden `version` subcommand MUST NEVER be invoked.
if [[ -e "$FORBID_FLAG" ]]; then fail "read_version: invoked forbidden 'version' subcommand"; else pass "read_version: never invoked 'version' subcommand"; fi

# (2) `-h` fallback when `--help` is unsupported.
FAKE_BIN2="$TMP/fakedash"
cat > "$FAKE_BIN2" <<'SH'
#!/usr/bin/env bash
case "$1" in --help) exit 2 ;; -h) echo "CLIProxyAPI Version: 8.0.1"; exit 0 ;; *) exit 2 ;; esac
SH
chmod +x "$FAKE_BIN2"
out=$(image_gen_read_binary_version "$FAKE_BIN2"); rc=$?
assert_return "read_version: -h fallback exits 0" 0 "$rc"
assert_eq     "read_version: -h fallback parsed" "8.0.1" "$out"

# (3) Bounded timeout: BOTH `--help` and `-h` hang. Probe MUST return within
#     a bounded window (not hang) and exit 1, without pkill. We record the
#     child PID the fake spawns and confirm ONLY that child is reaped.
FAKE_HANG="$TMP/fakehang"
HANG_PIDFILE="$TMP/fakehang.pid"
cat > "$FAKE_HANG" <<SH
#!/usr/bin/env bash
echo \$\$ > "$HANG_PIDFILE"
exec sleep 600
SH
chmod +x "$FAKE_HANG"
rm -f "$HANG_PIDFILE"
t0=$(date +%s)
out=$(image_gen_read_binary_version "$FAKE_HANG" 2>/dev/null); rc=$?
t1=$(date +%s)
assert_return "read_version: hanging binary exits 1" 1 "$rc"
assert_eq     "read_version: hanging binary prints nothing" "" "$out"
# Two probes (--help, -h) each bounded ~5s -> total must be well under 30s.
if [[ $((t1-t0)) -le 25 ]]; then pass "read_version: bounded timeout returns promptly"; else fail "read_version: bounded timeout too slow ($((t1-t0))s)"; fi
# Confirm the spawned child was reaped (no orphan) -- without pkill.
sleep 0.4
orphan="$(cat "$HANG_PIDFILE" 2>/dev/null)"
if [[ -n "$orphan" ]] && kill -0 "$orphan" 2>/dev/null; then
    fail "read_version: bounded timeout left an orphan pid ($orphan)"
    PIDS="$PIDS $orphan"
else
    pass "read_version: bounded timeout reaped its child (no orphan)"
fi

# (4) No parseable output anywhere -> exit 1, prints nothing.
FAKE_BAD="$TMP/fakebad"
cat > "$FAKE_BAD" <<'SH'
#!/usr/bin/env bash
echo "nothing parseable here"; exit 0
SH
chmod +x "$FAKE_BAD"
out=$(image_gen_read_binary_version "$FAKE_BAD" 2>/dev/null); rc=$?
assert_return "read_version: malformed exits 1" 1 "$rc"
assert_eq     "read_version: malformed prints nothing" "" "$out"

# --- image_gen_extract_config_key (closed inline lists; malformed rejected) ---
cfg="$TMP/k-block.yaml"; printf 'api-keys:\n  - "block-first"\n  - "block-second"\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg"); rc=$?
assert_return "extract_key: block exits 0" 0 "$rc"; assert_eq "extract_key: block first" "block-first" "$out"
cfg="$TMP/k-inline.yaml"; printf 'api-keys: ["inline-first", "inline-second"]\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg"); rc=$?
assert_return "extract_key: inline exits 0" 0 "$rc"; assert_eq "extract_key: inline first" "inline-first" "$out"
cfg="$TMP/k-bare.yaml"; printf 'api-keys:\n  - bare-scalar\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg"); rc=$?
assert_return "extract_key: bare exits 0" 0 "$rc"; assert_eq "extract_key: bare" "bare-scalar" "$out"
cfg="$TMP/k-empty.yaml"; printf 'api-keys: []\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: empty exits 1" 1 "$rc"; assert_eq "extract_key: empty prints nothing" "" "$out"
cfg="$TMP/k-comment.yaml"; printf 'api-keys:\n  - "real-key"   # note\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg"); rc=$?
assert_return "extract_key: comment exits 0" 0 "$rc"; assert_eq "extract_key: comment stripped" "real-key" "$out"
cfg="$TMP/k-nested.yaml"; printf 'profiles:\n  api-keys:\n    - nested-key\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: nested exits 1" 1 "$rc"; assert_eq "extract_key: nested prints nothing" "" "$out"
cfg="$TMP/k-placeholder.yaml"; printf 'api-keys:\n  - YOUR_CLIPROXYAPI_KEY\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: placeholder exits 1" 1 "$rc"
cfg="$TMP/k-anchor.yaml"; printf 'api-keys:\n  - &anchor real-key\n  - *anchor\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: anchor/alias exits 1" 1 "$rc"
cfg="$TMP/k-mapping.yaml"; printf 'api-keys:\n  - inner: value\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: mapping exits 1" 1 "$rc"
cfg="$TMP/k-flowmap.yaml"; printf 'api-keys:\n  - {}\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: flow mapping exits 1" 1 "$rc"
cfg="$TMP/k-control.yaml"; printf 'api-keys:\n  - "with\\ttab"\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: control char exits 1" 1 "$rc"
cfg="$TMP/k-whitespace.yaml"; printf 'api-keys:\n  - "   "\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: whitespace-only exits 1" 1 "$rc"
out=$(image_gen_extract_config_key "$TMP/nope.yaml" 2>/dev/null); rc=$?
assert_return "extract_key: missing file exits 1" 1 "$rc"
assert_eq     "extract_key: missing prints nothing" "" "$out"
# UNCLOSED inline list MUST be rejected.
cfg="$TMP/k-unclosed.yaml"; printf 'api-keys: [synthetic-key\n' > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: unclosed inline list exits 1" 1 "$rc"
assert_eq     "extract_key: unclosed inline prints nothing" "" "$out"
# Malformed quote inside inline list MUST be rejected.
cfg="$TMP/k-badquote.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["bad"value"]
YAML
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: malformed quote exits 1" 1 "$rc"

# Whole-list grammar: a valid FIRST item with a malformed LATER item MUST
# reject the entire list and emit NO key.
cfg="$TMP/k-m2.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["good-first", "bad"value"]
YAML
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: malformed 2nd item rejects list" 1 "$rc"
assert_eq     "extract_key: malformed 2nd prints nothing" "" "$out"
cfg="$TMP/k-m3.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["good", "also-good", bad"inner]
YAML
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: malformed 3rd (bare quote) rejects list" 1 "$rc"
assert_eq     "extract_key: malformed 3rd prints nothing" "" "$out"
cfg="$TMP/k-m4.yaml"
printf "api-keys: ['good', bad'inner]\n" > "$cfg"
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: unmatched single quote rejects list" 1 "$rc"
cfg="$TMP/k-m5.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["good" extra]
YAML
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: trailing material in item rejects list" 1 "$rc"
cfg="$TMP/k-m6.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["a"] junk
YAML
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: trailing material after ] rejects list" 1 "$rc"
cfg="$TMP/k-m7.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["a", ]
YAML
out=$(image_gen_extract_config_key "$cfg" 2>/dev/null); rc=$?
assert_return "extract_key: trailing empty item rejects list" 1 "$rc"
# Valid multi-item lists still parse.
cfg="$TMP/k-vmulti.yaml"
cat > "$cfg" <<'YAML'
api-keys: ["multi-first", "multi-second", bare-third]
YAML
out=$(image_gen_extract_config_key "$cfg"); rc=$?
assert_return "extract_key: valid mixed multi-item exits 0" 0 "$rc"
assert_eq     "extract_key: valid multi-item first returned" "multi-first" "$out"

# ===========================================================================
# Task 2: service lifecycle (liveness + capability)
# ===========================================================================

PORT_FILE="$TMP/port"
RECORDS_FILE="$TMP/records.json"
start_mock "$PORT_FILE" "$RECORDS_FILE"
HEALTH="$MOCK_ROOT/healthz"
IMG_BASE="$MOCK_ROOT/v1"

out=$(image_gen_service_healthy "$HEALTH" 2>/dev/null); rc=$?
assert_return "service_healthy: up exits 0" 0 "$rc"
out=$(image_gen_service_healthy "http://127.0.0.1:1/healthz" 2>/dev/null); rc=$?
assert_return "service_healthy: down exits 1" 1 "$rc"

t0=$(date +%s); image_gen_wait_ready "$HEALTH" 5 2>/dev/null; rc=$?; t1=$(date +%s)
assert_return "wait_ready: healthy exits 0" 0 "$rc"
[[ $((t1-t0)) -le 4 ]] && pass "wait_ready: healthy returns within timeout" || fail "wait_ready: too slow"
image_gen_wait_ready "http://127.0.0.1:1/healthz" 2 2>/dev/null; rc=$?
assert_return "wait_ready: unreachable exits 1" 1 "$rc"

# Capability probe (authenticated, EXACT data[].id == "gpt-image-2"). Main
# mock advertises gpt-image-2, so the probe passes.
out=$(image_gen_service_ready "$IMG_BASE" "any-key" 2>/dev/null); rc=$?
assert_return "service_ready: exact id gpt-image-2 exits 0" 0 "$rc"
# Substring-only id ("not-gpt-image-2") MUST be rejected (exact match).
SUB_PORT_FILE="$TMP/sub-port"
start_mock "$SUB_PORT_FILE" "" "" "substring"
out=$(image_gen_service_ready "$MOCK_ROOT/v1" "any-key" 2>/dev/null); rc=$?
assert_return "service_ready: substring id 'not-gpt-image-2' exits 1" 1 "$rc"
# id embedded in a different field MUST be rejected.
WF_PORT_FILE="$TMP/wf-port"
start_mock "$WF_PORT_FILE" "" "" "wrongfield"
out=$(image_gen_service_ready "$MOCK_ROOT/v1" "any-key" 2>/dev/null); rc=$?
assert_return "service_ready: id embedded in another field exits 1" 1 "$rc"
# Malformed JSON body MUST be rejected.
MJ_PORT_FILE="$TMP/mj-port"
start_mock "$MJ_PORT_FILE" "" "" "malformed"
out=$(image_gen_service_ready "$MOCK_ROOT/v1" "any-key" 2>/dev/null); rc=$?
assert_return "service_ready: malformed JSON exits 1" 1 "$rc"
# Non-array data MUST be rejected.
NA_PORT_FILE="$TMP/na-port"
start_mock "$NA_PORT_FILE" "" "" "nonarray"
out=$(image_gen_service_ready "$MOCK_ROOT/v1" "any-key" 2>/dev/null); rc=$?
assert_return "service_ready: non-array data exits 1" 1 "$rc"
# No gpt-image-2 at all (gpt-3.5-turbo only) MUST be rejected.
NOAUTH_PORT_FILE="$TMP/na2-port"; NOAUTH_RECORDS="$TMP/na2-records"
start_mock "$NOAUTH_PORT_FILE" "$NOAUTH_RECORDS" "" "no-oauth"
out=$(image_gen_service_ready "$MOCK_ROOT/v1" "any-key" 2>/dev/null); rc=$?
assert_return "service_ready: no gpt-image-2 exits 1" 1 "$rc"

# --- image_gen_start_service -----------------------------------------------
TRAP_BIN="$TMP/trap-bin"
cat > "$TRAP_BIN" <<'SH'
#!/usr/bin/env bash
echo "BINARY-WAS-STARTED" >&2; exit 1
SH
chmod +x "$TRAP_BIN"
CFG="$TMP/cfg.yaml"; printf 'api-keys:\n  - "synthetic-key"\n' > "$CFG"
LOG="$TMP/svc.log"
out=$(image_gen_start_service "$TRAP_BIN" "$CFG" "$LOG" "$HEALTH" 2>/dev/null); rc=$?
assert_return "start_service: healthy -> no start, exit 0" 0 "$rc"
assert_eq     "start_service: healthy -> nothing printed" "" "$out"
if [[ ! -f "$LOG" ]] || [[ "$(cat "$LOG" 2>/dev/null)" != *"BINARY-WAS-STARTED"* ]]; then
    pass "start_service: binary not invoked when healthy"
else
    fail "start_service: binary wrongly invoked"
fi

PORT2_FILE="$TMP/port2"; NEW_PORT=$(free_port)
SERVE_BIN="$TMP/serve-bin"
cat > "$SERVE_BIN" <<SH
#!/usr/bin/env bash
exec python3 "$MOCK" --port $NEW_PORT --port-file "$PORT2_FILE"
SH
chmod +x "$SERVE_BIN"
HEALTH2="http://127.0.0.1:${NEW_PORT}/healthz"
pid=$(image_gen_start_service "$SERVE_BIN" "$CFG" "$TMP/svc2.log" "$HEALTH2" 2>/dev/null); rc=$?
assert_return "start_service: cold start exits 0" 0 "$rc"
assert_match "start_service: prints numeric pid" "$pid" '^[0-9]+$'
PIDS="$PIDS $pid"
image_gen_service_healthy "$HEALTH2" 2>/dev/null && pass "start_service: healthy after cold start" || fail "start_service: not healthy after cold start"

REC_PORT=$(free_port); REC_PORT_FILE="$TMP/rec-port"
REC_BIN="$TMP/rec-bin"; ARGV_LOG="$TMP/argv.log"
cat > "$REC_BIN" <<SH
#!/usr/bin/env bash
printf 'ARGV:' >> "$ARGV_LOG"
for a in "\$@"; do printf ' [%s]' "\$a" >> "$ARGV_LOG"; done
printf '\\n' >> "$ARGV_LOG"
exec python3 "$MOCK" --port $REC_PORT --port-file "$REC_PORT_FILE"
SH
chmod +x "$REC_BIN"
REC_HEALTH="http://127.0.0.1:${REC_PORT}/healthz"
REC_CFG="$TMP/rec-cfg.yaml"; printf 'api-keys:\n  - "k"\n' > "$REC_CFG"
rpid=$(image_gen_start_service "$REC_BIN" "$REC_CFG" "$TMP/rec-svc.log" "$REC_HEALTH" 2>/dev/null); rc=$?
assert_return "start_service: recording start exits 0" 0 "$rc"
PIDS="$PIDS $rpid"
sleep 0.3
[[ -f "$ARGV_LOG" ]] && assert_eq "start_service: exact argv --config <cfg>" "ARGV: [--config] [$REC_CFG]" "$(cat "$ARGV_LOG")" || fail "start_service: argv not recorded"

# Timeout: pid killed, NOTHING printed on error path; verify via pidfile.
SLEEP_PIDFILE="$TMP/sleep.pid"
SLEEP_BIN="$TMP/sleep-bin"
cat > "$SLEEP_BIN" <<SH
#!/usr/bin/env bash
echo \$\$ > "$SLEEP_PIDFILE"
exec sleep 60
SH
chmod +x "$SLEEP_BIN"
rm -f "$SLEEP_PIDFILE"
DEAD_PORT=$(free_port); DEAD_HEALTH="http://127.0.0.1:${DEAD_PORT}/healthz"
out=$(IMAGE_GEN_CLIPROXYAPI_TIMEOUT=2 image_gen_start_service "$SLEEP_BIN" "$CFG" "$TMP/dead.log" "$DEAD_HEALTH" 2>/dev/null); rc=$?
assert_return "start_service: timeout exits 1" 1 "$rc"
assert_eq     "start_service: timeout prints nothing (no internal PID)" "" "$out"
sleep 0.3
orphan_pid="$(cat "$SLEEP_PIDFILE" 2>/dev/null)"
if [[ -n "$orphan_pid" ]] && ! kill -0 "$orphan_pid" 2>/dev/null; then
    pass "start_service: timeout killed spawned pid"
else
    fail "start_service: timeout left an orphan pid"
    [[ -n "$orphan_pid" ]] && PIDS="$PIDS $orphan_pid"
fi

DIE_BIN="$TMP/die-bin"
cat > "$DIE_BIN" <<'SH'
#!/usr/bin/env bash
exit 3
SH
chmod +x "$DIE_BIN"
DIE_PORT=$(free_port); DIE_HEALTH="http://127.0.0.1:${DIE_PORT}/healthz"
t0=$(date +%s)
IMAGE_GEN_CLIPROXYAPI_TIMEOUT=10 image_gen_start_service "$DIE_BIN" "$CFG" "$TMP/die.log" "$DIE_HEALTH" 2>/dev/null; rc=$?
t1=$(date +%s)
assert_return "start_service: early-exit returns 1" 1 "$rc"
[[ $((t1-t0)) -le 6 ]] && pass "start_service: early-exit returns promptly" || fail "start_service: early-exit waited too long"

out=$(image_gen_start_service "$TRAP_BIN" "$CFG" "$TMP/reuse.log" "$HEALTH" 2>/dev/null); rc=$?
assert_return "start_service: reuse healthy exits 0" 0 "$rc"
assert_eq     "start_service: reuse prints nothing" "" "$out"

RO_LOG_DIR="$TMP/rolog"; mkdir -p "$RO_LOG_DIR"; chmod 500 "$RO_LOG_DIR"
image_gen_start_service "$SLEEP_BIN" "$CFG" "$RO_LOG_DIR/svc.log" "http://127.0.0.1:1/healthz" 2>/dev/null; rc=$?
chmod 700 "$RO_LOG_DIR"
assert_return "start_service: restrictive log dir exits 1" 1 "$rc"

# ===========================================================================
# image_gen_main: diagnostics, forwarding, env, capability, exit code
# ===========================================================================

# Upstream probe: asserts injected env, gpt-image-2, decodes b64, emits image[].
PROBE="$TMP/probe.py"
cat > "$PROBE" <<'PY'
import base64, json, os, sys, urllib.request
def die(m): sys.stderr.write(m+"\n"); sys.exit(2)
key=os.environ.get("OPENAI_API_KEY",""); base=os.environ.get("OPENAI_BASE_URL",""); model=os.environ.get("IMAGE_GEN_MODEL","")
if not key: die("PROBE: missing OPENAI_API_KEY")
if not base.startswith("http://127.0.0.1"): die("PROBE: bad base "+base)
if model!="gpt-image-2": die("PROBE: bad model "+model)
if any(key in a for a in sys.argv): die("PROBE: key leaked into argv")
mode="gen"; out_path=None; args=sys.argv[1:]; i=0
while i<len(args):
    if args[i]=="--mode": mode=args[i+1]; i+=2
    elif args[i]=="--output": out_path=args[i+1]; i+=2
    else: i+=1
url=base.rstrip("/")+("/images/edits" if mode=="edit" else "/images/generations")
if mode=="edit":
    b="----pb"
    body=("\r\n".join(["--"+b,'Content-Disposition: form-data; name="model"',"","gpt-image-2",
        "--"+b,'Content-Disposition: form-data; name="image[]"; filename="in.png"',
        "Content-Type: image/octet-stream","",""])).encode()+b"\x89PNG\r\n"+("\r\n--"+b+"--\r\n").encode()
    req=urllib.request.Request(url,data=body,method="POST",headers={"Content-Type":"multipart/form-data; boundary="+b})
else:
    body=json.dumps({"model":"gpt-image-2","prompt":"test","n":1}).encode()
    req=urllib.request.Request(url,data=body,method="POST",headers={"Content-Type":"application/json"})
with urllib.request.urlopen(req,timeout=5) as r: resp=json.loads(r.read().decode())
raw=base64.b64decode(resp["data"][0]["b64_json"])
if out_path:
    with open(out_path,"wb") as fh: fh.write(raw)
sys.stdout.write("PROBE OK len=%d mode=%s\n"%(len(raw),mode)); sys.exit(0)
PY

cfg_ok="$TMP/main-cfg.yaml"; printf 'api-keys:\n  - "main-key"\n' > "$cfg_ok"

# (a) Missing config.
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$TMP/nope-cfg.yaml" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: missing config exits 1" 1 "$rc"
[[ "$out" == *"config"* ]] && pass "main: missing config diagnostic" || fail "main: missing config diagnostic missing"

# (b) Missing curl (restricted PATH: python3 present, curl absent).
MIN_NO_CURL="$TMP/min-no-curl"; mkdir -p "$MIN_NO_CURL"
ln -sf "$(command -v python3)" "$MIN_NO_CURL/python3"
out=$(PATH="$MIN_NO_CURL" IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" \
      IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: missing curl exits 1" 1 "$rc"
[[ "$out" == *"curl"* ]] && pass "main: missing curl diagnostic" || fail "main: missing curl diagnostic missing"

# (c) Missing python3 (restricted PATH: curl present, python3 absent).
MIN_NO_PY="$TMP/min-no-py"; mkdir -p "$MIN_NO_PY"
ln -sf "$(command -v curl)" "$MIN_NO_PY/curl"
out=$(PATH="$MIN_NO_PY" IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" \
      IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: missing python3 exits 1" 1 "$rc"
[[ "$out" == *"python3"* ]] && pass "main: missing python3 diagnostic" || fail "main: missing python3 diagnostic missing"

# (d) Missing upstream.
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$TMP/no-probe.py" \
      image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: missing upstream exits 1" 1 "$rc"
[[ "$out" == *"image_gen"* || "$out" == *"upstream"* ]] && pass "main: missing upstream diagnostic" || fail "main: missing upstream diagnostic missing"

# (e) Missing binary.
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" \
      PATH="/usr/bin:/bin" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: missing binary exits 1" 1 "$rc"
[[ "$out" == *"cliproxyapi"* || "$out" == *"binary"* ]] && pass "main: missing binary diagnostic" || fail "main: missing binary diagnostic missing"

# (f) Old version.
OLDV_DIR="$TMP/oldv-dir"; mkdir -p "$OLDV_DIR"
cat > "$OLDV_DIR/cliproxyapi" <<'SH'
#!/usr/bin/env bash
case "$1" in --help|-h) echo "CLIProxyAPI Version: 7.0.0"; exit 0 ;; *) echo "x"; exit 2 ;; esac
SH
chmod +x "$OLDV_DIR/cliproxyapi"
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" \
      PATH="$OLDV_DIR:/usr/bin:/bin" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: old version exits 1" 1 "$rc"
[[ "$out" == *"7.2.17"* && "$out" == *"brew upgrade cliproxyapi"* ]] && pass "main: old version mentions floor + brew" || fail "main: old version diagnostic incomplete"

# (g) Pre-release version is REJECTED even though numeric core >= floor.
RCV_DIR="$TMP/rcv-dir"; mkdir -p "$RCV_DIR"
cat > "$RCV_DIR/cliproxyapi" <<'SH'
#!/usr/bin/env bash
case "$1" in --help|-h) echo "CLIProxyAPI Version: 8.0.0-rc1"; exit 0 ;; *) echo "x"; exit 2 ;; esac
SH
chmod +x "$RCV_DIR/cliproxyapi"
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" \
      PATH="$RCV_DIR:/usr/bin:/bin" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: pre-release version exits 1" 1 "$rc"
[[ "$out" == *"pre-release"* && "$out" == *"7.2.17"* ]] && pass "main: pre-release diagnostic" || fail "main: pre-release diagnostic missing"

# (h) No key.
GOODV_DIR="$TMP/goodv-dir"; mkdir -p "$GOODV_DIR"
cat > "$GOODV_DIR/cliproxyapi" <<'SH'
#!/usr/bin/env bash
case "$1" in --help|-h) echo "CLIProxyAPI Version: 9.0.0"; exit 0 ;; *) echo "x"; exit 2 ;; esac
SH
chmod +x "$GOODV_DIR/cliproxyapi"
cfg_nokey="$TMP/cfg-nokey.yaml"; printf 'api-keys: []\n' > "$cfg_nokey"
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_nokey" IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" \
      PATH="$GOODV_DIR:/usr/bin:/bin" image_gen_main --prompt x 2>&1); rc=$?
assert_return "main: no key exits 1" 1 "$rc"
[[ "$out" == *"key"* ]] && pass "main: no key diagnostic" || fail "main: no key diagnostic missing"

# Helper: invoke main with the standard happy-path overrides.
run_main() { IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$1" \
    IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
    IMAGE_GEN_CLIPROXYAPI_LOG="$2" PATH="$GOODV_DIR:/usr/bin:/bin" image_gen_main "${@:3}"; }

# (i) End-to-end generation: capability proven (no diagnostic), image saved.
GEN_OUT="$TMP/gen.png"
: > "$RECORDS_FILE"
out=$(run_main "$PROBE" "$TMP/m-gen.log" --mode gen --output "$GEN_OUT" 2>&1); rc=$?
assert_return "main+probe(gen): exit 0" 0 "$rc"
[[ "$out" != *"capability probe failed"* ]] && pass "main(gen): capability proven, no diagnostic" || fail "main(gen): unexpected capability diagnostic"
[[ -f "$GEN_OUT" && -s "$GEN_OUT" ]] && pass "main+probe(gen): image saved" || fail "main+probe(gen): no image saved"
[[ "$out" == *"PROBE OK"* ]] && pass "main+probe(gen): probe ran" || fail "main+probe(gen): probe did not run"
sleep 0.2
gen_records="$(cat "$RECORDS_FILE" 2>/dev/null)"
[[ "$gen_records" == *'"generations"'* && "$gen_records" == *'"gpt-image-2"'* ]] && pass "records: generation route + model recorded" || fail "records: generation not recorded"

# (j) End-to-end edit: image[] field asserted independently.
EDIT_OUT="$TMP/edit.png"
: > "$RECORDS_FILE"
out=$(run_main "$PROBE" "$TMP/m-edit.log" --mode edit --output "$EDIT_OUT" 2>&1); rc=$?
assert_return "main+probe(edit): exit 0" 0 "$rc"
[[ -f "$EDIT_OUT" && -s "$EDIT_OUT" ]] && pass "main+probe(edit): image saved" || fail "main+probe(edit): no image saved"
sleep 0.2
edit_records="$(cat "$RECORDS_FILE" 2>/dev/null)"
[[ "$edit_records" == *'"edits"'* && "$edit_records" == *'"edit_field": "image[]"'* ]] && pass "records: edit route + image[] field recorded" || fail "records: edit/image[] not recorded"
[[ "$edit_records" == *'"edit_multipart": true'* ]] && pass "records: edit multipart recorded" || fail "records: edit multipart missing"

# (k) Exit-code preservation.
EXIT_PROBE="$TMP/exit-probe.py"
cat > "$EXIT_PROBE" <<'PY'
import os, sys
assert os.environ.get("OPENAI_API_KEY")
assert os.environ.get("OPENAI_BASE_URL","").startswith("http://127.0.0.1")
assert os.environ.get("IMAGE_GEN_MODEL")=="gpt-image-2"
sys.exit(3)
PY
out=$(run_main "$EXIT_PROBE" "$TMP/exit.log" --prompt x >/dev/null 2>&1); rc=$?
assert_return "main: preserves non-zero exit code" 3 "$rc"

# (l) Argument forwarding.
FWD_PROBE="$TMP/fwd-probe.py"
cat > "$FWD_PROBE" <<'PY'
import os, sys
with open(os.environ["FWD_OUT"],"w") as fh: fh.write("\n".join(sys.argv[1:]))
sys.exit(0)
PY
FWD_OUT="$TMP/fwd.txt"
IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$FWD_PROBE" \
IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/fwd.log" PATH="$GOODV_DIR:/usr/bin:/bin" \
FWD_OUT="$FWD_OUT" image_gen_main --prompt "hello world" --size 1024x1024 --n 1 >/dev/null 2>&1
[[ -f "$FWD_OUT" ]] && assert_eq "main: forwards all argv verbatim" $'--prompt\nhello world\n--size\n1024x1024\n--n\n1' "$(cat "$FWD_OUT")" || fail "main: argv forwarding not recorded"

# (m) Child-only env override (parent restored).
export OPENAI_BASE_URL="http://parent.example:1111"
export OPENAI_API_KEY="parent-key"
export IMAGE_GEN_MODEL="parent-model"
run_main "$EXIT_PROBE" "$TMP/child.log" --prompt x >/dev/null 2>&1
assert_eq "main: parent OPENAI_BASE_URL restored" "http://parent.example:1111" "$OPENAI_BASE_URL"
assert_eq "main: parent OPENAI_API_KEY restored"  "parent-key" "$OPENAI_API_KEY"
assert_eq "main: parent IMAGE_GEN_MODEL restored" "parent-model" "$IMAGE_GEN_MODEL"

# (n) Hostile ANTHROPIC_BASE_URL never leaks into child OPENAI_BASE_URL.
LEAK_PROBE="$TMP/leak-probe.py"
cat > "$LEAK_PROBE" <<'PY'
import os, sys
with open(os.environ["LEAK_OUT"],"w") as fh: fh.write(os.environ.get("OPENAI_BASE_URL","")+"\n")
sys.exit(0)
PY
LEAK_OUT="$TMP/leak.txt"
IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$LEAK_PROBE" \
IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/leak.log" PATH="$GOODV_DIR:/usr/bin:/bin" \
ANTHROPIC_BASE_URL="http://evil.example:9999" LEAK_OUT="$LEAK_OUT" \
image_gen_main --prompt x >/dev/null 2>&1
[[ -f "$LEAK_OUT" ]] && assert_match "main: child OPENAI_BASE_URL is loopback" "$(cat "$LEAK_OUT")" '^http://127\.0\.0\.1:[0-9]+/v1$' || fail "main: child base url not loopback"

# ===========================================================================
# Task 7: Launcher independence
#
# Every cl* launcher (cl, cl_claude, cl_glm, cl_ccr, cl_gpt, and generated
# cl_<name>_auto variants) routes Claude Code through _cl_profile_run, which
# only manages ANTHROPIC_* env and the claude binary. The image-gen Skill and
# this wrapper live at global ~/.claude paths; the wrapper never reads
# ANTHROPIC_BASE_URL, and claude.zsh never references OPENAI*/image-gen/the
# wrapper. So profile choice cannot reroute image generation, and a hostile
# ANTHROPIC_BASE_URL cannot change the child OPENAI_BASE_URL.
# ===========================================================================

# (q) Wrapper constants: the exact global paths/values the spec mandates.
# Constants are read from SOURCE, not the live shell var: later tests
# legitimately export IMAGE_GEN_MODEL to verify save/restore, which would
# silently clobber the sourced assignment and produce false failures here.
assert_eq "task7: IMAGE_GEN_BASE_URL is exact loopback /v1" \
    "http://127.0.0.1:8317/v1" "$IMAGE_GEN_BASE_URL"
assert_eq "task7: IMAGE_GEN_DEFAULT_UPSTREAM is global skill path (scripts/image_gen.py)" \
    "$HOME/.claude/skills/image-gen/scripts/image_gen.py" "$IMAGE_GEN_DEFAULT_UPSTREAM"
if grep -qE '^IMAGE_GEN_MODEL="gpt-image-2"$' "$WRAPPER" 2>/dev/null; then
    pass "task7: wrapper source defines IMAGE_GEN_MODEL=gpt-image-2 constant"
else
    fail "task7: wrapper source does not define IMAGE_GEN_MODEL=gpt-image-2"
fi

# (r) claude.zsh is launcher-only: it must not reference OPENAI*, image-gen,
# image_gen, IMAGE_GEN, or the wrapper filename. If it did, a profile could
# couple the launcher to the image-gen path. This single source-level check
# covers cl and every generated cl_<name> / cl_<name>_auto function, since
# they all flow through _cl_profile_run -> _cl_run -> claude.
CL_ZSH="$DIR/claude.zsh"
if [[ -f "$CL_ZSH" ]]; then
    if grep -nE 'OPENAI_|image-gen|image_gen|IMAGE_GEN|cliproxyapi\.sh' "$CL_ZSH" >/dev/null 2>&1; then
        fail "task7: claude.zsh references image-gen/OPENAI (launcher not independent)"
        grep -nE 'OPENAI_|image-gen|image_gen|IMAGE_GEN|cliproxyapi\.sh' "$CL_ZSH" >&2 || true
    else
        pass "task7: claude.zsh has no image-gen/OPENAI references (launcher independent)"
    fi
else
    fail "task7: claude.zsh not found at $CL_ZSH"
fi

# (s) Each real profile's ANTHROPIC_BASE_URL, plus a hostile value, must leave
# the child OPENAI_BASE_URL at the exact loopback value the wrapper chose.
# Proves profile choice cannot reroute image generation.
task7_anthropic_urls=(
    "http://127.0.0.1:8317"                    # gpt profile
    "http://127.0.0.1:3456"                    # ccr profile
    "https://open.bigmodel.cn/api/anthropic"   # glm profile
    "http://evil.example:9999/v1"              # hostile
)
for u in "${task7_anthropic_urls[@]}"; do
    rm -f "$LEAK_OUT"
    IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$LEAK_PROBE" \
    IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
    IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/task7-set.log" PATH="$GOODV_DIR:/usr/bin:/bin" \
    ANTHROPIC_BASE_URL="$u" LEAK_OUT="$LEAK_OUT" \
    image_gen_main --prompt x >/dev/null 2>&1
    assert_eq "task7: ANTHROPIC_BASE_URL=[$u] does not change child OPENAI_BASE_URL" \
        "$IMG_BASE" "$(cat "$LEAK_OUT" 2>/dev/null)"
done
# Unset ANTHROPIC_BASE_URL entirely (the native claude profile unsets it).
# `env -u` cannot invoke a shell function, so unset inside a subshell.
rm -f "$LEAK_OUT"
(
    unset ANTHROPIC_BASE_URL
    IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$LEAK_PROBE" \
    IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
    IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/task7-unset.log" PATH="$GOODV_DIR:/usr/bin:/bin" \
    LEAK_OUT="$LEAK_OUT" \
    image_gen_main --prompt x >/dev/null 2>&1
)
assert_eq "task7: unset ANTHROPIC_BASE_URL does not change child OPENAI_BASE_URL" \
    "$IMG_BASE" "$(cat "$LEAK_OUT" 2>/dev/null)"

# (t) REGRESSION: a parent shell that exports IMAGE_GEN_MODEL must NOT poison
# the delegated child. The wrapper must inject the constant gpt-image-2
# regardless of the parent's value, and restore the parent env unchanged.
# The probe writes the child's IMAGE_GEN_MODEL and exits 3 ONLY on an exact
# match, so a stale leak surfaces as a wrong status AND a wrong value.
MODEL_PROBE="$TMP/model-probe.py"
cat > "$MODEL_PROBE" <<'PY'
import os, sys
m = os.environ.get("IMAGE_GEN_MODEL", "")
with open(os.environ["MODEL_OUT"], "w") as fh: fh.write(m + "\n")
sys.exit(3 if m == "gpt-image-2" else 1)
PY
MODEL_OUT="$TMP/model-out.txt"
rm -f "$MODEL_OUT"
export IMAGE_GEN_MODEL="parent-model"
export MODEL_OUT
out=$(run_main "$MODEL_PROBE" "$TMP/model-svc.log" --prompt x 2>&1); rc=$?
assert_return "task7-regression: child probe exit 3 (model==gpt-image-2)" 3 "$rc"
assert_eq "task7-regression: child IMAGE_GEN_MODEL is gpt-image-2" \
    "gpt-image-2" "$(cat "$MODEL_OUT" 2>/dev/null)"
assert_eq "task7-regression: parent IMAGE_GEN_MODEL restored unchanged" \
    "parent-model" "$IMAGE_GEN_MODEL"
unset MODEL_OUT
unset IMAGE_GEN_MODEL



# (o) FAIL-CLOSED capability: liveness up but gpt-image-2 NOT proven -> exit
# nonzero, NO delegation. A canary probe records whether it was invoked; the
# record file MUST remain absent, and the key MUST NOT appear in argv/logs.
CANARY_PROBE="$TMP/canary-probe.py"
cat > "$CANARY_PROBE" <<'PY'
import os, sys
with open(os.environ["CANARY_OUT"],"w") as fh:
    fh.write("INVOKED argv=%s\n" % "|".join(sys.argv[1:]))
sys.exit(0)
PY

run_failclosed_case() {
    local label="$1" health="$2" base="$3" canary_out="$4"
    rm -f "$canary_out" 2>/dev/null
    local out rc
    out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$CANARY_PROBE" \
          IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$health" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$base" \
          IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/fc.log" IMAGE_GEN_CLIPROXYAPI_TIMEOUT=2 \
          PATH="$GOODV_DIR:/usr/bin:/bin" CANARY_OUT="$canary_out" \
          image_gen_main --prompt x 2>&1); rc=$?
    assert_return "$label: exit nonzero (fail-closed)" 1 "$rc"
    [[ "$out" == *"capability not proven"* && "$out" == *"gpt-image-2"* ]] && pass "$label: actionable diagnostic" || fail "$label: diagnostic missing"
    [[ -e "$canary_out" ]] && fail "$label: upstream was delegated (should NOT)" || pass "$label: upstream NOT delegated"
    # Key must not appear anywhere in captured stdout/stderr.
    local cfg_key; cfg_key="$(image_gen_extract_config_key "$cfg_ok" 2>/dev/null)"
    [[ -n "$cfg_key" && "$out" == *"$cfg_key"* ]] && fail "$label: key leaked to logs" || pass "$label: key absent from logs"
}

# (o1) No model / unrelated listener: mock with --no-oauth (liveness 200, but
# /v1/models omits gpt-image-2).
NOAUTH_PORT_FILE2="$TMP/na2-port"; NOAUTH_RECORDS2="$TMP/na2-records"
start_mock "$NOAUTH_PORT_FILE2" "$NOAUTH_RECORDS2" "" "no-oauth"
run_failclosed_case "main(no-model)" "$MOCK_ROOT/healthz" "$MOCK_ROOT/v1" "$TMP/canary-noauth.txt"

# (o2) Auth mismatch (no OAuth for this key): mock requires a different key, so
# the local key gets 401 on /v1/models -> capability not proven.
MISMATCH_PORT_FILE="$TMP/ms-port"; MISMATCH_RECORDS="$TMP/ms-records"
start_mock "$MISMATCH_PORT_FILE" "$MISMATCH_RECORDS" "a-different-secret-key"
run_failclosed_case "main(auth-mismatch)" "$MOCK_ROOT/healthz" "$MOCK_ROOT/v1" "$TMP/canary-mismatch.txt"

# (o3) Substring-only id ("not-gpt-image-2") -> fail closed.
SUB2_PORT_FILE="$TMP/sub2-port"
start_mock "$SUB2_PORT_FILE" "" "" "substring"
run_failclosed_case "main(substring-id)" "$MOCK_ROOT/healthz" "$MOCK_ROOT/v1" "$TMP/canary-sub.txt"

# (o4) Malformed /v1/models JSON -> fail closed.
MJ2_PORT_FILE="$TMP/mj2-port"
start_mock "$MJ2_PORT_FILE" "" "" "malformed"
run_failclosed_case "main(malformed-models)" "$MOCK_ROOT/healthz" "$MOCK_ROOT/v1" "$TMP/canary-mj.txt"

# (o5) Non-array data -> fail closed.
NA2_PORT_FILE="$TMP/na3-port"
start_mock "$NA2_PORT_FILE" "" "" "nonarray"
run_failclosed_case "main(non-array-data)" "$MOCK_ROOT/healthz" "$MOCK_ROOT/v1" "$TMP/canary-na.txt"

# (p) DIRECT invocation: the script must NOT exit 127 (guard at end).
DIRECT_OUT="$TMP/direct.png"
: > "$RECORDS_FILE"
out=$(IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_ok" IMAGE_GEN_UPSTREAM_SCRIPT="$PROBE" \
      IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
      IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/direct.log" PATH="$GOODV_DIR:/usr/bin:/bin" \
      bash "$WRAPPER" --mode gen --output "$DIRECT_OUT" 2>&1); rc=$?
[[ "$rc" -ne 127 ]] && pass "direct invocation: does not exit 127 (guard works)" || fail "direct invocation: exited 127 (guard broken)"
assert_return "direct invocation: end-to-end exit 0" 0 "$rc"
[[ -f "$DIRECT_OUT" && -s "$DIRECT_OUT" ]] && pass "direct invocation: image generated" || fail "direct invocation: no image generated"

# ===========================================================================
# xtrace sentinel-key regression (full subshell capture; key via file)
# ===========================================================================
SENT_KEY="sentinel-secret-key-1234567890abcdef"
cfg_sent="$TMP/cfg-sent.yaml"; printf 'api-keys:\n  - "%s"\n' "$SENT_KEY" > "$cfg_sent"
printf '%s' "$SENT_KEY" > "$TMP/sent.expect"; chmod 600 "$TMP/sent.expect"
SENT_PROBE="$TMP/sent-probe.py"
cat > "$SENT_PROBE" <<'PY'
import os, sys
with open(os.environ["SENT_EXPECT_FILE"]) as fh: expected=fh.read()
key=os.environ.get("OPENAI_API_KEY","")
ok_env = key == expected
ok_argv = all(expected not in a for a in sys.argv)
with open(os.environ["SENT_RESULT"],"w") as fh:
    fh.write("env=%s argv=%s\n" % ("yes" if ok_env else "no", "clean" if ok_argv else "leaked"))
sys.exit(0)
PY
TRACE_ALL="$TMP/trace.all"
(
    set -x
    IMAGE_GEN_CLIPROXYAPI_CONFIG="$cfg_sent" IMAGE_GEN_UPSTREAM_SCRIPT="$SENT_PROBE" \
    IMAGE_GEN_CLIPROXYAPI_HEALTH_URL="$HEALTH" IMAGE_GEN_CLIPROXYAPI_BASE_URL="$IMG_BASE" \
    IMAGE_GEN_CLIPROXYAPI_LOG="$TMP/trace-svc.log" PATH="$GOODV_DIR:/usr/bin:/bin" \
    SENT_EXPECT_FILE="$TMP/sent.expect" SENT_RESULT="$TMP/sent-result.txt" \
    image_gen_main --prompt x
) > "$TRACE_ALL" 2>&1
sent_result="$(cat "$TMP/sent-result.txt" 2>/dev/null)"
assert_eq "main: sentinel key in env"           "env=yes"    "${sent_result%% *}"
assert_eq "main: sentinel key absent from argv" "argv=clean" "${sent_result##* }"
if grep -Fq "$SENT_KEY" "$TRACE_ALL" 2>/dev/null; then fail "main: trace leaked sentinel key"; else pass "main: trace did not leak sentinel key"; fi
if grep -Fqi "OPENAI_API_KEY" "$TRACE_ALL" 2>/dev/null; then fail "main: trace leaked OPENAI_API_KEY assignment"; else pass "main: trace did not leak OPENAI_API_KEY line"; fi
found_key_in_paths=$(find "$TMP" -name "*${SENT_KEY}*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "main: no file path embeds the sentinel key" "0" "$found_key_in_paths"

# ===========================================================================
# Post-cleanup proof: kill every recorded PID, then confirm none survives.
# ===========================================================================
for p in $PIDS; do kill "$p" >/dev/null 2>&1; done
sleep 0.5
survivors=0
for p in $PIDS; do
    if kill -0 "$p" 2>/dev/null; then survivors=$((survivors+1)); fi
done
assert_eq "cleanup: no recorded PID survives after explicit kill" "0" "$survivors"

# ===========================================================================
echo ""
echo "============================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "============================================================"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
exit 0

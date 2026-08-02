#!/usr/bin/env bash
# ============================================================
# image-gen-cliproxyapi.sh
#
# Secure wrapper that starts or reuses a local CLIProxyAPI
# (OpenAI-compatible) instance, reads its local client key, injects
# child-only OPENAI_* variables, and delegates unchanged arguments to the
# upstream sinedied/agent-skills:image-gen `image_gen.py`.
#
# Design constraints:
#   - Bash 3.2 compatible (no associative arrays, no sort -V, no `${var^}`).
#   - The proxy key is NEVER printed, logged, or passed in argv; it is
#     injected only into the delegated child process's environment. The key
#     charset is restricted to header-safe characters.
#   - xtrace is disabled around secret handling so trace output never leaks
#     the key; the caller's trace state is restored before return.
#   - Liveness (`/healthz`) decides start/reuse. An authenticated capability
#     probe (`/v1/models` + key, requiring `gpt-image-2`) is then run; if it
#     cannot prove OAuth/capability, a diagnostic is emitted but delegation
#     still proceeds so any real auth failure is surfaced by the upstream.
#   - Loopback-only base URL: http://127.0.0.1:8317/v1
#   - Image model: gpt-image-2
#   - Minimum CLIProxyAPI version: 7.2.17 (stable; all prereleases rejected)
#
# Test overrides (env):
#   IMAGE_GEN_CLIPROXYAPI_CONFIG     config.yaml path
#   IMAGE_GEN_UPSTREAM_SCRIPT        upstream image_gen.py path
#   IMAGE_GEN_CLIPROXYAPI_HEALTH_URL liveness probe URL
#   IMAGE_GEN_CLIPROXYAPI_LOG        service log path
#   IMAGE_GEN_CLIPROXYAPI_TIMEOUT    ready timeout (seconds)
#   IMAGE_GEN_CLIPROXYAPI_BASE_URL   child OPENAI_BASE_URL (test-only; the
#                                    production value is the exact constant
#                                    above and is never derived from health)
# ============================================================

# ------------------------------------------------------------
# Constants
# ------------------------------------------------------------

IMAGE_GEN_VERSION_FLOOR="7.2.17"
IMAGE_GEN_BASE_URL="http://127.0.0.1:8317/v1"
IMAGE_GEN_MODEL="gpt-image-2"
# Canonical injection source. Kept separate from the exported
# IMAGE_GEN_MODEL env name so a parent shell that sets
# IMAGE_GEN_MODEL cannot change the value we inject into the
# delegated child (mirrors how OPENAI_BASE_URL uses $base_url).
IMAGE_GEN_DEFAULT_MODEL="gpt-image-2"
IMAGE_GEN_DEFAULT_HEALTH_URL="http://127.0.0.1:8317/healthz"
IMAGE_GEN_DEFAULT_LOG="$HOME/.cli-proxy-api/cliproxyapi.log"
IMAGE_GEN_DEFAULT_CONFIG="$HOME/.cli-proxy-api/config.yaml"
IMAGE_GEN_DEFAULT_UPSTREAM="$HOME/.claude/skills/image-gen/image_gen.py"
IMAGE_GEN_DEFAULT_TIMEOUT=25

# Candidate binary names, in priority order.
IMAGE_GEN_BIN_NAMES=("cliproxyapi" "cli-proxy-api" "cliproxy-api")

# ------------------------------------------------------------
# Task 1: pure validation helpers
# ------------------------------------------------------------

# Find the first CLIProxyAPI binary on PATH. Prints the path and returns 0,
# or prints nothing and returns 1 when no candidate exists. `type -P` ignores
# shell functions and the command hash table (fresh PATH search).
image_gen_find_binary() {
    local name path
    for name in "${IMAGE_GEN_BIN_NAMES[@]}"; do
        path="$(type -P "$name" 2>/dev/null)" || continue
        if [[ -n "$path" && -x "$path" ]]; then
            printf '%s' "$path"
            return 0
        fi
    done
    return 1
}

# Extract the first X.Y.Z triple from a version string. Accepts a leading
# "v", trailing pre-release/build metadata, and surrounding prose. Prints
# "X.Y.Z" and returns 0, or returns 1 when no triple is found. A two-digit
# form (X.Y) is normalized to X.Y.0.
image_gen_parse_version() {
    local raw="$1" triple
    [[ -n "$raw" ]] || return 1
    if [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        triple="${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ([0-9]+\.[0-9]+) ]]; then
        triple="${BASH_REMATCH[1]}.0"
    else
        return 1
    fi
    printf '%s' "$triple"
    return 0
}

# Return 0 if the version string carries ANY non-empty hyphen suffix (a
# pre-release: -rc1, -beta, -canary, -milestone, -foo, ...). Build metadata
# after `+` (e.g. 7.2.17+meta) is stable and does NOT count. Labels are not
# enumerated: any `-<nonempty>` before build metadata is a pre-release.
image_gen_has_prerelease() {
    local v="$1" no_meta
    [[ -n "$v" ]] || return 1
    no_meta="${v%%+*}"   # drop build metadata; stable by definition
    [[ "$no_meta" == *-?* ]]
}

# Pure numeric core comparison without `sort -V`. Returns 0 (true) when
# "$1"'s numeric core >= "$2"'s numeric core. Pre-release suffixes are
# ignored by THIS comparator (policy is enforced by meets_floor).
image_gen_version_at_least() {
    local a_triple b_triple
    a_triple="$(image_gen_parse_version "$1")" || return 1
    b_triple="$(image_gen_parse_version "$2")" || return 1
    local IFS=.
    # shellcheck disable=SC2206
    local a_arr=($a_triple)
    # shellcheck disable=SC2206
    local b_arr=($b_triple)
    local i a_part b_part
    for i in 0 1 2; do
        a_part="${a_arr[$i]:-0}"; a_part="${a_part%%[^0-9]*}"; a_part="${a_part:-0}"
        b_part="${b_arr[$i]:-0}"; b_part="${b_part%%[^0-9]*}"; b_part="${b_part:-0}"
        if (( a_part > b_part )); then return 0
        elif (( a_part < b_part )); then return 1; fi
    done
    return 0
}

# Floor policy: reject ALL pre-releases against a stable floor, regardless of
# numeric core (a pre-release is not a stable release). Returns 0 only when
# the version is a stable release whose numeric core >= floor.
image_gen_version_meets_floor() {
    local v="$1" floor="$2" triple
    triple="$(image_gen_parse_version "$v")" || return 1
    if image_gen_has_prerelease "$v"; then
        return 1
    fi
    image_gen_version_at_least "$triple" "$floor"
}

# Read the version of an installed binary by trying `version` then
# `--version`. Prints a normalized version token INCLUDING any pre-release
# suffix (e.g. "8.0.0-rc1") so floor policy can reject pre-releases. Returns
# 1 when neither form yields a parseable version.
image_gen_read_binary_version() {
    local binary="$1" raw token
    [[ -n "$binary" && -x "$binary" ]] || return 1
    raw="$("$binary" version 2>/dev/null)" || raw=""
    if [[ -z "$raw" ]]; then
        raw="$("$binary" --version 2>/dev/null)" || raw=""
    fi
    [[ -n "$raw" ]] || return 1
    if [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
        token="${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ([0-9]+\.[0-9]+) ]]; then
        token="${BASH_REMATCH[1]}.0"
    else
        return 1
    fi
    printf '%s' "$token"
}

# Validate a candidate api-key scalar. Rejects empty, YOUR_* placeholders,
# and anything outside a header-safe literal set ([A-Za-z0-9._~-]). Mirrors
# install.sh semantics without sourcing it.
_image_gen_valid_key_value() {
    local v="$1"
    [[ -n "$v" && "$v" != YOUR_* ]] || return 1
    [[ "$v" =~ ^[A-Za-z0-9._~-]+$ ]]
}

# Extract the first valid top-level api-keys entry from a CLIProxyAPI
# config.yaml. Self-contained constrained awk/shell parser: only a column-0
# `api-keys:` block or a fully-closed inline sequence is considered; nested
# keys, mappings, anchors/aliases, flow mappings, placeholders, control/
# whitespace characters, unclosed brackets, and malformed quotes are rejected.
image_gen_extract_config_key() {
    local path="$1" cand
    [[ -r "$path" ]] || return 1
    while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        if [[ "$cand" =~ ^\"(.*)\"$ ]]; then cand="${BASH_REMATCH[1]}"
        elif [[ "$cand" =~ ^\'(.*)\'$ ]]; then cand="${BASH_REMATCH[1]}"; fi
        cand="${cand#"${cand%%[![:space:]]*}"}"
        cand="${cand%"${cand##*[![:space:]]}"}"
        if _image_gen_valid_key_value "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
    done < <(
        awk '
            function valid_scalar(s) {
                if (s == "") return 0
                if (substr(s, 1, 5) == "YOUR_") return 0
                return (s ~ /^[A-Za-z0-9._~-]+$/)
            }
            # Validate one list item: balanced surrounding quotes (single or
            # double), no embedded quote of the wrapping kind, and a valid
            # scalar inside. Bare items must contain no quote/brace/colon.
            function valid_item(s,   inner) {
                if (s == "") return 0
                if (substr(s, 1, 1) == "\"") {
                    if (length(s) < 2 || substr(s, length(s), 1) != "\"") return 0
                    inner = substr(s, 2, length(s) - 2)
                    if (index(inner, "\"")) return 0
                    return valid_scalar(inner)
                }
                if (substr(s, 1, 1) == "'"'"'") {
                    if (length(s) < 2 || substr(s, length(s), 1) != "'"'"'") return 0
                    inner = substr(s, 2, length(s) - 2)
                    if (index(inner, "'"'"'")) return 0
                    return valid_scalar(inner)
                }
                if (s ~ /["'"'"'{}:\[\]]/) return 0
                return valid_scalar(s)
            }
            BEGIN { in_block = 0 }
            {
                if (in_block && $0 ~ /^[^ \t#]/) in_block = 0
                if (in_block) {
                    line = $0
                    sub(/[ \t]+#.*/, "", line)
                    if (line ~ /^[ \t]+-[ \t]/ || line ~ /^[ \t]+-[ \t]*$/) {
                        v = line
                        sub(/^[ \t]+-[ \t]*/, "", v)
                        sub(/[ \t]+$/, "", v)
                        if (length(v) > 0) print v
                    }
                    next
                }
                if ($0 ~ /^api-keys:/) {
                    rest = $0
                    sub(/^api-keys:[ \t]*/, "", rest)
                    sub(/[ \t]+#.*/, "", rest)
                    if (rest ~ /^#/) rest = ""
                    if (rest ~ /^\[/) {
                        # Require a fully-closed inline list with no trailing
                        # material after the closing bracket.
                        if (rest !~ /\][ \t]*$/) next
                        # Reject any stray bracket inside the list body.
                        body = rest
                        sub(/^\[/, "", body)
                        # Find last ] only; ensure no ] appears before it.
                        if (body ~ /\].*\]/) next
                        sub(/\][ \t]*$/, "", body)
                        m = split(body, arr, ",")
                        all_ok = 1
                        first = ""
                        for (i = 1; i <= m; i++) {
                            v = arr[i]
                            sub(/^[ \t]+/, "", v)
                            sub(/[ \t]+$/, "", v)
                            if (length(v) == 0) { all_ok = 0; break }
                            if (!valid_item(v)) { all_ok = 0; break }
                            if (first == "") first = v
                        }
                        if (all_ok && first != "") print first
                    } else if (length(rest) > 0) {
                        print rest
                    } else {
                        in_block = 1
                    }
                    next
                }
            }
        ' "$path" 2>/dev/null
    )
    return 1
}

# ------------------------------------------------------------
# Task 2: service lifecycle
# ------------------------------------------------------------

# Liveness: return 0 when the service answers the health URL, else 1.
# Unauthenticated; cheap. Used only to decide start/reuse.
image_gen_service_healthy() {
    local url="$1"
    command -v curl >/dev/null 2>&1 || return 1
    [[ -n "$url" ]] || return 1
    if curl -fsS -m 2 -o /dev/null "$url" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Capability: authenticated GET against exact loopback `/v1/models` using the
# local proxy key, requiring an EXACT `data[].id == "gpt-image-2"`. The
# Authorization header is fed via curl `--config -` (stdin) so the key never
# appears in argv; the response body is piped to python3 via stdin (never
# argv/env). python3 parses the JSON and exits 0 only on an exact id match.
# Fail-closed: malformed JSON, wrong schema, substring-only ids, embedded ids
# in other fields, non-array data, or error text all exit nonzero.
image_gen_service_ready() {
    local base_url="$1" key="$2"
    command -v curl >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    [[ -n "$base_url" && -n "$key" ]] || return 1
    {
        printf 'header = "Authorization: Bearer %s"\n' "$key"
        printf 'url = "%s/models"\n' "${base_url%/}"
        printf 'silent\n'
        printf 'show-error\n'
    } | curl --config - -sS -m 3 2>/dev/null | python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(1)
data = obj.get("data") if isinstance(obj, dict) else None
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if isinstance(item, dict) and item.get("id") == "gpt-image-2":
        sys.exit(0)
sys.exit(1)
'
}

# Poll the authenticated capability probe until it proves gpt-image-2 or the
# timeout elapses. Returns 0 on success, 1 on timeout. FAIL-CLOSED contract:
# callers MUST NOT delegate when this returns 1.
image_gen_wait_capability() {
    local base_url="$1" key="$2"
    local timeout="${3:-${IMAGE_GEN_CLIPROXYAPI_TIMEOUT:-$IMAGE_GEN_DEFAULT_TIMEOUT}}"
    command -v curl >/dev/null 2>&1 || return 1
    [[ -n "$base_url" && -n "$key" ]] || return 1
    local elapsed=0 step=1
    while (( elapsed < timeout )); do
        if image_gen_service_ready "$base_url" "$key"; then
            return 0
        fi
        sleep "$step"
        elapsed=$(( elapsed + step ))
    done
    return 1
}

# Poll liveness until it responds or the timeout elapses. Returns 0 on
# success, 1 on timeout. Optional $3 watches a spawned pid for early exit.
image_gen_wait_ready() {
    local url="$1"
    local timeout="${2:-$IMAGE_GEN_DEFAULT_TIMEOUT}"
    local watch_pid="${3:-}"
    command -v curl >/dev/null 2>&1 || return 1
    local elapsed=0 step=1
    while (( elapsed < timeout )); do
        if curl -fsS -m 2 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        if [[ -n "$watch_pid" ]] && ! kill -0 "$watch_pid" 2>/dev/null; then
            return 1
        fi
        sleep "$step"
        elapsed=$(( elapsed + step ))
    done
    return 1
}

# Start (or reuse) the CLIProxyAPI service. If the service is already alive,
# no process is started. Otherwise run `<binary> --config <config>` in the
# background, wait for liveness, and print the spawned PID on success. On
# timeout/failure the spawned PID is killed and nothing is printed.
image_gen_start_service() {
    local binary="$1" config="$2" log="$3" health_url="$4"
    local timeout="${IMAGE_GEN_CLIPROXYAPI_TIMEOUT:-$IMAGE_GEN_DEFAULT_TIMEOUT}"
    [[ -n "$binary" && -n "$config" && -n "$health_url" ]] || return 1

    if image_gen_service_healthy "$health_url"; then
        return 0
    fi

    local log_dir=""
    if [[ -n "$log" ]]; then
        log_dir="$(dirname "$log" 2>/dev/null)"
        if [[ -n "$log_dir" && ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || true
        fi
    fi

    nohup "$binary" --config "$config" >> "${log:-/dev/null}" 2>&1 &
    local pid=$!

    if image_gen_wait_ready "$health_url" "$timeout" "$pid"; then
        printf '%s' "$pid"
        return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
    return 1
}

# Emit a sanitized diagnostic on stderr and return the given code.
_image_gen_die() {
    local code="$1"; shift
    printf 'image-gen: %s\n' "$*" >&2
    return "$code"
}

# ------------------------------------------------------------
# Task 2: main orchestration
# ------------------------------------------------------------

image_gen_main() {
    local config binary version key health_url log upstream base_url rc

    # Forget any stale command-hash entries from the calling shell: a cached
    # path must never spoof (or hide) a prerequisite.
    hash -r 2>/dev/null || true

    config="${IMAGE_GEN_CLIPROXYAPI_CONFIG:-$IMAGE_GEN_DEFAULT_CONFIG}"
    upstream="${IMAGE_GEN_UPSTREAM_SCRIPT:-$IMAGE_GEN_DEFAULT_UPSTREAM}"
    health_url="${IMAGE_GEN_CLIPROXYAPI_HEALTH_URL:-$IMAGE_GEN_DEFAULT_HEALTH_URL}"
    log="${IMAGE_GEN_CLIPROXYAPI_LOG:-$IMAGE_GEN_DEFAULT_LOG}"
    base_url="${IMAGE_GEN_CLIPROXYAPI_BASE_URL:-$IMAGE_GEN_BASE_URL}"

    # 1. Config readable.
    if [[ ! -r "$config" ]]; then
        _image_gen_die 1 "cannot read CLIProxyAPI config: $config"; return 1
    fi
    # 2. curl present (liveness + capability probes).
    if ! type -P curl >/dev/null 2>&1; then
        _image_gen_die 1 "curl not found (required to probe CLIProxyAPI)"; return 1
    fi
    # 3. python3 present (run upstream).
    if ! type -P python3 >/dev/null 2>&1; then
        _image_gen_die 1 "python3 not found (required to run image_gen.py)"; return 1
    fi
    # 4. Upstream script readable.
    if [[ ! -r "$upstream" ]]; then
        _image_gen_die 1 "upstream image_gen.py not found: $upstream"; return 1
    fi
    # 5. Binary present.
    if ! binary="$(image_gen_find_binary)"; then
        _image_gen_die 1 "CLIProxyAPI binary not found (tried: ${IMAGE_GEN_BIN_NAMES[*]})"; return 1
    fi
    # 6/7. Version readable and meets the stable floor.
    if ! version="$(image_gen_read_binary_version "$binary")"; then
        _image_gen_die 1 "cannot read CLIProxyAPI version from $binary"; return 1
    fi
    if ! image_gen_version_meets_floor "$version" "$IMAGE_GEN_VERSION_FLOOR"; then
        if image_gen_has_prerelease "$version"; then
            _image_gen_die 1 "CLIProxyAPI $version is a pre-release; stable $IMAGE_GEN_VERSION_FLOOR+ required (run: brew upgrade cliproxyapi)"
        else
            _image_gen_die 1 "CLIProxyAPI $version is older than required $IMAGE_GEN_VERSION_FLOOR (run: brew upgrade cliproxyapi)"
        fi
        return 1
    fi

    # Disable xtrace before reading the key; bash traces `key=$(...)` values.
    local _had_xtrace=0
    case $- in *x*) _had_xtrace=1; set +x ;; esac

    # 8. Key extractable from config.
    if ! key="$(image_gen_extract_config_key "$config" 2>/dev/null)" || [[ -z "$key" ]]; then
        [[ "$_had_xtrace" -eq 1 ]] && set -x
        _image_gen_die 1 "no CLIProxyAPI API key found in config: $config"; return 1
    fi

    # 9. Start or reuse the service (liveness-based).
    if ! image_gen_start_service "$binary" "$config" "$log" "$health_url" >/dev/null; then
        [[ "$_had_xtrace" -eq 1 ]] && set -x
        _image_gen_die 1 "CLIProxyAPI did not become ready at $health_url (see log: $log)"; return 1
    fi

    # 10. Authenticated capability probe (FAIL-CLOSED). Poll /v1/models with
    # the local key within the configured timeout; require gpt-image-2. If
    # capability is never proven, refuse to delegate image_gen.py and exit
    # nonzero with an actionable diagnostic. The key is fed via curl stdin,
    # never argv, and never logged.
    local _cap_to="${IMAGE_GEN_CLIPROXYAPI_TIMEOUT:-$IMAGE_GEN_DEFAULT_TIMEOUT}"
    if ! image_gen_wait_capability "$base_url" "$key" "$_cap_to"; then
        [[ "$_had_xtrace" -eq 1 ]] && set -x
        _image_gen_die 1 "capability not proven at ${base_url}/models (gpt-image-2 with the local key) within ${_cap_to}s; OAuth/login may be inactive - run \`cliproxyapi --codex-login\` and retry"
        return 1
    fi

    # Delegate. The key is injected ONLY into the child environment; never argv.
    local _restore_base=0 _restore_key=0 _restore_model=0
    local _old_base="" _old_key="" _old_model=""
    if [[ -n "${OPENAI_BASE_URL+x}" ]]; then _old_base="$OPENAI_BASE_URL"; else _restore_base=1; fi
    if [[ -n "${OPENAI_API_KEY+x}" ]];  then _old_key="$OPENAI_API_KEY";   else _restore_key=1;  fi
    if [[ -n "${IMAGE_GEN_MODEL+x}" ]]; then _old_model="$IMAGE_GEN_MODEL"; else _restore_model=1; fi

    export OPENAI_BASE_URL="$base_url"
    export OPENAI_API_KEY="$key"
    export IMAGE_GEN_MODEL="$IMAGE_GEN_DEFAULT_MODEL"

    python3 "$upstream" "$@"; rc=$?

    if [[ "$_restore_base" -eq 1 ]]; then unset OPENAI_BASE_URL; else export OPENAI_BASE_URL="$_old_base"; fi
    if [[ "$_restore_key"  -eq 1 ]]; then unset OPENAI_API_KEY;  else export OPENAI_API_KEY="$_old_key";   fi
    if [[ "$_restore_model" -eq 1 ]]; then unset IMAGE_GEN_MODEL; else export IMAGE_GEN_MODEL="$_old_model"; fi

    unset key _old_base _old_key _old_model base_url

    [[ "$_had_xtrace" -eq 1 ]] && set -x
    return "$rc"
}

# ------------------------------------------------------------
# Direct execution guard. Lives at the end so all functions are defined
# before main is invoked (direct invocation no longer exits 127).
# ------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    image_gen_main "$@"
    exit $?
fi

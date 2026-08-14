#!/usr/bin/env bash
# Claude Code status line — gradient progress bars
# Shows: model, dir, git branch, context window, 5h usage (Anthropic or GLM)

# Cross-platform home directory (Windows $HOME may be wrong)
_HOME="${USERPROFILE:-$HOME}"

# Ensure jq is available (check ~/.claude/bin/ for Windows installs)
if ! command -v jq &>/dev/null; then
    for _p in "$_HOME/.claude/bin/jq.exe" "$_HOME/.claude/bin/jq"; do
        if [ -x "$_p" ]; then
            export PATH="$(dirname "$_p"):$PATH"
            break
        fi
    done
fi
if ! command -v jq &>/dev/null; then
    printf "Claude (jq not found - run installer or install jq)"
    exit 0
fi

input=$(cat)

# --- Extract fields ---
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.cwd // ""')
dir_name=$(basename "$cwd")

# Context window
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

# Git branch
git_branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree --no-optional-locks 2>/dev/null | grep -q true; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null || echo "")
fi

# --- Icon detection ---
_use_emoji=false
# Non-Windows: check UTF-8 locale
if [ -z "${USERPROFILE:-}" ]; then
    case "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) _use_emoji=true ;;
    esac
else
    # Windows: only enable emoji for terminals known to support Unicode
    # WT_SESSION  = Windows Terminal
    # MSYSTEM     = Git Bash / mintty (MINGW64, MINGW32, MSYS, etc.)
    # TERM_PROGRAM whitelist: vscode (VS Code integrated terminal)
    if [ -n "${WT_SESSION:-}" ] || [ -n "${MSYSTEM:-}" ]; then
        _use_emoji=true
    fi
    case "${TERM_PROGRAM:-}" in
        vscode) _use_emoji=true ;;
    esac
fi
# Always disable for known dumb terminals
case "${TERM:-dumb}" in
    dumb|linux|vt100|vt220) _use_emoji=false ;;
esac

if $_use_emoji; then
    ICON_MODEL="\xf0\x9f\xa7\xa0"     # 🧠
    ICON_DIR="\xf0\x9f\x93\x82"       # 📂
    ICON_CONDA="\xf0\x9f\x90\x8d"     # 🐍
    ICON_GIT="\xe2\x8e\x87"           # ⎇ (standard Unicode, safe everywhere)
else
    ICON_MODEL="M:"
    ICON_DIR="D:"
    ICON_CONDA="py:"
    ICON_GIT="br:"
fi

# --- 5-hour usage from API (non-blocking, async refresh) ---
# Strategy: statusline ONLY reads from cache (never blocks on network).
# If cache is stale, a background process refreshes it for next render.
#
# The backend is derived from $ANTHROPIC_BASE_URL, which the launcher exports
# per terminal. Cache and lock names carry a per-backend fingerprint so that
# terminals on different backends (or different accounts on the same backend)
# never read or overwrite each other's numbers.
_TMPDIR="${TMPDIR:-${TMP:-/tmp}}"

USAGE_BACKEND=other
case "${ANTHROPIC_BASE_URL:-}" in
    "")            USAGE_BACKEND=anthropic ;;
    *bigmodel.cn*) USAGE_BACKEND=glm ;;
    *z.ai*)        USAGE_BACKEND=glm ;;
esac

# Opt-out: set CL_NO_USAGE=1 (export it from ~/.zshrc — a one-shot prefix
# assignment is not enough, the launcher does not re-export it) to disable all
# quota fetching and hide the usage segment entirely.
[ -n "${CL_NO_USAGE:-}" ] && USAGE_BACKEND=other

# Backend credentials live in the environment; Anthropic's OAuth token is read
# from the keychain inside the background fetch only, so it never widens this
# path. Both variables are backend-neutral so the generic helpers below (cache
# fingerprint, lock naming) never reference a backend-specific name.
USAGE_SECRET=""
USAGE_ENDPOINT_BASE=""
if [ "$USAGE_BACKEND" = "glm" ]; then
    USAGE_SECRET="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
    # Derive scheme+host only: the quota endpoint sits at the domain root, not
    # under the Anthropic-compat path prefix. Mainland and international
    # deployments use different domains, so nothing is hardcoded.
    case "${ANTHROPIC_BASE_URL:-}" in
        *://*)
            _u_scheme="${ANTHROPIC_BASE_URL%%://*}"
            _u_rest="${ANTHROPIC_BASE_URL#*://}"
            USAGE_ENDPOINT_BASE="${_u_scheme}://${_u_rest%%/*}"
            ;;
    esac
    if [ -z "$USAGE_SECRET" ] || [ -z "$USAGE_ENDPOINT_BASE" ]; then
        USAGE_BACKEND=other
    fi
fi

# cksum is POSIX and present on every supported platform including Git Bash,
# unlike shasum/md5. The credential itself is never written to disk.
usage_fingerprint() {
    local secret="$1" sum="" out=""
    if [ -n "$secret" ]; then
        out=$(printf '%s' "$secret" | cksum 2>/dev/null)
        # cksum prints "<checksum> <bytes>"; parameter expansion avoids an
        # awk fork on every render.
        sum="${out%% *}"
        case "$sum" in ''|*[!0-9]*) sum="" ;; esac
    fi
    if [ -n "$sum" ]; then
        printf '%s-%s' "$USAGE_BACKEND" "$sum"
    else
        printf '%s' "$USAGE_BACKEND"
    fi
}
_USAGE_FP=$(usage_fingerprint "$USAGE_SECRET")
USAGE_CACHE="$_TMPDIR/claude-usage-cache-${_USAGE_FP}.json"
USAGE_LOCK="$_TMPDIR/claude-usage-fetch-${_USAGE_FP}.lock.d"

# CACHE_TTL     = how old the cache may get before a background refresh starts
# CACHE_MAX_AGE = how old the cache may get before the numbers stop rendering
# USAGE_ERR_BACKOFF = how long a failure suppresses further fetch attempts.
# It must never be shorter than CACHE_TTL, otherwise a failing backend would be
# polled *more* often than a healthy one.
case "$USAGE_BACKEND" in
    glm)
        # Zhipu applies undisclosed rate-limit / risk-control rules to its plan
        # endpoints, so poll an order of magnitude less often than the native
        # API (10x/3x the anthropic values) and back off at least a full TTL.
        CACHE_TTL=600
        CACHE_MAX_AGE=1800
        USAGE_ERR_BACKOFF=600
        ;;
    *)
        # Native Anthropic (and any future backend): the quota endpoint is
        # first-party and cheap, so refresh aggressively.
        CACHE_TTL=60
        CACHE_MAX_AGE=600  # 10min — don't display data older than this
        USAGE_ERR_BACKOFF=300
        ;;
esac
usage_5h=""
usage_resets=""
usage_resets_epoch=""

# Stale threshold: a fetch is curl --max-time 5 plus a keychain/powershell
# lookup, so it finishes well inside 120s on any healthy machine. Anything
# older than that is a crashed or killed fetch, not a slow one.
USAGE_LOCK_STALE=120

_usage_dir_age() {
    local mt
    mt=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - mt ))
}

# mkdir is atomic on every filesystem we care about: whoever creates the
# directory owns the refresh. Stale locks are reclaimed so one crashed fetch
# cannot wedge the statusline permanently.
#
# Reclaiming is itself guarded by a second mkdir lock. Without it the
# stat -> rm -rf -> mkdir sequence is a TOCTOU race: several renders can all
# judge the lock stale, and a late rm -rf deletes the lock a peer just created,
# leaving two "holders" that both hit the upstream API concurrently.
usage_lock_acquire() {
    mkdir "$USAGE_LOCK" 2>/dev/null && return 0
    [ "$(_usage_dir_age "$USAGE_LOCK")" -gt "$USAGE_LOCK_STALE" ] \
        || [ "$(_usage_dir_age "$USAGE_LOCK")" -lt 0 ] || return 1

    local reclaim="$USAGE_LOCK.reclaim"
    if ! mkdir "$reclaim" 2>/dev/null; then
        # Someone else is already reclaiming — unless that reclaim itself died,
        # in which case break it and let the next render retry. The reclaim
        # holder is only ever alive for an rm+mkdir pair, so it can use the
        # same staleness threshold without deadlocking against a live fetch.
        local rage
        rage=$(_usage_dir_age "$reclaim")
        if [ "$rage" -gt "$USAGE_LOCK_STALE" ] || [ "$rage" -lt 0 ]; then
            rm -rf "$reclaim" 2>/dev/null
        fi
        return 1
    fi

    # Re-check under the reclaim lock: a peer may have already reclaimed and be
    # holding a fresh lock by now.
    local ok=1
    if ! mkdir "$USAGE_LOCK" 2>/dev/null; then
        local age
        age=$(_usage_dir_age "$USAGE_LOCK")
        if [ "$age" -gt "$USAGE_LOCK_STALE" ] || [ "$age" -lt 0 ]; then
            rm -rf "$USAGE_LOCK" 2>/dev/null
            mkdir "$USAGE_LOCK" 2>/dev/null && ok=0
        fi
    else
        ok=0
    fi
    rm -rf "$reclaim" 2>/dev/null
    return $ok
}

usage_lock_release() {
    rm -rf "$USAGE_LOCK" 2>/dev/null
}

# Write stdin to the cache via a same-directory rename so a concurrent reader
# can never observe a partially written file.
usage_cache_write() {
    local tmpf="$USAGE_CACHE.$$.tmp"
    cat > "$tmpf" 2>/dev/null || { rm -f "$tmpf" 2>/dev/null; return 1; }
    if [ ! -s "$tmpf" ]; then
        rm -f "$tmpf" 2>/dev/null
        return 1
    fi
    mv -f "$tmpf" "$USAGE_CACHE" 2>/dev/null
}

# Negative cache: record the failure so renders back off instead of hammering
usage_cache_fail() {
    echo "${1:-000}" > "$USAGE_CACHE.err" 2>/dev/null
}

# Emit a curl config file (for `curl -K -`) declaring each argument as a
# request header. Keeping credentials on stdin rather than in argv means they
# never show up in `ps` output for other users on the machine.
# curl's config parser only honours \\ \" \t \n \r \v inside a double-quoted
# value, so backslash and double quote are the only characters needing escapes.
usage_curl_headers() {
    local h esc
    for h in "$@"; do
        esc=${h//\\/\\\\}
        esc=${esc//\"/\\\"}
        printf 'header = "%s"\n' "$esc"
    done
}

fetch_anthropic_usage() {
    local token kc_json raw="$USAGE_CACHE.$$.raw"
    # 1) macOS Keychain
    kc_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    # 2) Linux libsecret (GNOME Keyring / KWallet)
    [ -z "$kc_json" ] && kc_json=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
    # 3) Windows Credential Manager (Git Bash / MSYS2)
    if [ -z "$kc_json" ] && command -v powershell.exe &>/dev/null; then
        kc_json=$(powershell.exe -NoProfile -NoLogo -Command '
            try {
                $cred = Get-StoredCredential -Target "Claude Code-credentials" -ErrorAction Stop
                if ($cred) { [System.Net.NetworkCredential]::new("", $cred.Password).Password }
            } catch {
                try {
                    Add-Type -AssemblyName System.Security
                    $path = Join-Path $env:LOCALAPPDATA "claude-code\credentials.json"
                    if (Test-Path $path) { Get-Content $path -Raw }
                } catch {}
            }
        ' 2>/dev/null)
    fi
    if [ -n "$kc_json" ]; then
        token=$(echo "$kc_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    # 4) Fall back to credentials file
    if [ -z "$token" ]; then
        local creds="$_HOME/.claude/.credentials.json"
        [ -f "$creds" ] || return
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
    fi
    [ -z "$token" ] && return

    local http_code ua
    ua=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'unknown')
    [ -z "$ua" ] && ua="unknown"
    # Headers are fed through a curl config file on stdin (-K -) instead of -H
    # so the bearer token never appears in this process's argv, where any local
    # user's `ps` would show it.
    # Inherit proxy from environment (all_proxy, https_proxy, etc.)
    http_code=$(usage_curl_headers \
            "Authorization: Bearer $token" \
            "Content-Type: application/json" \
            "User-Agent: claude-code/$ua" \
            "anthropic-beta: oauth-2025-04-20" \
        | curl -K - -s -o "$raw" -w '%{http_code}' \
            --connect-timeout 2 --max-time 5 \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

    if [ "$http_code" = "200" ] && [ -s "$raw" ] \
        && jq -e '(.five_hour.utilization | type) == "number"' "$raw" &>/dev/null; then
        usage_cache_write < "$raw" && rm -f "$USAGE_CACHE.err"
    else
        usage_cache_fail "$http_code"
    fi
    rm -f "$raw" 2>/dev/null
}

fetch_glm_usage() {
    local raw="$USAGE_CACHE.$$.raw" http_code norm
    # The plan quota endpoint takes the raw API key — prefixing it with
    # "Bearer" makes it 401. The key is a long-lived plan credential, so it is
    # passed via a stdin curl config (-K -) and never through argv.
    http_code=$(usage_curl_headers \
            "Authorization: $USAGE_SECRET" \
            "Accept-Language: en-US,en" \
            "Content-Type: application/json" \
        | curl -K - -s -o "$raw" -w '%{http_code}' \
            --connect-timeout 2 --max-time 5 \
            "$USAGE_ENDPOINT_BASE/api/monitor/usage/quota/limit" 2>/dev/null)

    norm=""
    if [ "$http_code" = "200" ] && [ -s "$raw" ]; then
        # Several TOKENS_LIMIT windows are returned (5h plus longer ones).
        # Zhipu encodes the window size inconsistently across its own clients,
        # so no `unit`/`duration`/`window` field can be trusted to exist or to
        # keep its spelling — reading one would break silently the moment the
        # response is reshaped. What can be relied on is a bound that holds by
        # construction: the 5h window's next reset is always within 5h of now.
        #
        # So: keep only windows resetting within now+6h (an hour of slack for
        # clock skew), and identify the 5h window only when exactly one
        # candidate survives. "Take the soonest" is deliberately NOT used: a
        # longer window in the last minutes before its own reset also passes
        # the bound and would then be relabelled as the 5h window, showing a
        # confidently wrong number. Nothing in the response distinguishes the
        # two at that point, so the ambiguous case renders nothing at all — a
        # missing segment is recoverable, a wrong percentage is not. For a 5h
        # + weekly pair this blanks roughly 6h out of every 168h.
        #
        # nextResetTime is a rolling deadline in milliseconds; it must be taken
        # from the response rather than computed from a clock boundary. jq's
        # `now` is float seconds, so it is scaled to match.
        # percentage is type-checked here: a non-numeric value (e.g. "N/A")
        # must drop the whole segment, not reach the renderer's arithmetic.
        norm=$(jq -c '
            if (.success == true) then
                (.data.limits // [])
                | map(select(.type == "TOKENS_LIMIT"
                             and (.percentage | type) == "number"
                             and (.nextResetTime | type) == "number"
                             and ((.nextResetTime / 1000) - now) <= (6 * 3600)))
                | if length == 1 then
                      .[0] | {five_hour: {
                        utilization: .percentage,
                        resets_epoch: (.nextResetTime / 1000 | floor)
                      }}
                  else empty
                  end
            else empty end' "$raw" 2>/dev/null)
    fi

    if [ -n "$norm" ]; then
        printf '%s\n' "$norm" | usage_cache_write && rm -f "$USAGE_CACHE.err"
    else
        usage_cache_fail "$http_code"
    fi
    rm -f "$raw" 2>/dev/null
}

# Background fetch: updates cache file, never blocks the statusline
bg_fetch_usage() {
    usage_lock_acquire || return
    case "$USAGE_BACKEND" in
        anthropic) fetch_anthropic_usage ;;
        glm)       fetch_glm_usage ;;
    esac
    usage_lock_release
}

now=$(date +%s)

if [ "$USAGE_BACKEND" != "other" ]; then
    # Read from cache (instant, no network)
    cache_is_fresh=false
    if [ -f "$USAGE_CACHE" ]; then
        cache_mtime=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0)
        cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$CACHE_TTL" ]; then
            cache_is_fresh=true
        fi
        # Display from cache only if not too old.
        # One jq call for all three fields instead of three. The separator must
        # not be whitespace: `read` collapses runs of IFS whitespace, which
        # would silently shift fields whenever one is empty (only one of
        # resets_at / resets_epoch is ever present). \x1f is non-whitespace, so
        # empty fields are preserved positionally.
        if [ "$cache_age" -lt "$CACHE_MAX_AGE" ]; then
            _usage_row=$(jq -r '.five_hour
                | [(.utilization // ""), (.resets_at // ""), (.resets_epoch // "")]
                | join("\u001f")' "$USAGE_CACHE" 2>/dev/null)
            IFS=$'\x1f' read -r usage_5h usage_resets usage_resets_epoch <<< "$_usage_row"
        fi
    fi

    # A cache written by an older version (or corrupted on disk) may hold a
    # non-numeric utilization. Reject anything that is not a plain decimal here
    # so the arithmetic further down can never fail: the segment simply
    # disappears, which is the required degradation mode.
    case "$usage_5h" in
        ''|*[!0-9.]*|.|*.*.*) usage_5h="" ;;
    esac

    # If cache is stale or missing, trigger async background refresh
    # But respect negative cache: skip if the last failure is still inside the
    # per-backend backoff window.
    if ! $cache_is_fresh; then
        _should_fetch=true
        if [ -f "$USAGE_CACHE.err" ]; then
            _err_mtime=$(stat -c %Y "$USAGE_CACHE.err" 2>/dev/null || stat -f %m "$USAGE_CACHE.err" 2>/dev/null || echo 0)
            _err_age=$(( now - _err_mtime ))
            [ "$_err_age" -lt "$USAGE_ERR_BACKOFF" ] && _should_fetch=false
        fi
        if $_should_fetch; then
            bg_fetch_usage &>/dev/null &
            disown 2>/dev/null
        fi
    fi
fi

# --- Terminal width ---
# Claude Code runs statusline in a pipe (no tty on stdin), so $COLUMNS
# and `tput cols` are unreliable. Probe the real terminal via /dev/pts/*.
_get_term_width() {
    # 1) $COLUMNS if set and positive
    local c="${COLUMNS:-0}"
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && { echo "$c"; return; }

    # 2) Walk ancestor process fds to find the real terminal (Linux)
    local _pid=$$
    while [ "$_pid" -gt 1 ] 2>/dev/null; do
        for _fd in /proc/"$_pid"/fd/*; do
            [ -e "$_fd" ] || continue
            local _tgt
            _tgt=$(readlink "$_fd" 2>/dev/null) || continue
            case "$_tgt" in /dev/pts/*|/dev/tty*)
                c=$(stty size < "$_tgt" 2>/dev/null | awk '{print $2}')
                [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && { echo "$c"; return; }
            esac
        done
        _pid=$(awk '{print $4}' /proc/"$_pid"/stat 2>/dev/null) || break
    done

    # 3) Try tput cols as last resort before fallback
    c=$(tput cols 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && { echo "$c"; return; }

    # 4) Fallback
    echo 120
}
COLUMNS=$(_get_term_width)

# visible_len: compute display width of a string with ANSI escapes
# Strips escape codes, then uses wc -L for accurate multi-byte/emoji width
visible_len() {
    local stripped w
    stripped=$(printf "%b" "$1" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g')
    # wc -L gives display width (handles CJK/emoji double-width) — GNU only
    w=$(printf "%b" "$stripped" | wc -L 2>/dev/null | tr -d ' ')
    # Fallback for macOS/BSD where wc -L is unavailable
    if [ -z "$w" ] || [ "$w" -eq 0 ] 2>/dev/null; then
        w=${#stripped}
    fi
    echo "$w"
}

# --- Colors ---
C_MODEL="\033[38;5;183m"
C_DIR="\033[38;5;117m"
C_GIT="\033[38;5;116m"
C_SEP="\033[38;5;240m"
C_LABEL="\033[38;5;250m"
C_CONDA="\033[38;5;113m"   # soft green (Python/conda)
C_R="\033[0m"

# Gradient: soft green -> green -> yellow-green -> yellow -> orange -> red -> dark red
bar_colors=(71 72 78 114 150 186 222 221 220 214 208 202 196 160 124 88)
BAR_W=20

build_bar() {
    local pct=$1 w=${2:-$BAR_W}
    local filled=$(( pct * w / 100 ))
    [ "$filled" -gt "$w" ] && filled=$w
    local empty=$(( w - filled ))
    local bar="" nc=${#bar_colors[@]}

    for ((i = 0; i < filled; i++)); do
        local ci=$(( i * nc / w ))
        [ "$ci" -ge "$nc" ] && ci=$((nc - 1))
        bar+="\033[38;5;${bar_colors[$ci]}m\xe2\x96\x88"
    done
    for ((i = 0; i < empty; i++)); do
        bar+="\033[38;5;238m\xe2\x96\x91"
    done

    # Percentage color
    local pc=72
    [ "$pct" -ge 40 ] && pc=222
    [ "$pct" -ge 65 ] && pc=208
    [ "$pct" -ge 85 ] && pc=196

    printf "%b \033[38;5;${pc}m%d%%$C_R" "$bar" "$pct"
}

# Format context size
fmt_ctx() {
    local s=${1:-0}
    if [ "$s" -ge 1000000 ]; then
        echo "$(( s / 1000 / 1000 )).$(( s / 1000 % 1000 / 100 ))M"
    elif [ "$s" -ge 1000 ]; then
        echo "$(( s / 1000 ))k"
    else
        echo "$s"
    fi
}

# Format an absolute epoch as a relative countdown
fmt_reltime() {
    local reset_epoch="$1"
    case "$reset_epoch" in
        ''|*[!0-9]*) return ;;
    esac
    local diff=$(( reset_epoch - now ))
    [ "$diff" -le 0 ] && { echo "now"; return; }
    local h=$(( diff / 3600 )) m=$(( diff % 3600 / 60 ))
    if [ "$h" -gt 0 ]; then
        echo "${h}h${m}m"
    else
        echo "${m}m"
    fi
}

# Format ISO 8601 reset time as relative
fmt_resets() {
    local resets_at="$1"
    [ -z "$resets_at" ] && return
    # Strip microseconds and timezone offset, treat as UTC
    # "2026-03-05T13:00:00.293168+00:00" -> "2026-03-05T13:00:00"
    local clean
    clean=$(echo "$resets_at" | sed 's/\.[0-9]*//; s/[+-][0-9][0-9]:[0-9][0-9]$//; s/Z$//')
    local reset_epoch
    # macOS: TZ=UTC date -j -f, Linux: date -d (handles ISO natively)
    reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null \
        || date -d "$resets_at" +%s 2>/dev/null) || return
    fmt_reltime "$reset_epoch"
}

# --- Assemble segments ---
segments=()
sep_visible_w=3  # " │ " is 3 visible characters

# Segment 1: Model
segments+=("${ICON_MODEL} ${C_MODEL}${model}${C_R}")

# Segment 2: Directory
if [ -n "$dir_name" ]; then
    segments+=("${ICON_DIR} ${C_DIR}${dir_name}${C_R}")
fi

# Segment 3: Conda/venv
conda_env="${CONDA_DEFAULT_ENV:-}"
conda_env="$(basename "$conda_env")"
venv="${VIRTUAL_ENV:-}"
venv="$(basename "$venv")"

if [ -n "$conda_env" ]; then
    segments+=("${ICON_CONDA} ${C_CONDA}${conda_env}${C_R}")
elif [ -n "$venv" ]; then
    segments+=("${ICON_CONDA} ${C_CONDA}${venv}${C_R}")
fi

# Segment 4: Git branch
if [ -n "$git_branch" ]; then
    segments+=("${C_GIT}${ICON_GIT} ${git_branch}${C_R}")
fi

# Pre-compute widths of all segments (cached for reuse)
_seg_widths=()
_pre_w=0
for _s in "${segments[@]}"; do
    local_w=$(visible_len "$_s")
    local_w=${local_w:-0}
    _seg_widths+=("$local_w")
    [ "$_pre_w" -gt 0 ] && _pre_w=$(( _pre_w + sep_visible_w ))
    _pre_w=$(( _pre_w + local_w ))
done

# Segment 5: Context bar (adaptive width)
ctx_pct_int=$(printf "%.0f" "$ctx_pct" 2>/dev/null || echo "$ctx_pct")
ctx_fmt=$(fmt_ctx "$ctx_size")
# Estimate overhead: "context " (8) + " " (1) + pct "XX%" (3-4) + " " (1) + ctx_fmt (~4) ≈ 18
ctx_label_overhead=18
ctx_bar_w=$BAR_W
ctx_remaining=$(( COLUMNS - _pre_w - sep_visible_w - ctx_label_overhead ))
if [ "$ctx_remaining" -lt "$BAR_W" ]; then
    ctx_bar_w=$(( ctx_remaining >= 8 ? ctx_remaining : BAR_W ))
fi
ctx_bar=$(build_bar "$ctx_pct_int" "$ctx_bar_w")
_ctx_seg="${C_LABEL}context${C_R} ${ctx_bar} ${C_LABEL}${ctx_fmt}${C_R}"
segments+=("$_ctx_seg")
_ctx_w=$(visible_len "$_ctx_seg"); _ctx_w=${_ctx_w:-0}
_seg_widths+=("$_ctx_w")

# Segment 6: 5-hour usage bar (adaptive width)
if [ -n "$usage_5h" ]; then
    # `printf %.0f` emits a partial "0" *before* failing on a bad operand, so
    # its output is only trustworthy after a second integer check.
    usage_pct=$(printf "%.0f" "$usage_5h" 2>/dev/null)
    case "$usage_pct" in
        ''|*[!0-9]*) usage_pct="" ;;
    esac
fi
if [ -n "$usage_pct" ]; then
    if [ -n "$usage_resets_epoch" ]; then
        resets_fmt=$(fmt_reltime "$usage_resets_epoch")
    else
        resets_fmt=$(fmt_resets "$usage_resets")
    fi
    # Non-native backends are labelled so two terminals side by side are
    # distinguishable; a bare "5h" is always the native Anthropic quota.
    usage_label="5h"
    [ "$USAGE_BACKEND" = "glm" ] && usage_label="glm 5h"
    # Overhead: "5h " (3) + " " (1) + pct "XX%" (3-4) + " " (1) + resets (~5) ≈ 14
    usage_label_overhead=$(( 14 + ${#usage_label} - 2 ))
    usage_bar_w=$BAR_W

    # Re-compute cumulative width including segment 5 (use cached widths + new segment)
    _pre_w=0
    for _w in "${_seg_widths[@]}"; do
        [ "$_pre_w" -gt 0 ] && _pre_w=$(( _pre_w + sep_visible_w ))
        _pre_w=$(( _pre_w + _w ))
    done

    usage_remaining=$(( COLUMNS - _pre_w - sep_visible_w - usage_label_overhead ))
    if [ "$usage_remaining" -lt "$BAR_W" ]; then
        usage_bar_w=$(( usage_remaining >= 8 ? usage_remaining : BAR_W ))
    fi

    usage_bar=$(build_bar "$usage_pct" "$usage_bar_w")
    usage_seg="${C_LABEL}${usage_label}${C_R} ${usage_bar}"
    [ -n "$resets_fmt" ] && usage_seg+=" ${C_LABEL}${resets_fmt}${C_R}"
    segments+=("$usage_seg")
    _usage_w=$(visible_len "$usage_seg"); _usage_w=${_usage_w:-0}
    _seg_widths+=("$_usage_w")
fi

# --- Wrap algorithm ---
sep_str="${C_SEP} \xe2\x94\x82 ${C_R}"

out=""
line_w=0

_seg_idx=0
for seg in "${segments[@]}"; do
    seg_w=${_seg_widths[$_seg_idx]:-0}
    _seg_idx=$(( _seg_idx + 1 ))
    needed=$seg_w
    [ "$line_w" -gt 0 ] && needed=$(( seg_w + sep_visible_w ))

    if [ "$line_w" -gt 0 ] && [ $(( line_w + needed )) -gt "$COLUMNS" ]; then
        # Wrap to next line
        out+="\n"
        line_w=0
        needed=$seg_w
    fi

    if [ "$line_w" -gt 0 ]; then
        out+="$sep_str"
        line_w=$(( line_w + sep_visible_w ))
    fi

    out+="$seg"
    line_w=$(( line_w + seg_w ))
done

printf "%b" "$out"

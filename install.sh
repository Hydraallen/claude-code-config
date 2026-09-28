#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Awesome Claude Code Configuration Installer
# https://github.com/Hydraallen/claude-code-config (fork of Mizoreww/awesome-agent-config)
# ============================================================

CLAUDE_DIR="$HOME/.claude"
REPO_OWNER="${REPO_OWNER:-Hydraallen}"
REPO_NAME="${REPO_NAME:-claude-code-config}"
REPO_BRANCH="${REPO_BRANCH:-main}"
# These values are interpolated into URLs that, in remote mode, are evaluated by
# `bash -c` (see detect_script_dir). Validate against a safe charset to prevent
# command injection from a hostile/garbled environment. (error() is not defined
# yet at this point in the script, so emit to stderr directly.)
if [[ ! "$REPO_OWNER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid REPO_OWNER: $REPO_OWNER" >&2; exit 1
fi
if [[ ! "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid REPO_NAME: $REPO_NAME" >&2; exit 1
fi
if [[ ! "$REPO_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "Invalid REPO_BRANCH: $REPO_BRANCH" >&2; exit 1
fi
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
# Legacy stamp filename kept so existing installs (and update-config) still
# find their recorded version after the fork rename.
VERSION_STAMP_FILE="$CLAUDE_DIR/.awesome-claude-code-config-version"
# Deployable Claude templates live under platforms/claude/templates/ since the
# upstream v4 layout (shared with the agent-guided install path). Set by
# detect_script_dir once SCRIPT_DIR is known.
CLAUDE_TEMPLATES_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Wall-clock cap for a single network operation (marketplace/plugin fetch).
# This is a backstop, not the primary bound: the `claude` CLI caps its own clone
# and cache refresh at 120s. Staying above that lets the CLI hit its limit first
# and clean up its own child `git`, which a kill from here cannot reach.
# Attempt counts are 2 rather than 3 to keep the worst case bounded despite the
# higher cap: 2 x 180 + 3 = 363s per marketplace, ~243s in practice since the
# CLI's own 120s fires first. Raise it on very slow links: NET_TIMEOUT=300
NET_TIMEOUT="${NET_TIMEOUT:-180}"

# Abort a git transfer that stalls under 1 KiB/s for 30s rather than hanging
# forever on a half-dead connection. Exported so the git processes that the
# `claude plugin ...` CLI spawns inherit them.
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1024}"
export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-30}"

# Never let git stop to ask for credentials — an unattended installer has no tty
# to answer with, so a private/renamed repo must fail fast instead of hanging.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GIT_ASKPASS="${GIT_ASKPASS:-/bin/true}"
export GCM_INTERACTIVE="${GCM_INTERACTIVE:-never}"

# with_timeout <seconds> <command...>: run the command, kill it if it outlives
# <seconds>. Returns the command's status, or 124 on timeout (matching
# timeout(1)). stdin is closed so a child that prompts gets EOF instead of
# blocking forever on a tty.
#
# Order of preference is coreutils timeout(1)/gtimeout(1), then perl, then a
# bash watchdog. macOS ships neither coreutils binary but always ships perl,
# whose alarm(2) gives a timer inside the waiting process itself — nothing to
# orphan. The bash watchdog is last because its timer is a `sleep` in a forked
# subshell: killing the subshell orphans the `sleep`, which then holds the
# caller's inherited stdout/stderr open until it expires. Any reader waiting for
# EOF (a pipe, `$(...)`, a log capture) stalls for the full <seconds> even when
# the command succeeded immediately.
#
# `--foreground` is mandatory on the coreutils branches, not cosmetic. Without
# it timeout(1) calls setpgid(2) before forking, so the command runs in a
# process group that is not the terminal's foreground group. `claude` is an Ink
# TUI: it calls tcsetattr(3) on the tty during startup, and a tcsetattr from a
# background process group raises SIGTTOU, whose default action stops the
# process. The command freezes within seconds — after printing, since writes
# from a background group are allowed while TOSTOP is off — and timeout only
# reaps the stopped process at expiry, so every attempt burns its full cap
# having done no work. In foreground mode timeout signals only the direct
# child rather than a whole group, so `--kill-after` restores the
# TERM-then-KILL escalation the perl branch does by hand, with the same 5s
# grace so every backend agrees on how long a TERM-ignoring child gets.
#
# Only GNU coreutils understands those flags. The busybox applet of the same
# name rejects them outright, and it has no need for them either — it does not
# setpgid, so it never had the freeze. `command -v timeout` cannot tell the two
# apart, so each binary is probed once with the exact flag set that will be
# used, and the verdict cached in a plain scalar (bash 3.2 has no associative
# arrays). A binary that fails the probe is skipped entirely and the next
# backend takes over; falling back to a flag-less timeout(1) is not an option,
# because on a GNU system that is exactly the freeze described above.
_TIMEOUT_FOREGROUND_OK=""
_GTIMEOUT_FOREGROUND_OK=""

timeout_supports_foreground() {
    case "$1" in
        timeout)
            if [[ -z "${_TIMEOUT_FOREGROUND_OK:-}" ]]; then
                if timeout --foreground --kill-after=5 1 true >/dev/null 2>&1; then
                    _TIMEOUT_FOREGROUND_OK=yes
                else
                    _TIMEOUT_FOREGROUND_OK=no
                fi
            fi
            [[ "$_TIMEOUT_FOREGROUND_OK" == yes ]]
            ;;
        gtimeout)
            if [[ -z "${_GTIMEOUT_FOREGROUND_OK:-}" ]]; then
                if gtimeout --foreground --kill-after=5 1 true >/dev/null 2>&1; then
                    _GTIMEOUT_FOREGROUND_OK=yes
                else
                    _GTIMEOUT_FOREGROUND_OK=no
                fi
            fi
            [[ "$_GTIMEOUT_FOREGROUND_OK" == yes ]]
            ;;
        *) return 1 ;;
    esac
}

# Which branch of with_timeout is live here. Printed once so a stalled install
# reported from someone else's machine can be diagnosed from its log alone. The
# probe is part of the test so the label names the branch actually taken.
timeout_backend() {
    if command -v timeout &>/dev/null && timeout_supports_foreground timeout; then
        echo "timeout(1) --foreground"
    elif command -v gtimeout &>/dev/null && timeout_supports_foreground gtimeout; then
        echo "gtimeout(1) --foreground"
    elif command -v perl &>/dev/null; then echo "perl"
    else echo "bash watchdog"
    fi
}

with_timeout() {
    local secs="$1"; shift
    local status=0
    if command -v timeout &>/dev/null && timeout_supports_foreground timeout; then
        timeout --foreground --kill-after=5 "$secs" "$@" </dev/null || status=$?
        # A child that ignores TERM is reaped by the follow-up KILL, which
        # timeout reports as 137. Report it as the timeout it was, so all
        # branches agree on 124.
        if (( status == 137 )); then status=124; fi
        return $status
    fi
    if command -v gtimeout &>/dev/null && timeout_supports_foreground gtimeout; then
        gtimeout --foreground --kill-after=5 "$secs" "$@" </dev/null || status=$?
        if (( status == 137 )); then status=124; fi
        return $status
    fi
    if command -v perl &>/dev/null; then
        # Waits in the parent and exits 124 itself rather than letting SIGALRM
        # kill it, so the caller sees a clean status and no `Alarm clock`
        # message. Indirect-object exec never routes through a shell, so
        # command words containing spaces or metacharacters stay literal.
        perl -e '
            my $t = shift;
            my $pid = fork;
            exit 127 unless defined $pid;
            if ($pid == 0) { exec {$ARGV[0]} @ARGV; exit 127 }
            $SIG{ALRM} = sub {
                my $reaped = $?;
                # -1 means the main waitpid below already collected it: the
                # command finished on the same instruction boundary the alarm
                # fired on. Report its real status, not a timeout.
                if (waitpid($pid, 1) == -1) {   # 1 == WNOHANG
                    exit(($reaped & 127) ? 128 + ($reaped & 127) : $reaped >> 8);
                }
                kill "TERM", $pid;
                for (1 .. 50) {
                    last if waitpid($pid, 1) != 0;
                    select undef, undef, undef, 0.1;
                }
                kill "KILL", $pid;
                exit 124;
            };
            alarm $t;
            waitpid $pid, 0;
            alarm 0;
            exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
        ' "$secs" "$@" </dev/null || status=$?
        return $status
    fi

    "$@" </dev/null &
    local cmd_pid=$!
    # The watchdog's own output goes to /dev/null: if it outlives this call its
    # orphaned `sleep` must not keep the caller's pipe open.
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 5; kill -KILL "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watchdog_pid=$!
    wait "$cmd_pid" 2>/dev/null || status=$?
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    # A signalled command exits >128; report that as a timeout.
    if (( status > 128 )); then
        status=124
    fi
    return $status
}

# Retry wrapper: retry <max_attempts> <delay_seconds> <description> <command...>
# Returns 0 on success, 1 if all attempts fail.
retry() {
    local max_attempts="$1"; shift
    local delay="$1"; shift
    local description="$1"; shift
    local attempt=1

    while (( attempt <= max_attempts )); do
        if "$@" ; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            warn "$description failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
            sleep "$delay"
        else
            warn "$description failed after $max_attempts attempts, skipping."
        fi
        (( attempt++ ))
    done
    return 1
}

# Install jq if not available (needed for settings merge & statusline)
install_jq() {
    command -v jq &>/dev/null && return 0
    # Check ~/.claude/bin/jq
    if [[ -x "$CLAUDE_DIR/bin/jq" ]]; then
        export PATH="$CLAUDE_DIR/bin:$PATH"; return 0
    fi

    if $DRY_RUN; then
        info "Would install jq (not found in PATH or $CLAUDE_DIR/bin/)"
        return 0
    fi

    info "jq not found, attempting to install..."

    # 1) Download pre-built binary (no sudo, preferred for CI/headless)
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in darwin) os="macos";; linux) os="linux";; esac
    arch="$(uname -m)"
    case "$arch" in x86_64) arch="amd64";; aarch64|arm64) arch="arm64";; esac

    if [[ -n "${os:-}" && -n "${arch:-}" ]]; then
        local url="https://github.com/jqlang/jq/releases/latest/download/jq-${os}-${arch}"
        mkdir -p "$CLAUDE_DIR/bin"
        if curl -fsSL "$url" -o "$CLAUDE_DIR/bin/jq" 2>/dev/null || \
           wget -qO "$CLAUDE_DIR/bin/jq" "$url" 2>/dev/null; then
            chmod +x "$CLAUDE_DIR/bin/jq"
            export PATH="$CLAUDE_DIR/bin:$PATH"
            ok "jq installed to $CLAUDE_DIR/bin/jq"
            return 0
        fi
    fi

    # 2) Package manager chain (fallback, may need sudo)
    if command -v brew &>/dev/null; then
        brew install jq &>/dev/null && { ok "jq installed via brew"; return 0; }
    fi
    if command -v sudo &>/dev/null; then
        for pm_cmd in "apt-get install -y jq" "dnf install -y jq" \
                      "yum install -y jq" "pacman -S --noconfirm jq" "apk add jq"; do
            local pm="${pm_cmd%% *}"
            command -v "$pm" &>/dev/null && sudo $pm_cmd &>/dev/null && { ok "jq installed via $pm"; return 0; }
        done
    fi

    warn "Could not install jq automatically"
    return 1
}

# Install MesloLGS NF font for statusline icons (bundled in fonts/)
install_nerd_font() {
    # Check if already installed (fc-list first — more reliable than filename glob)
    if command -v fc-list &>/dev/null; then
        if fc-list 2>/dev/null | grep -qi "MesloLGS NF"; then
            return 0
        fi
    fi
    local font_dir
    case "$(uname -s)" in
        Darwin) font_dir="$HOME/Library/Fonts" ;;
        *)      font_dir="$HOME/.local/share/fonts" ;;
    esac
    # Fallback: check by font files directly (works without fontconfig)
    if ls "$font_dir"/MesloLGS\ NF* &>/dev/null 2>&1; then
        return 0
    fi

    if $DRY_RUN; then
        info "Would install MesloLGS NF font"
        return 0
    fi

    info "Installing MesloLGS NF font for statusline icons..."
    mkdir -p "$font_dir"

    # Copy bundled fonts from repository
    local src_dir="$CLAUDE_TEMPLATES_DIR/fonts"
    if [ ! -d "$src_dir" ] || ! ls "$src_dir"/*.ttf &>/dev/null 2>&1; then
        warn "Bundled fonts not found in $src_dir — statusline will use text fallback"
        return 1
    fi
    cp "$src_dir"/*.ttf "$font_dir"/

    # Verify copy succeeded
    if ! ls "$font_dir"/MesloLGS\ NF* &>/dev/null 2>&1; then
        warn "Font installation failed — no font files found"
        return 1
    fi
    # Refresh font cache
    if command -v fc-cache &>/dev/null; then
        fc-cache -f "$font_dir" 2>/dev/null || true
    fi
    ok "MesloLGS NF font installed to $font_dir"
    warn "Set your terminal font to 'MesloLGS NF' for best icon display"
    return 0
}

# --- Remote install detection -------------------------------------------

detect_script_dir() {
    local candidate
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$candidate/platforms/claude/templates/CLAUDE.md" ]]; then
        # Running from a local clone
        SCRIPT_DIR="$candidate"
        REMOTE_MODE=false
    else
        # Remote mode: download tarball to temp dir
        REMOTE_MODE=true
        # Not local — trap needs access after function returns (set -u)
        tmpdir="$(mktemp -d)"
        trap 'rm -rf "$tmpdir"' EXIT

        local version="${VERSION:-$REPO_BRANCH}"
        # Sanitize VERSION/branch to prevent command injection. Slash is allowed
        # so branch refs like "feature/foo" work; it is safe inside the quoted URL.
        if [[ ! "$version" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            error "Invalid VERSION value: $version (only alphanumeric, dots, slashes, hyphens, underscores allowed)"
            exit 1
        fi
        local tarball_url="$REPO_URL/archive/refs/heads/${version}.tar.gz"
        # If version looks like a tag (v1.0.0), use tags URL
        if [[ "$version" =~ ^v[0-9] ]]; then
            tarball_url="$REPO_URL/archive/refs/tags/${version}.tar.gz"
        fi

        info "Remote mode: downloading $version..."
        local download_cmd
        if command -v curl &>/dev/null; then
            download_cmd="curl -fsSL $tarball_url"
        elif command -v wget &>/dev/null; then
            download_cmd="wget -qO- $tarball_url"
        else
            error "Neither curl nor wget found. Install one and retry."
            exit 1
        fi

        if ! retry 5 3 "Download source tarball" bash -c "$download_cmd > '$tmpdir/.source.tar.gz' && tar xzf '$tmpdir/.source.tar.gz' -C '$tmpdir' --strip-components=1"; then
            error "Failed to download source after retries. Cannot continue in remote mode."
            exit 1
        fi
        # GitHub archives carry the commit id in a pax header; recorded in
        # agent-config/selection.json as the installed repository revision.
        if command -v git &>/dev/null; then
            # get-tar-commit-id stops after the header, so gzip may exit on
            # SIGPIPE; keep the output regardless of the pipeline status.
            SOURCE_REVISION="$(gzip -dc "$tmpdir/.source.tar.gz" 2>/dev/null | git get-tar-commit-id 2>/dev/null || true)"
            [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || SOURCE_REVISION=""
        fi
        rm -f "$tmpdir/.source.tar.gz"

        SCRIPT_DIR="$tmpdir"
        ok "Source downloaded to temporary directory"
    fi
    CLAUDE_TEMPLATES_DIR="$SCRIPT_DIR/platforms/claude/templates"
}

# Source directory of a repository skill. Claude-specific skills (currently
# adversarial-review) live under platforms/claude/skills/; shared skills under
# skills/. Echoes the first existing candidate, or the skills/ path when neither
# exists so callers report a clear "not found".
skill_source_dir() {
    local name="$1"
    if [[ -d "$SCRIPT_DIR/platforms/claude/skills/$name" ]]; then
        echo "$SCRIPT_DIR/platforms/claude/skills/$name"
    else
        echo "$SCRIPT_DIR/skills/$name"
    fi
}

# --- Version management -------------------------------------------------

get_source_version() {
    if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
        cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

get_installed_version() {
    if [[ -f "$VERSION_STAMP_FILE" ]]; then
        cat "$VERSION_STAMP_FILE" | tr -d '[:space:]'
    else
        echo "not installed"
    fi
}

get_remote_version() {
    local url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/VERSION"
    local result=""
    _fetch_version() {
        if command -v curl &>/dev/null; then
            result="$(curl -fsSL "$url" 2>/dev/null | tr -d '[:space:]')"
        elif command -v wget &>/dev/null; then
            result="$(wget -qO- "$url" 2>/dev/null | tr -d '[:space:]')"
        else
            return 1
        fi
        [[ -n "$result" ]]
    }
    if retry 5 2 "Fetch remote version" _fetch_version; then
        echo "$result"
    else
        echo "unavailable"
    fi
}

show_version() {
    local source_ver installed_ver remote_ver
    source_ver="$(get_source_version)"
    installed_ver="$(get_installed_version)"
    remote_ver="$(get_remote_version)"

    echo "claude-code-config version info:"
    echo "  Source:    $source_ver"
    echo "  Installed: $installed_ver"
    echo "  Remote:    $remote_ver"

    if [[ "$installed_ver" != "not installed" && "$remote_ver" != "unavailable" \
          && "$installed_ver" != "$remote_ver" ]]; then
        warn "Update available: $installed_ver -> $remote_ver"
    fi
}

stamp_version() {
    local ver
    ver="$(get_source_version)"
    if [[ "$ver" != "unknown" ]]; then
        echo "$ver" > "$VERSION_STAMP_FILE"
    fi
}

# --- Helpers ------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Claude Code configuration files.

Running without options launches an interactive component selector.
Works with both local and piped installs (curl | bash).

Options:
    --all               Install everything (non-interactive)
    --only <ids>        Install just these menu items (comma- or space-separated
                        IDs, see --list-ids), non-interactively. Additive:
                        nothing else is removed, plugins are not reconciled
    --uninstall         Remove all installed files
    --list-ids          Print every menu item ID with its default and group
    --version           Show version info
    --dry-run           Show what would be installed without doing it,
                        including which plugins/marketplaces would be REMOVED
    --force             Skip confirmation prompts
    --prune-foreign-plugins
                        Also uninstall plugins this installer does not manage
                        when they are not selected this run (hand-installed
                        third-party ones included). By default only
                        installer-managed plugins are reconciled.
    --keep-foreign-plugins
                        Accepted for compatibility; this is now the default.
    -h, --help          Show this help

Every run also removes retired items (github plugin + GitHub MCP, claude-mem,
PUA). --all installs every item except the opt-in storage-analyzer skill.

Examples:
    $(basename "$0")                                 # Interactive selector
    $(basename "$0") --all                           # Install everything
    $(basename "$0") --uninstall                     # Uninstall everything
    $(basename "$0") --dry-run --all                 # Preview full install
    $(basename "$0") --dry-run                       # Preview plugin reconciliation
    $(basename "$0") --only lieflat-charts,skill-neat-freak   # Add two items only
    bash <(curl -fsSL $REPO_URL/raw/$REPO_BRANCH/install.sh)        # Remote install (interactive)
    bash <(curl -fsSL $REPO_URL/raw/$REPO_BRANCH/install.sh) --all  # Remote install (everything)
EOF
}

# --- Flags & state ------------------------------------------------------

DRY_RUN=false
INSTALL_ALL=false
EXPLICIT_ALL=false
INSTALL_WARNINGS=0
INSTALL_CRITICAL=0
INSTALL_RULES=false
# rules/writing-style.md (replaces the retired Common rules). True by default so
# non-interactive and --all runs install it; the interactive menu sets it from
# the "Writing style rule" item.
INSTALL_WRITING_STYLE=true
INSTALL_SKILLS=false
INSTALL_AGENTS=false
INSTALL_MATTPOCOCK=false
INSTALL_LESSONS=false
INSTALL_STATUSLINE=false
INSTALL_MCP=false
INSTALL_LARK=false
INSTALL_PLUGINS=false
INSTALL_CLAUDE_MD=false
INSTALL_SETTINGS=false
INSTALL_SHELL_WRAPPER=false
# True when ~/.claude/claude.zsh already existed when install_shell_wrapper ran,
# i.e. this is a re-install. Used to escalate the ".zshrc is not sourcing it"
# reminder from a first-run tip to a warning: a second install that still finds
# no source line means the one-time hint was missed, and every cl* command has
# been silently unavailable since the first run.
WRAPPER_PREEXISTED=false
# Which lark-mcp tool preset to register. Without -t the package defaults to
# preset.default, and upstream's own FAQ lists "token limit exceeded after
# starting the MCP service" as a known problem whose documented fix is this very
# flag. preset.light is the smallest set; widen it in ~/.claude.json later.
LARK_MCP_PRESET="preset.light"
CO_AUTHOR=false
INSTALL_DEEPXIV=false
# --only: install just the listed menu IDs, additively (no removals, no plugin
# reconciliation). ONLY_IDS holds the raw, not yet validated list.
ONLY_MODE=false
ONLY_IDS=""
LIST_IDS=false
UNINSTALL=false
FORCE=false
SHOW_VERSION=false
INTERACTIVE=false
RULE_LANGS=()
RULE_LANGS_EXPLICIT=false
PLUGIN_GROUPS=()
REVIEW_ADVERSARIAL=false
REVIEW_CODEX=false
SELECTED_SKILLS=()
# Repository skills this script installer owns. --all installs exactly these,
# and unselected-cleanup / --uninstall only ever remove these. skills/ also
# holds skills that only the agent-guided path manages (edit-config), which
# the script must never copy or delete. humanizer/humanizer-zh are no longer
# bundled: humanizer is a plugin and humanizer-zh a pinned upstream skill.
SCRIPT_OWNED_SKILLS=("paper-reading" "cheatsheet-creator" "update-config" "adversarial-review" "storage-analyzer")
# Script-owned skills that are opt-in only: never installed by --all or the
# non-interactive default run, only when picked explicitly.
SCRIPT_OPT_IN_SKILLS=("storage-analyzer")
# Pinned third-party skill items selected this run (see UPSTREAM_SKILL_ITEMS).
SELECTED_UPSTREAM_SKILLS=()
# True when this run's selection is a complete menu selection (interactive
# selector): only then are previously installed, now-deselected items removed.
FULL_SELECTION=false
SELECTED_PLUGINS=()
SELECTED_DEEPXIV_SKILLS=()
SELECTED_PROFILES=()
DEEPXIV_KNOWN_SKILLS=("deepxiv-cli" "deepxiv-trending-digest" "deepxiv-baseline-table")

# Plugin reconciliation state (populated at runtime; also set by tests as
# fixtures for the pure resolution functions below).
#   RESOLVED_PLUGINS   - deduped plugins selected for THIS run (set by install_plugins)
#   CATALOGUE_PLUGINS  - union of all installer-managed plugin groups
#   INSTALLED_PLUGINS  - keys currently present in installed_plugins.json
#   PRUNED_PLUGINS     - keys prune_unlisted_plugins() decided to uninstall
#   SURVIVING_PLUGINS  - keys still installed once pruning has settled
#   LOCAL_MARKETPLACES - marketplace cache dirs present locally (valid catalogs)
#   PLUGIN_PRUNE_SCOPE - "catalogue" (default: only reconcile installer-managed
#                        plugins; plugins this installer does not own are never
#                        uninstalled, apart from tombstoned ones) or "all"
#                        (uninstall anything not selected this run, including
#                        hand-installed third-party plugins; set by
#                        --prune-foreign-plugins)
RESOLVED_PLUGINS=()
CATALOGUE_PLUGINS=()
INSTALLED_PLUGINS=()
PRUNED_PLUGINS=()
SURVIVING_PLUGINS=()
LOCAL_MARKETPLACES=()
PLUGIN_PRUNE_SCOPE="catalogue"

# Retired Skill ownership tombstones.
RETIRED_HARNESS_WORKFLOW_SHA256="d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba"

# Curated subset of mattpocock/skills we install via `npx skills` (NOT vendored).
# THIS ARRAY IS THE SINGLE SOURCE OF TRUTH: install_mattpocock_skills installs
# exactly these, and cleanup_retired_mattpocock_skills treats every OTHER entry
# recorded in the ownership manifest as retired and removes it. The 11 skills
# dropped from the original 17-skill integration duplicate superpowers
# (test-driven-development / systematic-debugging / writing-plans /
# writing-skills) and ecc (tdd-workflow / blueprint / skill-* cluster); `triage`
# additionally hard-depends on `setup-matt-pocock-skills`, which is itself dropped.
MATTPOCOCK_SKILLS=(
    "grilling" "grill-me" "teach" "prototype" "handoff" "codebase-design"
)

# Is $1 a member of the curated keep list?
is_kept_mattpocock_skill() {
    local needle="${1-}" s
    for s in "${MATTPOCOCK_SKILLS[@]}"; do
        [[ "$s" == "$needle" ]] && return 0
    done
    return 1
}

is_safe_retired_skill_name() {
    local name="${1-}"
    [[ -n "$name" ]] || return 1
    [[ "$name" != "." && "$name" != ".." ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

sha256_file() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | cut -d " " -f 1 | tr "[:upper:]" "[:lower:]"
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | cut -d " " -f 1 | tr "[:upper:]" "[:lower:]"
    else
        return 1
    fi
}

# Ownership manifest path. Format v2, one record per line:
#     <skill-name>\t<sha256 of the installed SKILL.md>
# Legacy v1 records are a bare <skill-name> with no tab (the original 17-skill
# integration wrote these). Both are accepted on read; only v2 is ever written.
MATTPOCOCK_MANIFEST_NAME=".mattpocock-skills"

# Digest of a skill's SKILL.md, or empty when it cannot be computed.
mattpocock_skill_digest() {
    local skill_file="$CLAUDE_DIR/skills/${1-}/SKILL.md"
    [[ -f "$skill_file" ]] || return 1
    sha256_file "$skill_file" 2>/dev/null || return 1
}

# Atomically replace the ownership manifest with the records on stdin.
# Refuses to write through a symlink (a symlinked manifest would let a normal
# installer run truncate an arbitrary file), writes a sibling temp file, and
# reports failure instead of swallowing it — a manifest we failed to persist
# means a later uninstall cannot purge what we just installed.
write_mattpocock_manifest() {
    local manifest="$CLAUDE_DIR/$MATTPOCOCK_MANIFEST_NAME" tmp
    if [[ -L "$manifest" ]]; then
        warn "Refusing to write mattpocock ownership manifest through a symlink: $manifest"
        return 1
    fi
    tmp="$(mktemp "${manifest}.tmp.XXXXXX")" || { warn "Could not create temp file for mattpocock ownership manifest"; return 1; }
    if ! cat > "$tmp"; then
        rm -f -- "$tmp"
        warn "Could not write mattpocock ownership manifest"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$manifest"; then
        rm -f -- "$tmp"
        warn "Could not replace mattpocock ownership manifest: $manifest"
        return 1
    fi
    return 0
}

# Remove manifest-owned mattpocock skills that are no longer in MATTPOCOCK_SKILLS.
# Pass --all (uninstall path) to treat EVERY manifest entry as retired and drop
# the manifest entirely. Without --all (install path) the curated keep list
# survives and the manifest is rewritten to the surviving entries, so repeated
# installer runs are idempotent instead of flip-flopping with the install step.
#
# A manifest NAME alone is not proof of ownership: `teach`, `handoff` and
# `prototype` are names a user may well have taken for their own skill after we
# installed ours. So a v2 record is only deleted when the directory's current
# SKILL.md still hashes to what we recorded at install time — the same
# content-verified ownership rule cleanup_retired_harness_workflow already uses.
cleanup_retired_mattpocock_skills() {
    local purge_all=false
    [[ "${1-}" == "--all" ]] && purge_all=true
    local manifest="$CLAUDE_DIR/$MATTPOCOCK_MANIFEST_NAME"
    if [[ -L "$manifest" ]]; then
        warn "mattpocock ownership manifest is a symlink; refusing to act on it: $manifest"
        return 0
    fi
    [[ -f "$manifest" ]] || return 0
    local skill_name skill_hash skill_path current_hash
    local -a survivors=()
    while IFS=$'\t' read -r skill_name skill_hash || [[ -n "$skill_name" ]]; do
        [[ -n "$skill_name" ]] || continue
        if ! is_safe_retired_skill_name "$skill_name"; then
            warn "Skipping unsafe retired skill manifest entry"
            continue
        fi
        if ! $purge_all && is_kept_mattpocock_skill "$skill_name"; then
            survivors+=("$skill_name")
            continue
        fi
        skill_path="$CLAUDE_DIR/skills/$skill_name"
        [[ -d "$skill_path" ]] || continue
        # v2 record: require the recorded content to still be there before deleting.
        if [[ -n "$skill_hash" ]]; then
            if ! current_hash="$(mattpocock_skill_digest "$skill_name")"; then
                warn "Retired skill '$skill_name': cannot verify ownership; preserving directory"
                continue
            fi
            if [[ "$current_hash" != "$skill_hash" ]]; then
                warn "Retired skill '$skill_name' is modified or user-authored; preserving directory"
                continue
            fi
        fi
        if $DRY_RUN; then info "Would remove retired manifest-owned skill: $skill_name";
        else rm -rf -- "$skill_path"; ok "Removed retired manifest-owned skill: $skill_name"; fi
    done < "$manifest"

    if ((${#survivors[@]} > 0)); then
        # Keep-list entries remain owned; rewrite the manifest to just those,
        # re-deriving each digest from what is on disk right now so a skill the
        # user has since replaced is recorded as theirs, not ours.
        if $DRY_RUN; then
            info "Would rewrite mattpocock skill manifest (${#survivors[@]} kept)"
            return 0
        fi
        local -a records=()
        for skill_name in "${survivors[@]}"; do
            # No readable SKILL.md means we cannot prove we own it — drop the
            # record rather than keep a bare name that would later authorise a
            # deletion we cannot justify.
            if current_hash="$(mattpocock_skill_digest "$skill_name")"; then
                records+=("$(printf '%s\t%s' "$skill_name" "$current_hash")")
            fi
        done
        if ((${#records[@]} > 0)); then
            printf '%s\n' "${records[@]}" | write_mattpocock_manifest || \
                warn "mattpocock ownership record is stale; a later --uninstall may not purge these skills"
        else
            rm -f -- "$manifest"
        fi
        return 0
    fi

    if $DRY_RUN; then info "Would remove retired skill manifest: $manifest";
    else rm -f -- "$manifest"; ok "Removed retired skill manifest"; fi
}

cleanup_retired_harness_workflow() {
    local skill_dir="$CLAUDE_DIR/skills/harness-workflow" skill_file digest
    [[ -d "$skill_dir" ]] || return 0
    skill_file="$skill_dir/SKILL.md"
    if [[ ! -f "$skill_file" ]]; then warn "Retired harness-workflow: cannot verify ownership; preserving directory"; return 0; fi
    if ! digest="$(sha256_file "$skill_file")"; then warn "Retired harness-workflow: cannot verify ownership; preserving directory"; return 0; fi
    if [[ "$digest" != "$RETIRED_HARNESS_WORKFLOW_SHA256" ]]; then warn "Retired harness-workflow is modified or user-authored; preserving directory"; return 0; fi
    if $DRY_RUN; then
        info "Would remove retired managed skill file: harness-workflow/SKILL.md"
        return 0
    fi
    rm -f -- "$skill_file"
    if rmdir "$skill_dir" 2>/dev/null; then
        ok "Removed retired managed skill: harness-workflow"
    else
        warn "Removed retired managed harness-workflow/SKILL.md; preserved additional content"
    fi
}

cleanup_retired_enabled_plugins() {
    local settings="$CLAUDE_DIR/settings.json" removed_json tmp
    [[ -f "$settings" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then warn "jq unavailable — cannot remove retired enabled plugins safely"; return 0; fi
    if ! jq empty "$settings" 2>/dev/null; then warn "settings.json is invalid — cannot remove retired enabled plugins safely"; return 0; fi
    local found=false pkg
    for pkg in "${PLUGINS_REMOVED[@]}"; do
        if jq -e --arg k "$pkg" '(.enabledPlugins // {}) | has($k)' "$settings" >/dev/null; then
            found=true
            if $DRY_RUN; then info "Would remove retired enabled plugin: $pkg"; fi
        fi
    done
    $found || return 0
    $DRY_RUN && return 0
    removed_json="$(printf '%s\n' "${PLUGINS_REMOVED[@]}" | jq -R . | jq -s .)"
    tmp="$(mktemp "${settings}.tmp.XXXXXX")" || return 1
    if jq --argjson removed "$removed_json" 'reduce $removed[] as $r (. ; del(.enabledPlugins[$r]))' "$settings" > "$tmp" && jq empty "$tmp"; then
        chmod --reference="$settings" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$settings"
        ok "Removed retired enabled plugin settings"
    else
        rm -f "$tmp"; warn "Could not remove retired enabled plugins safely"
    fi
}

# $1 may be --all (uninstall): purge every manifest-owned mattpocock skill,
# including the curated keep list.
cleanup_retired_skills() {
    cleanup_retired_mattpocock_skills "${1-}"
    cleanup_retired_harness_workflow
}

# --- Plugin groups ------------------------------------------------------

PLUGINS_ESSENTIAL=(
    "andrej-karpathy-skills@karpathy-skills"
    "superpowers@claude-plugins-official"
    "context7@claude-plugins-official"
    "commit-commands@claude-plugins-official"
    "document-skills@anthropic-agent-skills"
    "playwright@claude-plugins-official"
    "feature-dev@claude-plugins-official"
    "code-simplifier@claude-plugins-official"
    "ralph-loop@claude-plugins-official"
    "example-skills@anthropic-agent-skills"
    "humanizer@humanizer"
)

# Optional plugins: default OFF, installed only via explicit --all or manual opt-in
PLUGINS_OPTIONAL=(
    "ecc@ecc"
    "frontend-slides@frontend-slides"
    "ppt-master@ppt-master"
)

PLUGINS_AI_RESEARCH=(
    "tokenization@ai-research-skills"
    "fine-tuning@ai-research-skills"
    "post-training@ai-research-skills"
    "inference-serving@ai-research-skills"
    "distributed-training@ai-research-skills"
    "optimization@ai-research-skills"
)

# Review plugins (Review group). Part of the installer-owned catalogue so an
# interactive run that unchecks them uninstalls them (they used to be only
# disabled in settings.json). Neither is installed by the essential group.
PLUGINS_REVIEW=(
    "code-review@claude-plugins-official"
    "codex@openai-codex"
)

# Marketplaces reconciliation never removes, even when no selected plugin
# needs them: claude-plugins-official is Claude Code's built-in catalog.
PROTECTED_MARKETPLACES=("claude-plugins-official")

# Plugins/marketplaces retired or renamed upstream. Re-running the installer
# uninstalls these stale ids and removes their orphaned marketplaces so a
# rename (e.g. everything-claude-code -> ecc) self-heals on the next run.
#
# This sweep (prune_retired_plugins) runs on every invocation and is independent
# of PLUGIN_PRUNE_SCOPE: tombstoned ids are uninstalled even under the default
# "catalogue" scope, which otherwise never touches plugins the installer does
# not manage.
RETIRED_PLUGINS=(
    "frontend-design@claude-plugins-official"
    "everything-claude-code@everything-claude-code"  # renamed to ecc@ecc
    "health@claude-health"                           # claude-health renamed to the waza suite
    "github@claude-plugins-official"                 # GitHub MCP/plugin retired (4.2.0)
    "claude-mem@thedotmack"                          # claude-mem retired (4.2.0)
    "pua@pua-skills"                                 # PUA retired (4.2.0)
)
RETIRED_MARKETPLACES=(
    "everything-claude-code"  # superseded by the ecc marketplace
    "claude-health"           # superseded by waza
    "thedotmack"              # claude-mem retired
    "pua-skills"              # PUA retired
)

# Tombstones: plugins removed upstream. Stripped from a user's enabledPlugins
# on upgrade and uninstalled on --uninstall, so "removed" plugins don't linger.
PLUGINS_REMOVED=(
    "frontend-design@claude-plugins-official"
    "everything-claude-code@everything-claude-code"
    "health@claude-health"
    "github@claude-plugins-official"
    "claude-mem@thedotmack"
    "pua@pua-skills"
)

# Retired standalone MCP registration: very early releases added GitHub's
# hosted MCP server at user scope under this name and URL. Removed only when
# both still match, so a user's own "github" server is left alone.
RETIRED_GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"

# --- Terminal detection (single source of truth) -----------------------

# Can we interact with a human? Returns 0 if stdout is a tty AND we can
# read keyboard input (either stdin is a tty or /dev/tty is accessible).
can_interact() {
    [[ -t 1 ]] && { [[ -t 0 ]] || [[ -r /dev/tty ]]; }
}

# --- Argument parsing ---------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        # No args: interactive mode if terminal available (including piped installs
        # like "curl | bash" where /dev/tty is still accessible), else install all
        if can_interact; then
            INTERACTIVE=true
        else
            INSTALL_ALL=true
        fi
        return
    fi

    local has_action=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                INSTALL_ALL=true
                EXPLICIT_ALL=true
                has_action=true
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                has_action=true
                shift
                ;;
            --only)
                if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
                    error "--only needs a list of menu IDs (see --list-ids)"
                    exit 1
                fi
                ONLY_MODE=true
                ONLY_IDS="${ONLY_IDS:+$ONLY_IDS,}$2"
                has_action=true
                shift 2
                ;;
            --only=*)
                ONLY_MODE=true
                ONLY_IDS="${ONLY_IDS:+$ONLY_IDS,}${1#--only=}"
                has_action=true
                shift
                ;;
            --list-ids)
                LIST_IDS=true
                has_action=true
                shift
                ;;
            --version)
                SHOW_VERSION=true
                has_action=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --keep-foreign-plugins)
                # Now the default; still accepted for existing scripts.
                PLUGIN_PRUNE_SCOPE="catalogue"
                shift
                ;;
            --prune-foreign-plugins)
                PLUGIN_PRUNE_SCOPE="all"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                error "Run '$(basename "$0") --help' for available options."
                exit 1
                ;;
        esac
    done

    if $ONLY_MODE && { $INSTALL_ALL || $UNINSTALL; }; then
        error "--only cannot be combined with --all or --uninstall"
        exit 1
    fi

    # Only modifier flags (--dry-run, --force) with no action
    if ! $has_action; then
        if can_interact; then
            INTERACTIVE=true
        else
            INSTALL_ALL=true
        fi
    fi
}

# --- Menu definition ----------------------------------------------------
#
# Single source of truth for the selectable items: the interactive selector,
# --only and scripts/check-catalog-sync.sh all read it through
# load_menu_groups / menu_item_ids. install.ps1 mirrors the same items and IDs.
MENU_GROUP_LABELS=()
MENU_GROUP_HINTS=()
MENU_GROUP_ITEMS=()

load_menu_groups() {
    # --- Two-level menu data structure ---
    # Each group has: label, hint, and an array of items.
    # Item format: "label|description|default_on|id"
    # Groups are navigated in the main menu; Enter opens sub-menu.
    # Mutual exclusion: review-adversarial and review-codex (handled in toggle logic).

    MENU_GROUP_LABELS=()
    MENU_GROUP_HINTS=()
    MENU_GROUP_ITEMS=()    # newline-separated list of items per group

    # Group 0: Core
    MENU_GROUP_LABELS+=("Core")
    MENU_GROUP_HINTS+=("")
    MENU_GROUP_ITEMS+=("CLAUDE.md|Global instructions template|1|claude-md
settings.json|Smart-merged Claude Code settings|1|settings
Writing style rule|Complete English writing rule (rules/writing-style.md)|1|rules-writing-style
StatusLine|Gradient bars + Anthropic/GLM 5h quota|1|statusline
Lessons|lessons.md template + SessionStart hook|1|lessons
Search agent|Jeff read-only web search agent|1|agents
Shell wrapper|cl/cl_auto zsh functions + system prompt|1|shell-wrapper
Co-authored-by|Add Claude as co-author in commits|0|co-author")

    # Group 1: Model Backends
    # Each backend is a profile JSON consumed by claude.zsh. Installing a profile
    # is free — it only writes a template. The proxy binaries a profile needs are
    # fetched lazily by the launcher on first use, not here.
    MENU_GROUP_LABELS+=("Model Backends")
    MENU_GROUP_HINTS+=("cl_<name> per backend; credentials are never overwritten on upgrade")
    MENU_GROUP_ITEMS+=("GLM Coding Plan|Zhipu BigModel, Anthropic-compatible endpoint|1|backend-glm
OpenRouter|Direct Anthropic-compatible endpoint; DeepSeek V4 slots|1|backend-or
ChatGPT via CLIProxyAPI|Reuse a ChatGPT Plus/Pro subscription (Codex OAuth); needs cliproxyapi|0|backend-gpt
CCR gateway|claude-code-router: GLM + GPT merged into one /model list; manual web-UI setup|0|backend-ccr")

    # Group 2: Language Rules
    MENU_GROUP_LABELS+=("Language Rules")
    MENU_GROUP_HINTS+=("Python/TypeScript/Go are enabled by default; uncheck what you don't need")
    MENU_GROUP_ITEMS+=("Python rules|PEP 8, pytest, type hints, bandit|1|rules-python
TypeScript rules|Zod, Playwright, immutability|1|rules-ts
Go rules|gofmt, table-driven tests, gosec|1|rules-go")

    # Group 2: Review
    MENU_GROUP_LABELS+=("Review")
    MENU_GROUP_HINTS+=("adversarial-review and Codex are mutually exclusive")
    MENU_GROUP_ITEMS+=("code-review plugin|PR code review (claude-plugins-official)|1|review-code-review
adversarial-review|Cross-model adversarial review (poteto/noodle); needs codex CLI|0|review-adversarial
Codex CLI|Codex adversarial review (openai/codex)|0|review-codex")

    # Group 3: Workflow
    MENU_GROUP_LABELS+=("Workflow")
    MENU_GROUP_HINTS+=("planning, iteration, code quality, meta-config")
    MENU_GROUP_ITEMS+=("andrej-karpathy-skills|Karpathy coding guidelines (Think-First, Simplicity, Surgical)|1|plug-andrej-karpathy-skills
superpowers|Planning, brainstorming, TDD, debugging|1|plug-superpowers
mattpocock/skills|6 curated agent skills via npx: grilling, grill-me, teach, prototype, handoff, codebase-design (mattpocock)|1|skill-mattpocock
feature-dev|Guided feature development|1|plug-feature-dev
ralph-loop|Automated iteration loop|1|plug-ralph-loop
commit-commands|git commit / push / PR workflow|1|plug-commit-commands
code-simplifier|Code simplification & cleanup|1|plug-code-simplifier
ecc|Everything Claude Code: TDD, security, database, Go/Python/Spring Boot|1|plug-everything-claude-code
update-config|Configure Claude Code via settings.json (skill)|1|skill-update-config
neat-freak|Knowledge, docs & workspace closeout (KKKKhazix/khazix-skills, pinned; needs python3)|0|skill-neat-freak")

    # Group 4: Integrations
    MENU_GROUP_LABELS+=("Integrations")
    MENU_GROUP_HINTS+=("external tools & services")
    MENU_GROUP_ITEMS+=("context7|Real-time library documentation|1|plug-context7
playwright|Browser automation & E2E testing|1|plug-playwright")

    # Group 5: Design & Content
    MENU_GROUP_LABELS+=("Design & Content")
    MENU_GROUP_HINTS+=("documents, UI, creative artifacts, humanization")
    MENU_GROUP_ITEMS+=("document-skills|Document processing (PDF, DOCX, PPTX, XLSX)|1|plug-document-skills
example-skills|Frontend/design/canvas/algorithmic-art skills|1|plug-example-skills
humanizer|Remove AI writing patterns (English, blader); humanizer@humanizer plugin, /humanizer:humanizer|1|skill-humanizer
humanizer-zh|Remove AI writing patterns (Chinese, op7418; pinned upstream; needs python3)|0|skill-humanizer-zh
lieflat-charts|HTML chart & report templates (larashero3, PolyForm-NC · noncommercial; needs python3)|0|lieflat-charts")

    # Group 6: Slides
    MENU_GROUP_LABELS+=("Slides")
    MENU_GROUP_HINTS+=("AI slide / PPTX generation · default off")
    MENU_GROUP_ITEMS+=("frontend-slides|HTML slide generator with PPT conversion (zarazhangrui)|0|plug-frontend-slides
ppt-master|Editable PPTX from PDF/DOCX/URL/Markdown; needs pip install (hugohe3)|0|plug-ppt-master")

    # Group 7: Storage
    MENU_GROUP_LABELS+=("Storage")
    MENU_GROUP_HINTS+=("disk usage analysis · default off")
    MENU_GROUP_ITEMS+=("storage-analyzer|Read-only disk usage analysis with interactive report (skill)|0|skill-storage-analyzer")

    # Group 8: Academic Research (AI Research bundle + ResearchStudio + DeepXiv + paper-reading)
    MENU_GROUP_LABELS+=("Academic Research")
    MENU_GROUP_HINTS+=("paper reading, AI Research bundle, ResearchStudio & DeepXiv skills")
    MENU_GROUP_ITEMS+=("paper-reading|Research paper summarization (skill)|1|skill-paper-reading
cheatsheet-creator|Exam cheatsheet from lectures/homework/past exams (skill)|1|skill-cheatsheet-creator
AI Research bundle|6 plugins / 31 skills: tokenization, fine-tuning, post-training, inference, distributed, optimization|0|ai-research
ResearchStudio Idea|idea_spark, paper_search, scoop_check (microsoft/ResearchStudio, pinned; needs python3)|0|researchstudio-idea
deepxiv-cli|arXiv/PMC paper search & reading CLI skill|0|deepxiv-cli
deepxiv-trending-digest|Trending paper digest generation|0|deepxiv-trending-digest
deepxiv-baseline-table|Baseline comparison table from papers|0|deepxiv-baseline-table")

    # Group 9: MCP Servers
    #   Both are opt-in (default off). The standalone Playwright MCP registers
    #   under the name `playwright` — the same name the official playwright
    #   plugin uses — and a user-scope entry shadows the plugin's, so enabling
    #   both leaves the plugin one silently never started. Pick this only if
    #   you deselect the playwright plugin in the Plugins group.
    #   Lark/Feishu needs App ID/Secret credentials and ~1GB RAM per session.
    MENU_GROUP_LABELS+=("MCP Servers")
    MENU_GROUP_HINTS+=("")
    MENU_GROUP_ITEMS+=("Playwright MCP|Standalone server — shadows the playwright plugin, pick only without it|0|mcp
Lark/Feishu MCP|Feishu/Lark integration — needs App ID/Secret, ~1GB RAM/session|0|mcp-lark")

}

# Print every menu item as "id|default_on|group label", one per line.
menu_item_ids() {
    load_menu_groups
    local g line _l _d _df _id
    for (( g=0; g<${#MENU_GROUP_LABELS[@]}; g++ )); do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r _l _d _df _id <<< "$line"
            printf '%s|%s|%s\n' "$_id" "$_df" "${MENU_GROUP_LABELS[$g]}"
        done <<< "${MENU_GROUP_ITEMS[$g]}"
    done
}

# 0 when $1 is a known menu item id.
is_menu_item_id() {
    local needle="$1" entry
    while IFS= read -r entry; do
        [[ "${entry%%|*}" == "$needle" ]] && return 0
    done < <(menu_item_ids)
    return 1
}

# --list-ids: one "id  default  group" row per menu item.
print_menu_ids() {
    local entry id df group
    printf '%-30s %-8s %s\n' "ID" "DEFAULT" "GROUP"
    while IFS='|' read -r id df group; do
        printf '%-30s %-8s %s\n' "$id" "$([[ "$df" == 1 ]] && echo on || echo off)" "$group"
    done < <(menu_item_ids)
}

# --only: validate ONLY_IDS and apply them like menu picks, additively.
apply_only_selection() {
    local raw="${ONLY_IDS//,/ }" id bad=()
    local -a ids=()
    read -r -a ids <<< "$raw"
    if [[ ${#ids[@]} -eq 0 ]]; then
        error "--only needs at least one menu ID (see --list-ids)"
        exit 1
    fi
    for id in "${ids[@]}"; do
        is_menu_item_id "$id" || bad+=("$id")
    done
    if [[ ${#bad[@]} -gt 0 ]]; then
        error "Unknown menu ID(s) for --only: ${bad[*]}"
        error "Run '$(basename "$0") --list-ids' for the valid IDs."
        exit 1
    fi
    INSTALL_ALL=false
    FULL_SELECTION=false
    RULE_LANGS_EXPLICIT=false
    INSTALL_WRITING_STYLE=false
    for id in "${ids[@]}"; do
        apply_menu_id "$id"
    done
    # settings.json is merged only when an item writes keys into it; a plugin
    # pick alone does not need it (claude plugin install enables the plugin).
    if ($INSTALL_STATUSLINE || $INSTALL_LESSONS || $CO_AUTHOR) && ! $INSTALL_SETTINGS; then
        INSTALL_SETTINGS=true
        info "settings.json auto-enabled (required by StatusLine/Lessons/Co-author)"
    fi
    info "--only: ${ids[*]} (additive: nothing else is installed or removed)"
}

# Map a plug-* menu ID to its package name (bash 3.2 compatible, no associative arrays).
plug_id_to_pkg() {
    case "$1" in
        plug-andrej-karpathy-skills) echo "andrej-karpathy-skills@karpathy-skills" ;;
        plug-everything-claude-code) echo "ecc@ecc" ;;
        plug-superpowers)       echo "superpowers@claude-plugins-official" ;;
        plug-frontend-slides)   echo "frontend-slides@frontend-slides" ;;
        plug-ppt-master)        echo "ppt-master@ppt-master" ;;
        plug-context7)          echo "context7@claude-plugins-official" ;;
        plug-commit-commands)   echo "commit-commands@claude-plugins-official" ;;
        plug-document-skills)   echo "document-skills@anthropic-agent-skills" ;;
        plug-playwright)        echo "playwright@claude-plugins-official" ;;
        plug-feature-dev)       echo "feature-dev@claude-plugins-official" ;;
        plug-code-simplifier)   echo "code-simplifier@claude-plugins-official" ;;
        plug-ralph-loop)        echo "ralph-loop@claude-plugins-official" ;;
        plug-example-skills)    echo "example-skills@anthropic-agent-skills" ;;
        *) echo "" ;;
    esac
}

# Apply one selected menu item ID to the install flags. Shared by the
# interactive selector and --only.
apply_menu_id() {
    local item_id="$1"
    case "$item_id" in
        # Core
        claude-md)              INSTALL_CLAUDE_MD=true ;;
        settings)               INSTALL_SETTINGS=true ;;
        rules-writing-style)    INSTALL_RULES=true; INSTALL_WRITING_STYLE=true ;;
        statusline)             INSTALL_STATUSLINE=true ;;
        lessons)                INSTALL_LESSONS=true ;;
        agents)                 INSTALL_AGENTS=true ;;
        shell-wrapper)          INSTALL_SHELL_WRAPPER=true ;;
        co-author)              CO_AUTHOR=true ;;
        # Model backends (profile JSON consumed by claude.zsh)
        backend-glm)            INSTALL_SHELL_WRAPPER=true; SELECTED_PROFILES+=("glm") ;;
        backend-or)             INSTALL_SHELL_WRAPPER=true; SELECTED_PROFILES+=("or") ;;
        backend-gpt)            INSTALL_SHELL_WRAPPER=true; SELECTED_PROFILES+=("gpt") ;;
        backend-ccr)            INSTALL_SHELL_WRAPPER=true; SELECTED_PROFILES+=("ccr") ;;
        # Language rules
        rules-python)           INSTALL_RULES=true; RULE_LANGS+=("python") ;;
        rules-ts)               INSTALL_RULES=true; RULE_LANGS+=("typescript") ;;
        rules-go)               INSTALL_RULES=true; RULE_LANGS+=("golang") ;;
        # Review
        review-code-review)     INSTALL_PLUGINS=true; SELECTED_PLUGINS+=("code-review@claude-plugins-official") ;;
        review-adversarial)     REVIEW_ADVERSARIAL=true; INSTALL_SKILLS=true; SELECTED_SKILLS+=("adversarial-review") ;;
        review-codex)           REVIEW_CODEX=true; INSTALL_PLUGINS=true; SELECTED_PLUGINS+=("codex@openai-codex") ;;
        # Skills
        skill-paper-reading)    INSTALL_SKILLS=true; SELECTED_SKILLS+=("paper-reading") ;;
        skill-cheatsheet-creator) INSTALL_SKILLS=true; SELECTED_SKILLS+=("cheatsheet-creator") ;;
        skill-storage-analyzer) INSTALL_SKILLS=true; SELECTED_SKILLS+=("storage-analyzer") ;;
        # humanizer ships as the upstream humanizer@humanizer plugin
        skill-humanizer)        INSTALL_PLUGINS=true; SELECTED_PLUGINS+=("humanizer@humanizer") ;;
        # Pinned upstream skills (fetched, staged, recorded in agent-config/files.json)
        skill-humanizer-zh)     SELECTED_UPSTREAM_SKILLS+=("humanizer-zh") ;;
        skill-neat-freak)       SELECTED_UPSTREAM_SKILLS+=("neat-freak") ;;
        lieflat-charts)         SELECTED_UPSTREAM_SKILLS+=("lieflat-charts") ;;
        researchstudio-idea)    SELECTED_UPSTREAM_SKILLS+=("researchstudio-idea") ;;
        # AI Research: one item, six category plugins
        ai-research)            INSTALL_PLUGINS=true; SELECTED_PLUGINS+=("${PLUGINS_AI_RESEARCH[@]}") ;;
        skill-update-config)    INSTALL_SKILLS=true; SELECTED_SKILLS+=("update-config") ;;
        skill-mattpocock)       INSTALL_MATTPOCOCK=true ;;
        # DeepXiv
        deepxiv-cli)            INSTALL_DEEPXIV=true; SELECTED_DEEPXIV_SKILLS+=("deepxiv-cli") ;;
        deepxiv-trending-digest) INSTALL_DEEPXIV=true; SELECTED_DEEPXIV_SKILLS+=("deepxiv-trending-digest") ;;
        deepxiv-baseline-table) INSTALL_DEEPXIV=true; SELECTED_DEEPXIV_SKILLS+=("deepxiv-baseline-table") ;;
        # MCP
        mcp)                    INSTALL_MCP=true ;;
        mcp-lark)               INSTALL_LARK=true ;;
        # Plugins (all plug-* ids)
        plug-*)
            INSTALL_PLUGINS=true
            local pkg
            pkg="$(plug_id_to_pkg "$item_id")"
            [[ -n "$pkg" ]] && SELECTED_PLUGINS+=("$pkg") || true
            ;;
    esac
}

# --- Interactive menu ---------------------------------------------------

interactive_menu() {
    # Open a file descriptor for keyboard input.
    # Prefer stdin when it's a real tty (normal execution); fall back to /dev/tty
    # for piped installs (curl | bash) where stdin carries the script.
    if [[ -t 0 ]]; then
        exec 3<&0
    elif ! exec 3</dev/tty 2>/dev/null; then
        warn "Cannot open terminal for interactive input, falling back to default install"
        INSTALL_ALL=true
        return
    fi

    # Menu data comes from load_menu_groups (shared with --only).
    load_menu_groups
    local -a GROUP_LABELS=("${MENU_GROUP_LABELS[@]}")
    local -a GROUP_HINTS=("${MENU_GROUP_HINTS[@]}")
    local -a GROUP_ITEMS=("${MENU_GROUP_ITEMS[@]}")

    local num_groups=${#GROUP_LABELS[@]}
    # Index of the Review group (its adversarial/codex items are mutually
    # exclusive). Looked up by label so inserting a group cannot shift it.
    local review_g=-1 _g
    for (( _g=0; _g<num_groups; _g++ )); do
        [[ "${GROUP_LABELS[$_g]}" == "Review" ]] && review_g=$_g
    done

    # Flatten all items into parallel arrays for indexing
    local -a ALL_LABELS=() ALL_DESCS=() ALL_DEFAULTS=() ALL_IDS=()
    local -a GROUP_START=() GROUP_END=()
    local flat_idx=0
    for (( g=0; g<num_groups; g++ )); do
        GROUP_START[$g]=$flat_idx
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local _l _d _df _id
            IFS='|' read -r _l _d _df _id <<< "$line"
            ALL_LABELS+=("$_l")
            ALL_DESCS+=("$_d")
            ALL_DEFAULTS+=("$_df")
            ALL_IDS+=("$_id")
            (( ++flat_idx ))
        done <<< "${GROUP_ITEMS[$g]}"
        GROUP_END[$g]=$(( flat_idx - 1 ))
    done

    local n=$flat_idx
    local selected=()
    local cursor=0

    # Initialize selections from defaults
    local i
    for (( i=0; i<n; i++ )); do
        selected[$i]="${ALL_DEFAULTS[$i]}"
    done

    # Save terminal state (operate on fd 3 which points to the actual tty)
    local saved_stty
    saved_stty=$(stty -g <&3 2>/dev/null) || saved_stty=""

    _menu_active=false  # Not local — trap handlers need access under bash 5.x
    _menu_cleanup() {
        $_menu_active || return 0
        _menu_active=false
        printf '\033[?1049l' 2>/dev/null
        [[ -n "$saved_stty" ]] && stty "$saved_stty" <&3 2>/dev/null || stty echo <&3 2>/dev/null || true
        tput cnorm 2>/dev/null || printf '\033[?25h'
        exec 3<&- 2>/dev/null || true
    }
    trap '_menu_cleanup; exit 0' INT TERM
    # Also clean up on unexpected exit (e.g. set -e) to restore terminal.
    # Chain with tmpdir cleanup for remote mode.
    if $REMOTE_MODE; then
        trap '_menu_cleanup; rm -rf "${tmpdir:-}"' EXIT
    else
        trap '_menu_cleanup' EXIT
    fi

    _read_key() {
        local key="" _read_ret=0
        IFS= read -r -s -n 1 key <&3 2>/dev/null || _read_ret=$?
        # EOF (ret=1) → treat as quit, not enter
        if [[ $_read_ret -eq 1 ]]; then
            echo "QUIT"
            return
        fi

        if [[ "$key" == $'\033' ]]; then
            local rest=""
            IFS= read -r -s -n 2 -t 1 rest <&3 2>/dev/null || true
            case "$rest" in
                '[A') echo "UP" ;;
                '[B') echo "DOWN" ;;
                '[C') echo "RIGHT" ;;
                '[D') echo "LEFT" ;;
                '')   echo "ESC" ;;
                *)    echo "OTHER" ;;
            esac
            return
        fi

        case "$key" in
            '')     echo "ENTER" ;;
            ' ')    echo "SPACE" ;;
            a|A)    echo "ALL" ;;
            n|N)    echo "NONE" ;;
            d|D)    echo "DEFAULT" ;;
            q|Q)    echo "QUIT" ;;
            j|J)    echo "DOWN" ;;
            k|K)    echo "UP" ;;
            *)      echo "OTHER" ;;
        esac
    }

    # --- Helper: count selected items in a group ---
    _group_count() {
        local g=$1 cnt=0
        for (( j=GROUP_START[g]; j<=GROUP_END[g]; j++ )); do
            (( selected[j] )) && (( cnt++ )) || true
        done
        echo $cnt
    }
    _group_total() {
        local g=$1
        echo $(( GROUP_END[g] - GROUP_START[g] + 1 ))
    }

    # --- Helper: enforce mutual exclusion for review items ---
    _enforce_review_mutex() {
        local toggled_idx=$1
        local toggled_id="${ALL_IDS[$toggled_idx]}"
        # Only enforce if we just turned ON one of the mutually exclusive pair
        if [[ ${selected[$toggled_idx]} -eq 1 ]]; then
            if [[ "$toggled_id" == "review-adversarial" ]]; then
                # Find and turn off review-codex
                for (( j=GROUP_START[review_g]; j<=GROUP_END[review_g]; j++ )); do
                    [[ "${ALL_IDS[$j]}" == "review-codex" ]] && selected[$j]=0 || true
                done
            elif [[ "$toggled_id" == "review-codex" ]]; then
                # Find and turn off review-adversarial
                for (( j=GROUP_START[review_g]; j<=GROUP_END[review_g]; j++ )); do
                    [[ "${ALL_IDS[$j]}" == "review-adversarial" ]] && selected[$j]=0 || true
                done
            fi
        fi
    }

    # --- Draw main menu (groups as rows with counts) ---
    _draw_main_menu() {
        local buf=""
        buf+='\033[H'
        buf+='\033[K\n'
        buf+='  \033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\033[K\n'
        buf+="    \033[1;36mAwesome Claude Code Config Installer\033[0m  \033[2m${_cached_version}\033[0m\033[K\n"
        buf+='  \033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\033[K\n'
        buf+='\033[K\n'
        buf+='  \033[2m↑/↓ Navigate   Enter/→ Open   a All  n None  d Defaults  q Quit\033[0m\033[K\n'
        buf+='\033[K\n'

        local g
        for (( g=0; g<num_groups; g++ )); do
            local cnt tot label hint padded count_str
            cnt=$(_group_count $g)
            tot=$(_group_total $g)
            label="${GROUP_LABELS[$g]}"
            hint="${GROUP_HINTS[$g]}"
            printf -v padded '%-24s' "$label"
            count_str="[${cnt}/${tot}]"
            printf -v count_str '%-7s' "$count_str"

            if [[ $g -eq $cursor ]]; then
                buf+="  \033[32m>\033[0m ${count_str} \033[1m${padded}\033[0m"
            else
                buf+="    ${count_str} ${padded}"
            fi
            if [[ -n "$hint" ]]; then
                buf+=" \033[2m(${hint})\033[0m"
            fi
            buf+='\033[K\n'
        done
        buf+='\033[K\n'

        # Submit button
        if [[ $cursor -eq $num_groups ]]; then
            buf+='  \033[32m>\033[0m  \033[1;32m[ Submit ]\033[0m\033[K\n'
        else
            buf+='     \033[2m[ Submit ]\033[0m\033[K\n'
        fi
        buf+='\033[K\n\033[J'
        printf '%b' "$buf"
    }

    # --- Draw sub-menu (items within a group) ---
    _draw_sub_menu() {
        local g=$1 sub_cursor=$2
        local g_start=${GROUP_START[$g]} g_end=${GROUP_END[$g]}
        local sub_n=$(( g_end - g_start + 1 ))

        local buf=""
        buf+='\033[H'
        buf+='\033[K\n'
        buf+='  \033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\033[K\n'
        buf+="    \033[1;36m${GROUP_LABELS[$g]}\033[0m"
        if [[ -n "${GROUP_HINTS[$g]}" ]]; then
            buf+="  \033[2m(${GROUP_HINTS[$g]})\033[0m"
        fi
        buf+='\033[K\n'
        buf+='  \033[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\033[K\n'
        buf+='\033[K\n'
        buf+='  \033[2m↑/↓ Navigate   Space Toggle   ←/Esc/Enter Back\033[0m\033[K\n'
        buf+='  \033[2ma All   n None   d Defaults\033[0m\033[K\n'
        buf+='\033[K\n'

        local j rel=0
        for (( j=g_start; j<=g_end; j++, rel++ )); do
            local label="${ALL_LABELS[$j]}"
            local desc="${ALL_DESCS[$j]}"
            local padded
            printf -v padded '%-28s' "$label"

            local mark=" "
            if [[ ${selected[$j]} -eq 1 ]]; then
                mark='\033[32m*\033[0m'
            fi

            if [[ $rel -eq $sub_cursor ]]; then
                buf+="  \033[32m>\033[0m [${mark}] \033[1m${padded}\033[0m \033[2m${desc}\033[0m\033[K\n"
            else
                buf+="    [${mark}] ${padded} \033[2m${desc}\033[0m\033[K\n"
            fi
        done
        buf+='\033[K\n'

        # Back button
        if [[ $sub_cursor -eq $sub_n ]]; then
            buf+='  \033[32m>\033[0m  \033[1;33m[ Back ]\033[0m\033[K\n'
        else
            buf+='     \033[2m[ Back ]\033[0m\033[K\n'
        fi
        buf+='\033[K\n\033[J'
        printf '%b' "$buf"
    }

    # Cache version to avoid file reads on every redraw
    local _cached_version
    _cached_version="$(get_source_version)"

    # Enter alternate screen, hide cursor, disable echo
    _menu_active=true
    printf '\033[?1049h' 2>/dev/null
    tput civis 2>/dev/null || printf '\033[?25l'
    stty -echo <&3 2>/dev/null || true

    # Main menu loop
    cursor=0
    while true; do
        _draw_main_menu

        local key
        key="$(_read_key)"

        case "$key" in
            UP)
                (( cursor > 0 )) && (( cursor-- )) || true
                ;;
            DOWN)
                (( cursor < num_groups )) && (( cursor++ )) || true
                ;;
            ENTER|RIGHT)
                if (( cursor == num_groups )); then
                    # Submit (only on ENTER, not RIGHT)
                    if [[ "$key" == "ENTER" ]]; then break; fi
                    continue
                fi
                # Enter sub-menu for this group
                local sub_g=$cursor
                local sub_n=$(( GROUP_END[sub_g] - GROUP_START[sub_g] + 1 ))
                local sub_cursor=0
                local in_sub=true
                while $in_sub; do
                    _draw_sub_menu $sub_g $sub_cursor
                    key="$(_read_key)"
                    case "$key" in
                        UP)
                            (( sub_cursor > 0 )) && (( sub_cursor-- )) || true
                            ;;
                        DOWN)
                            (( sub_cursor < sub_n )) && (( sub_cursor++ )) || true
                            ;;
                        SPACE)
                            if (( sub_cursor < sub_n )); then
                                local abs_idx=$(( GROUP_START[sub_g] + sub_cursor ))
                                selected[$abs_idx]=$(( 1 - ${selected[$abs_idx]} ))
                                _enforce_review_mutex $abs_idx
                            fi
                            ;;
                        ENTER)
                            # Back button or toggle
                            if (( sub_cursor == sub_n )); then
                                in_sub=false
                            else
                                local abs_idx=$(( GROUP_START[sub_g] + sub_cursor ))
                                selected[$abs_idx]=$(( 1 - ${selected[$abs_idx]} ))
                                _enforce_review_mutex $abs_idx
                            fi
                            ;;
                        ALL)
                            for (( j=GROUP_START[sub_g]; j<=GROUP_END[sub_g]; j++ )); do
                                selected[$j]=1
                            done
                            # Re-enforce mutex only when in the Review group
                            if (( sub_g == review_g )); then
                                for (( j=GROUP_START[review_g]; j<=GROUP_END[review_g]; j++ )); do
                                    [[ "${ALL_IDS[$j]}" == "review-codex" ]] && selected[$j]=0 || true
                                done
                            fi
                            ;;
                        NONE)
                            for (( j=GROUP_START[sub_g]; j<=GROUP_END[sub_g]; j++ )); do
                                selected[$j]=0
                            done
                            ;;
                        DEFAULT)
                            for (( j=GROUP_START[sub_g]; j<=GROUP_END[sub_g]; j++ )); do
                                selected[$j]="${ALL_DEFAULTS[$j]}"
                            done
                            ;;
                        QUIT|ESC|LEFT)
                            in_sub=false
                            ;;
                    esac
                done
                ;;
            SPACE)
                # On main menu, Space does nothing (Enter to open sub-menu)
                ;;
            ALL)
                for (( i=0; i<n; i++ )); do selected[$i]=1; done
                # Enforce review mutex: "select all" keeps adversarial ON, codex OFF
                for (( j=${GROUP_START[review_g]}; j<=${GROUP_END[review_g]}; j++ )); do
                    [[ "${ALL_IDS[$j]}" == "review-codex" ]] && selected[$j]=0 || true
                done
                ;;
            NONE)
                for (( i=0; i<n; i++ )); do selected[$i]=0; done
                ;;
            DEFAULT)
                for (( i=0; i<n; i++ )); do
                    selected[$i]="${ALL_DEFAULTS[$i]}"
                done
                ;;
            QUIT)
                _menu_cleanup
                echo ""
                info "Cancelled."
                exit 0
                ;;
        esac
    done

    # Restore terminal (fd 3 closed by _menu_cleanup)
    _menu_cleanup
    trap - INT TERM EXIT
    # Restore tmpdir cleanup for remote mode
    $REMOTE_MODE && [[ -n "${tmpdir:-}" ]] && trap 'rm -rf "$tmpdir"' EXIT || true

    # Map selections to install flags
    INSTALL_ALL=false
    FULL_SELECTION=true
    RULE_LANGS_EXPLICIT=true
    INSTALL_WRITING_STYLE=false

    for (( i=0; i<n; i++ )); do
        [[ ${selected[$i]} -eq 0 ]] && continue
        apply_menu_id "${ALL_IDS[$i]}"
    done

    # Auto-enable settings.json when StatusLine, Lessons, Co-author, or Plugins need it for config
    if ($INSTALL_STATUSLINE || $INSTALL_LESSONS || $CO_AUTHOR || $INSTALL_PLUGINS) && ! $INSTALL_SETTINGS; then
        INSTALL_SETTINGS=true
        info "settings.json auto-enabled (required by StatusLine/Lessons/Co-author/Plugins)"
    fi
}

# --- Confirm prompt (respects --force) ----------------------------------

confirm() {
    local prompt="${1:-Continue?}"
    if $FORCE; then
        return 0
    fi
    if ! can_interact; then
        error "Non-interactive shell detected. Use --force to skip confirmation."
        exit 1
    fi
    if [[ -t 0 ]]; then
        echo -en "${YELLOW}${prompt} [y/N] ${NC}"
        read -r answer
    else
        # Piped stdin: send prompt AND read answer via /dev/tty so they stay paired
        echo -en "${YELLOW}${prompt} [y/N] ${NC}" > /dev/tty
        read -r answer </dev/tty
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

# --- Install functions --------------------------------------------------

install_claude_md() {
    info "Installing CLAUDE.md..."

    # Build the target content in a temp file first (so we can diff before writing)
    local review_line
    if $REVIEW_ADVERSARIAL; then
        review_line='Whenever a code review is needed — whether explicitly requested by the user or triggered by a skill (e.g., `code-reviewer`, `simplify`) — always invoke the `adversarial-review` skill to perform it. If the adversarial-review skill is unavailable (e.g., `codex` CLI not installed), fall back to using the `code-reviewer` agent for the review. Never substitute the actual review call with a text-only description.'
    elif $REVIEW_CODEX; then
        review_line='Whenever a code review is needed — whether explicitly requested by the user or triggered by a skill (e.g., `code-reviewer`, `simplify`) — first check if the Codex plugin is available by running `/codex:setup`. If Codex is ready (`ready: true`), invoke `/codex:adversarial-review` to perform the review. If Codex is unavailable or not authenticated, fall back to using the `code-reviewer` agent for the review. Never substitute the actual review call with a text-only description.'
    else
        review_line='Whenever a code review is needed — whether explicitly requested by the user or triggered by a skill (e.g., `code-reviewer`, `simplify`) — use the `code-reviewer` agent to perform it. Never substitute the actual review call with a text-only description.'
    fi

    if $DRY_RUN; then
        info "Would copy: CLAUDE.md -> $CLAUDE_DIR/CLAUDE.md"
        info "  Code Review: adversarial=$REVIEW_ADVERSARIAL codex=$REVIEW_CODEX"
    else
        # Prepare new content in a temp file
        local new_claude_md; new_claude_md="$(mktemp)"
        cp "$CLAUDE_TEMPLATES_DIR/CLAUDE.md" "$new_claude_md"
        # Rewrite the Code Review line to match the selected review backend.
        # awk, not `sed …c\…`: BSD sed (macOS) rejects text on the same line as
        # the `c` command ("extra characters after \ at the end of c command"),
        # so the sed form failed on every Mac and shipped the repo's default
        # wording no matter what was selected. The replacement text is passed
        # through the environment so awk cannot reinterpret backslashes in it.
        if command -v awk &>/dev/null; then
            local _awktmp="$new_claude_md._awktmp"
            local _awkrc=0
            # The END block exits 9 when the anchor matched nothing. In that case
            # awk still copied every input line verbatim, so the output is safe to
            # keep — but the substitution silently did nothing, which is exactly the
            # failure mode of the old `sed …c\…` form. Exit 9 is ours alone; a real
            # awk failure (crash, unwritable temp file) surfaces as 1/2 and takes the
            # other branch, so the two cases stay distinguishable.
            REVIEW_LINE="$review_line" awk '
                /^Whenever a code review is needed/ { print ENVIRON["REVIEW_LINE"]; matched = 1; next }
                { print }
                END { if (!matched) exit 9 }
            ' "$new_claude_md" > "$_awktmp" || _awkrc=$?
            if [[ $_awkrc -eq 0 ]]; then
                mv "$_awktmp" "$new_claude_md"
            elif [[ $_awkrc -eq 9 ]]; then
                warn "CLAUDE.md anchor 'Whenever a code review is needed' matched no line; the Code Review rule stays as the bundled template text. Update the installer's anchor if CLAUDE.md was reworded."
                mv "$_awktmp" "$new_claude_md"
            else
                warn "Could not rewrite the CLAUDE.md Code Review line; using the bundled default"
                rm -f "$_awktmp"
            fi
        else
            warn "awk not found; the CLAUDE.md Code Review rule stays as the bundled template text"
        fi

        # Compare with existing — skip if identical
        if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && diff -q "$CLAUDE_DIR/CLAUDE.md" "$new_claude_md" &>/dev/null; then
            ok "CLAUDE.md unchanged, skipping"
            rm -f "$new_claude_md"
            return
        fi

        # Content differs: back up existing before overwriting
        if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]]; then
            cp "$CLAUDE_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md.bak"
            warn "Existing CLAUDE.md backed up to CLAUDE.md.bak — merge your customizations manually"
        fi
        mv "$new_claude_md" "$CLAUDE_DIR/CLAUDE.md"

        ok "CLAUDE.md installed"
    fi
}

# Emit a JSON array of effective selected plugin packages (name@marketplace).
# Combines SELECTED_PLUGINS (individual picks) with PLUGIN_GROUPS expansion.
_effective_selected_plugins_json() {
    local pkgs=()
    if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
        pkgs+=("${SELECTED_PLUGINS[@]}")
    fi
    if [[ ${#PLUGIN_GROUPS[@]} -gt 0 ]]; then
        local g
        for g in "${PLUGIN_GROUPS[@]}"; do
            case "$g" in
                essential|core) pkgs+=("${PLUGINS_ESSENTIAL[@]}") ;;
                ai-research)    pkgs+=("${PLUGINS_AI_RESEARCH[@]}") ;;
                all)            pkgs+=("${PLUGINS_ESSENTIAL[@]}" "${PLUGINS_OPTIONAL[@]}" "${PLUGINS_AI_RESEARCH[@]}") ;;
            esac
        done
    fi
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        echo "[]"
        return
    fi
    if command -v jq &>/dev/null; then
        printf '%s\n' "${pkgs[@]}" | jq -R . | jq -cs 'unique'
    else
        local out="[" sep="" p
        for p in "${pkgs[@]}"; do
            local esc="${p//\\/\\\\}"; esc="${esc//\"/\\\"}"
            out+="${sep}\"${esc}\""
            sep=","
        done
        out+="]"
        echo "$out"
    fi
}

# 0 when the installed Claude Code CLI is at least $1.$2.$3.
claude_version_at_least() {
    local ver major minor patch
    ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || return 1
    [[ -z "$ver" ]] && return 1
    IFS='.' read -r major minor patch <<< "$ver"
    (( major > $1 || (major == $1 && minor > $2) || (major == $1 && minor == $2 && patch >= $3) ))
}

_supports_auto_mode() {
    # Auto mode requires Claude Code >= 2.1.80 (shipped 2026-03-24)
    local ver
    ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || return 1
    [[ -z "$ver" ]] && return 1
    local major minor patch
    IFS='.' read -r major minor patch <<< "$ver"
    # 2.1.80+
    (( major > 2 || (major == 2 && minor > 1) || (major == 2 && minor == 1 && patch >= 80) ))
}

# Compose the incoming settings from the shared templates under
# platforms/claude/templates/ (the same fragments the agent-guided path merges
# one by one) plus the fork's plugins.json. statusline.json and
# lessons-hooks.json are only included when that item is selected, so the
# composed file never carries a statusLine or SessionStart hook the user did
# not ask for. Objects are deep-merged in order; the fragments share no arrays.
# Echoes the path of a temp file holding the result; the caller deletes it.
compose_settings_template() {
    local with_sl="$1" with_lh="$2"
    local t="$CLAUDE_TEMPLATES_DIR"
    local parts=("$t/settings.json" "$t/permissions.json" "$t/plugins.json")
    [[ "$with_sl" == true ]] && parts+=("$t/statusline.json")
    [[ "$with_lh" == true ]] && parts+=("$t/lessons-hooks.json")
    local p
    for p in "${parts[@]}"; do
        if [[ ! -f "$p" ]]; then
            error "Settings template missing: $p" >&2
            return 1
        fi
    done
    local out
    out="$(mktemp)" || return 1
    if command -v jq &>/dev/null; then
        if ! jq -s 'reduce .[] as $x ({}; . * $x)' "${parts[@]}" > "$out"; then
            rm -f "$out"
            return 1
        fi
    elif command -v python3 &>/dev/null; then
        if ! python3 - "${parts[@]}" > "$out" <<'PY'
import json
import sys


def merge(base, over):
    result = dict(base)
    for key, value in over.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


composed = {}
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        composed = merge(composed, json.load(handle))
json.dump(composed, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY
        then
            rm -f "$out"
            return 1
        fi
    else
        rm -f "$out"
        error "Neither jq nor python3 is available to compose settings.json" >&2
        return 1
    fi
    echo "$out"
}

install_settings() {
    info "Installing settings.json..."

    # Hoist jq install — both the merge branch and the fresh-install selection filter
    # need it. Without this, fresh installs on jq-less machines silently skipped
    # the plugin filter (bug_003) when statusline+lessons were both kept default-on.
    install_jq || true

    # Dry-run never reads the composed content (every dry-run branch below only
    # prints), so skip the temp-file write to keep the preview side-effect-free.
    local incoming=""
    if ! $DRY_RUN; then
        if ! incoming="$(compose_settings_template "$INSTALL_STATUSLINE" "$INSTALL_LESSONS")"; then
            error "Could not compose settings.json from $CLAUDE_TEMPLATES_DIR"
            (( INSTALL_CRITICAL++ )) || true
            return
        fi
    fi
    _install_settings_from "$incoming"
    [[ -n "$incoming" ]] && rm -f "$incoming"
    return 0
}

_install_settings_from() {
    local incoming="$1"

    # Auto mode detection: downgrade to bypassPermissions if Claude Code is too old
    local USE_AUTO_MODE=true
    if ! command -v claude &>/dev/null; then
        USE_AUTO_MODE=false
        info "Claude Code not found — defaulting to bypassPermissions (auto mode available after install)"
    elif ! _supports_auto_mode; then
        USE_AUTO_MODE=false
        warn "Claude Code too old for auto mode (requires >= 2.1.80) — falling back to bypassPermissions"
    fi

    if [[ ! -f "$CLAUDE_DIR/settings.json" ]]; then
        # New file: copy with optional field stripping
        if $DRY_RUN; then
            info "Would copy: settings.json -> $CLAUDE_DIR/settings.json"
            $INSTALL_STATUSLINE || info "  - statusLine: skipped (not selected)"
            $INSTALL_LESSONS    || info "  - hooks.SessionStart: skipped (not selected)"
            $CO_AUTHOR          && info "  - includeCoAuthoredBy: true" || info "  - includeCoAuthoredBy: skipped (not selected)"
        else
            # statusLine / SessionStart are already absent from $incoming when
            # their item is not selected (see compose_settings_template).
            cp "$incoming" "$CLAUDE_DIR/settings.json"
            # Downgrade auto -> bypassPermissions if Claude Code too old
            if ! $USE_AUTO_MODE && [[ -f "$CLAUDE_DIR/settings.json" ]]; then
                if command -v jq &>/dev/null; then
                    local tmp; tmp=$(jq '.permissions.defaultMode = "bypassPermissions"' "$CLAUDE_DIR/settings.json")
                    echo "$tmp" > "$CLAUDE_DIR/settings.json"
                else
                    local sedtmp="$CLAUDE_DIR/settings.json.sedtmp"
                    sed 's/"defaultMode": "auto"/"defaultMode": "bypassPermissions"/' "$CLAUDE_DIR/settings.json" > "$sedtmp" && mv "$sedtmp" "$CLAUDE_DIR/settings.json"
                fi
            fi
            # Set Co-authored-by preference
            if $CO_AUTHOR && [[ -f "$CLAUDE_DIR/settings.json" ]]; then
                if command -v jq &>/dev/null; then
                    local tmp; tmp=$(jq '.includeCoAuthoredBy = true' "$CLAUDE_DIR/settings.json")
                    echo "$tmp" > "$CLAUDE_DIR/settings.json"
                else
                    local sedtmp="$CLAUDE_DIR/settings.json.sedtmp"
                    sed 's/"includeCoAuthoredBy": false/"includeCoAuthoredBy": true/' "$CLAUDE_DIR/settings.json" > "$sedtmp" && mv "$sedtmp" "$CLAUDE_DIR/settings.json"
                fi
                ok "Co-authored-by: Claude enabled in commits"
            fi
            # Apply enabledPlugins selection filter. Catalogue = source keys ∪ selection,
            # so plugins picked in the menu that aren't declared in the shipped
            # settings.json (e.g. codex) still land as true. A fresh file has
            # nothing to disable, so every mode gets it: template keys that were
            # not selected (and so are not installed) are written as false.
            if command -v jq &>/dev/null && [[ -f "$CLAUDE_DIR/settings.json" ]]; then
                local sel_json; sel_json="$(_effective_selected_plugins_json)"
                local tmp; tmp="$(jq --argjson selected "$sel_json" '
                    ($selected | reduce .[] as $p ({}; .[$p] = true)) as $sel |
                    .enabledPlugins = (((.enabledPlugins // {}) + $sel) | to_entries | map({key, value: ($sel[.key] // false)}) | from_entries)
                ' "$CLAUDE_DIR/settings.json")"
                echo "$tmp" > "$CLAUDE_DIR/settings.json"
            fi
            ok "settings.json installed (new)"
        fi
        return
    fi

    # File exists: smart merge with jq if available (jq was hoisted at function start)
    if ! command -v jq &>/dev/null; then
        warn "settings.json already exists and jq is not installed"
        warn "  Cannot perform smart merge. Please merge manually:"
        warn "  Source: $CLAUDE_TEMPLATES_DIR/{settings,permissions,plugins,statusline,lessons-hooks}.json"
        warn "  Target: $CLAUDE_DIR/settings.json"
        (( INSTALL_CRITICAL++ )) || true
        return
    fi

    # Validate existing settings.json before merge
    if ! jq empty "$CLAUDE_DIR/settings.json" 2>/dev/null; then
        error "Existing settings.json is not valid JSON — cannot merge safely"
        error "  Fix the file manually: $CLAUDE_DIR/settings.json"
        error "  Validate with: jq empty $CLAUDE_DIR/settings.json"
        # Back up the broken file so the user can inspect it
        cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.broken"
        warn "Broken file backed up to settings.json.broken"
        (( INSTALL_CRITICAL++ )) || true
        return
    fi

    if $DRY_RUN; then
        info "Would smart-merge settings.json (jq available)"
        info "  - env: incoming as defaults, existing overrides"
        info "  - permissions.allow: union of arrays"
        if plugin_reconcile_enabled; then
            info "  - enabledPlugins: selection-aware rebuild (unselected known plugins disabled, unknown plugins preserved)"
        else
            info "  - enabledPlugins: additive (selected enabled, existing preserved, nothing disabled)"
        fi
        if $INSTALL_LESSONS; then
            info "  - hooks.SessionStart: deduplicated by matcher"
        else
            info "  - hooks.SessionStart: skipped (not selected)"
        fi
        if $INSTALL_STATUSLINE; then
            info "  - statusLine: incoming takes priority"
        else
            info "  - statusLine: skipped (not selected)"
        fi
        if $CO_AUTHOR; then
            info "  - includeCoAuthoredBy: true"
        else
            info "  - includeCoAuthoredBy: skipped (not selected)"
        fi
        return
    fi

    local existing="$CLAUDE_DIR/settings.json"
    local merged
    merged="$(mktemp)"

    local inc_sl=false inc_lh=false
    $INSTALL_STATUSLINE && inc_sl=true
    $INSTALL_LESSONS && inc_lh=true

    # Build JSON array of effective selected plugin packages. When plugins were
    # interacted with this run, unselected-but-locally-present plugins are disabled.
    local selected_json
    selected_json="$(_effective_selected_plugins_json)"
    local apply_sel=false
    # Only a reconciling (interactive) run disables unselected plugins; --all,
    # --only and the non-interactive default never disable anything.
    plugin_reconcile_enabled && apply_sel=true

    # Tombstoned plugin keys to strip from a user's existing enabledPlugins on upgrade.
    local removed_json
    removed_json="$(printf '%s\n' "${PLUGINS_REMOVED[@]}" | jq -R . | jq -s .)"

    jq -s --argjson inc_sl "$inc_sl" --argjson inc_lh "$inc_lh" \
          --argjson selected "$selected_json" --argjson apply_sel "$apply_sel" \
          --argjson removed "$removed_json" '
    def unique_array: [.[] | tostring] | unique | [.[] | fromjson? // .];

    # $base = incoming (defaults), $over = existing (user overrides)
    .[0] as $base | .[1] as $over |

    # env: incoming as defaults, existing overrides
    ($base.env // {}) * ($over.env // {}) as $env |

    # permissions.allow: union
    (($base.permissions.allow // []) + ($over.permissions.allow // []) | unique) as $allow |

    # enabledPlugins:
    # When $apply_sel is true, apply the selection filter ONLY to keys the installer
    # knows about (keys of $base.enabledPlugins) — those become true iff in $selected,
    # else false. Keys that exist only in $over (user-added plugins outside our
    # catalogue) are preserved verbatim so the installer never silently disables
    # third-party plugins.
    # When $apply_sel is false, fall back to union (existing wins on conflict).
    (($selected | reduce .[] as $p ({}; .[$p] = true))) as $sel |
    (if $apply_sel then
       (
         # Known catalogue = $base keys + $sel keys (so plugins picked in the menu
         # that are not declared in the shipped settings.json — e.g. codex —
         # still land in enabledPlugins as true).
         (($base.enabledPlugins // {}) + $sel) as $catalogue |
         ($catalogue | to_entries
           | map({key, value: ($sel[.key] // false)}) | from_entries) as $known_map |
         (($catalogue | keys)) as $known_keys |
         (($over.enabledPlugins // {})
           | with_entries(select(.key as $k | ($known_keys | index($k)) | not))) as $over_only |
         ($known_map + $over_only)
       )
     else
       # Additive: existing ($over) wins on conflict per the documented promise;
       # template keys the user does not have yet are added as false (they are
       # not installed by this run), and the selection of this run is enabled.
       ((($base.enabledPlugins // {}) | map_values(false)) * ($over.enabledPlugins // {}) + $sel)
     end) as $plugins_pre |
    # Strip tombstoned (removed) plugins so they do not linger enabled after upgrade.
    (reduce $removed[] as $r ($plugins_pre; del(.[$r]))) as $plugins |

    # hooks.SessionStart: deduplicate by matcher (only merge incoming if lessons selected).
    # Existing entries that are the installer-managed lessons hook (their command
    # sets LESSONS_FILE=) are dropped first so the current template replaces an
    # older copy — e.g. one without the 9,000-byte guard against the Claude Code
    # 10,000-character hook-output preview. Other existing entries still win.
    (if $inc_lh then
      (($over.hooks.SessionStart // [])
        | map(select(((.hooks // []) | map(.command? // "") | any(test("LESSONS_FILE="))) | not))) as $over_ss |
      (($base.hooks.SessionStart // []) + $over_ss)
      | group_by(.matcher)
      | map(last)
    else
      ($over.hooks.SessionStart // [])
    end) as $session_hooks |

    # statusLine: use incoming if selected, otherwise preserve existing
    (if $inc_sl then ($base.statusLine // null)
     else ($over.statusLine // null)
    end) as $status_line |

    # Build merged object: start with incoming, overlay existing, then set merged fields
    ($base * $over) * {
      env: $env,
      enabledPlugins: $plugins,
      statusLine: $status_line,
      permissions: (($base.permissions // {}) * ($over.permissions // {}) + {allow: $allow}),
      hooks: (($base.hooks // {}) * ($over.hooks // {}) + {SessionStart: $session_hooks})
    }
    # Remove null statusLine (when neither side had one)
    | if .statusLine == null then del(.statusLine) else . end
    ' "$incoming" "$existing" > "$merged"

    if jq empty "$merged" 2>/dev/null; then
        # Downgrade auto -> bypassPermissions if Claude Code too old
        if ! $USE_AUTO_MODE; then
            jq '.permissions.defaultMode = "bypassPermissions"' "$merged" > "${merged}.tmp" && mv "${merged}.tmp" "$merged"
        fi
        # Set Co-authored-by preference
        if $CO_AUTHOR; then
            jq '.includeCoAuthoredBy = true' "$merged" > "${merged}.tmp" && mv "${merged}.tmp" "$merged"
            ok "Co-authored-by: Claude enabled in commits"
        fi
        mv "$merged" "$existing"
        ok "settings.json smart-merged"
    else
        rm -f "$merged"
        error "Merge produced invalid JSON — keeping existing file"
        warn "Please merge manually: $CLAUDE_TEMPLATES_DIR/*.json -> $existing"
        (( INSTALL_CRITICAL++ )) || true
    fi
}

install_rules() {
    info "Installing rules..."
    $DRY_RUN || mkdir -p "$CLAUDE_DIR/rules"

    # Writing style rule: a single file that replaces the retired Common rules.
    local ws_src="$CLAUDE_TEMPLATES_DIR/rules/writing-style.md"
    local ws_dst="$CLAUDE_DIR/rules/writing-style.md"
    if $INSTALL_WRITING_STYLE; then
        if $DRY_RUN; then
            info "Would copy: rules/writing-style.md -> $ws_dst"
        elif [[ -f "$ws_src" ]]; then
            cp "$ws_src" "$ws_dst"
            ok "Writing style rule installed"
        else
            error "Writing style rule not found: $ws_src"
        fi
    elif $RULE_LANGS_EXPLICIT && [[ -f "$ws_dst" && -f "$ws_src" ]] && cmp -s "$ws_src" "$ws_dst"; then
        # Deselected in the menu: remove only an unmodified copy of our file.
        if $DRY_RUN; then
            info "Would remove unselected: $ws_dst"
        else
            rm -f "$ws_dst"
            ok "Removed unselected rule: writing-style.md"
        fi
    fi

    # Retired files from earlier installs are reported, not deleted: they may
    # carry user edits (see docs/migration.md#common-rules), and both would
    # otherwise keep loading as rules next to the new ones.
    if [[ -d "$CLAUDE_DIR/rules/common" ]]; then
        warn "Retired Common rules still present: $CLAUDE_DIR/rules/common/ — review and remove it manually (writing-style.md replaces it)"
    fi
    if [[ -f "$CLAUDE_DIR/rules/README.md" ]]; then
        warn "Legacy $CLAUDE_DIR/rules/README.md loads as a rule — remove it manually unless you added it yourself"
    fi

    # Determine which language rules to install
    local langs=()
    if [[ ${#RULE_LANGS[@]} -gt 0 ]]; then
        langs=("${RULE_LANGS[@]}")
    elif ! $RULE_LANGS_EXPLICIT && ! $ONLY_MODE; then
        # Auto-detect: install all available languages (--all mode or legacy)
        for lang_dir in "$CLAUDE_TEMPLATES_DIR"/rules/*/; do
            local lang
            lang=$(basename "$lang_dir")
            [[ "$lang" == "common" || "$lang" == "README.md" ]] && continue
            langs+=("$lang")
        done
    fi
    # If RULE_LANGS_EXPLICIT=true and RULE_LANGS is empty, skip language rules

    # Use `"${arr[@]+"${arr[@]}"}"` for langs: macOS ships bash 3.2 where the
    # plain form aborts under `set -u` when the array is empty (selective install
    # picking rules-writing-style with no language rules).
    for lang in "${langs[@]+"${langs[@]}"}"; do
        if [[ -d "$CLAUDE_TEMPLATES_DIR/rules/$lang" ]]; then
            if $DRY_RUN; then
                info "Would copy: rules/$lang/ -> $CLAUDE_DIR/rules/$lang/"
            else
                rm -rf "$CLAUDE_DIR/rules/$lang"
                cp -r "$CLAUDE_TEMPLATES_DIR/rules/$lang" "$CLAUDE_DIR/rules/$lang"
                ok "$lang rules installed"
            fi
        else
            error "Language rules not found: $lang"
        fi
    done

    # Clean up known language rule dirs that were NOT selected (from previous installs)
    # Only removes languages this installer knows about; preserves user-created dirs
    if $RULE_LANGS_EXPLICIT; then
        local known_langs=("python" "typescript" "golang")
        for known in "${known_langs[@]}"; do
            local keep=false
            for lang in "${langs[@]+"${langs[@]}"}"; do
                if [[ "$lang" == "$known" ]]; then
                    keep=true
                    break
                fi
            done

            if ! $keep && [[ -d "$CLAUDE_DIR/rules/$known" ]]; then
                if $DRY_RUN; then
                    info "Would remove unselected: $CLAUDE_DIR/rules/$known/"
                else
                    rm -rf "$CLAUDE_DIR/rules/$known"
                    ok "Removed unselected rules: $known"
                fi
            fi
        done
    fi

}

install_skills() {
    info "Installing custom skills..."
    $DRY_RUN || mkdir -p "$CLAUDE_DIR/skills"

    # Migration removes only explicitly provenance-backed retired content.
    for old_skill in "update"; do
        if [[ -d "$CLAUDE_DIR/skills/$old_skill" ]]; then
            if $DRY_RUN; then
                info "Would remove legacy skill: $old_skill"
            else
                rm -rf "$CLAUDE_DIR/skills/$old_skill"
                ok "Removed legacy skill: $old_skill"
            fi
        fi
    done

    # If specific skills were selected (interactive mode / --only), install only those
    if [[ ${#SELECTED_SKILLS[@]} -gt 0 ]]; then
        for skill in "${SELECTED_SKILLS[@]}"; do
            local skill_dir; skill_dir="$(skill_source_dir "$skill")"
            if is_agent_managed_elsewhere "skills/$skill"; then
                info "Skill $skill is managed by edit-config (agent-config/files.json) — left unchanged"
            elif [[ -d "$skill_dir" ]]; then
                if $DRY_RUN; then
                    info "Would copy: ${skill_dir#"$SCRIPT_DIR"/}/ -> $CLAUDE_DIR/skills/$skill/"
                else
                    rm -rf "$CLAUDE_DIR/skills/$skill"
                    cp -r "$skill_dir" "$CLAUDE_DIR/skills/$skill"
                    ok "Skill installed: $skill"
                fi
            else
                warn "Skill not found: $skill"
            fi
        done
    else
        # --all mode: install every script-owned skill except the opt-in ones
        local skill opt
        for skill in "${SCRIPT_OWNED_SKILLS[@]}"; do
            local opt_in=false
            for opt in "${SCRIPT_OPT_IN_SKILLS[@]}"; do
                [[ "$opt" == "$skill" ]] && opt_in=true
            done
            $opt_in && continue
            local skill_dir; skill_dir="$(skill_source_dir "$skill")"
            if [[ ! -d "$skill_dir" ]]; then
                warn "Skill not found: $skill"
                continue
            fi
            if is_agent_managed_elsewhere "skills/$skill"; then
                info "Skill $skill is managed by edit-config (agent-config/files.json) — left unchanged"
                continue
            fi

            if $DRY_RUN; then
                info "Would copy: ${skill_dir#"$SCRIPT_DIR"/}/ -> $CLAUDE_DIR/skills/$skill/"
            else
                rm -rf "$CLAUDE_DIR/skills/$skill"
                cp -r "$skill_dir" "$CLAUDE_DIR/skills/$skill"
                ok "Skill installed: $skill"
            fi
        done
    fi

    # Clean up installer-managed skills that were NOT selected (from previous installs)
    # Only runs for a full (interactive) selection; --only is additive.
    if $FULL_SELECTION && [[ ${#SELECTED_SKILLS[@]} -gt 0 ]]; then
        for known in "${SCRIPT_OWNED_SKILLS[@]}"; do
            local keep=false
            for skill in "${SELECTED_SKILLS[@]}"; do
                if [[ "$skill" == "$known" ]]; then
                    keep=true
                    break
                fi
            done
            if ! $keep && [[ -d "$CLAUDE_DIR/skills/$known" ]] \
               && ! is_agent_managed_elsewhere "skills/$known"; then
                if $DRY_RUN; then
                    info "Would remove unselected skill: $known"
                else
                    rm -rf "$CLAUDE_DIR/skills/$known"
                    ok "Removed unselected skill: $known"
                fi
            fi
        done
    fi
}

install_agents() {
    info "Installing custom agents..."
    $DRY_RUN || mkdir -p "$CLAUDE_DIR/agents"
    for agent_file in "$SCRIPT_DIR"/agents/*.md; do
        [[ -f "$agent_file" ]] || continue
        local agent
        agent=$(basename "$agent_file")
        if $DRY_RUN; then
            info "Would copy: agents/$agent -> $CLAUDE_DIR/agents/$agent"
        else
            cp "$agent_file" "$CLAUDE_DIR/agents/$agent"
            ok "Agent installed: $agent"
        fi
    done
}

# User-facing maintenance scripts to install into ~/.claude/scripts.
# Repo-dev-only scripts (e.g. check-readme-sync.sh) are deliberately excluded.
# image-gen-openrouter.py is the always-installed OpenRouter image wrapper
# consumed by the network-installed sinedied/agent-skills:image-gen Skill (see
# install_image_gen). It is installed as a user script so uninstall removes it
# through the same USER_SCRIPTS loop.
USER_SCRIPTS=("cleanup-claude-data.sh" "image-gen-openrouter.py")

# Wrapper superseded by image-gen-openrouter.py, removed from ~/.claude on the
# next install so it does not linger past the uninstall loop that no longer
# knows about it.
SUPERSEDED_USER_SCRIPTS=("image-gen-cliproxyapi.sh")

install_scripts() {
    info "Installing maintenance scripts..."
    [[ -d "$SCRIPT_DIR/scripts" ]] || { info "No scripts/ directory in source, skipping"; return; }
    $DRY_RUN || mkdir -p "$CLAUDE_DIR/scripts"
    for script in "${USER_SCRIPTS[@]}"; do
        local src="$SCRIPT_DIR/scripts/$script"
        [[ -f "$src" ]] || { warn "Expected script missing in source: $script"; continue; }
        if $DRY_RUN; then
            info "Would copy: scripts/$script -> $CLAUDE_DIR/scripts/$script"
        else
            cp "$src" "$CLAUDE_DIR/scripts/$script"
            chmod +x "$CLAUDE_DIR/scripts/$script"
            ok "Script installed: $script (run manually; not auto-executed)"
        fi
    done
    for script in "${SUPERSEDED_USER_SCRIPTS[@]}"; do
        local stale="$CLAUDE_DIR/scripts/$script"
        [[ -f "$stale" ]] || continue
        if $DRY_RUN; then
            info "Would remove superseded script: $stale"
        else
            rm -f "$stale" && ok "Removed superseded script: $script"
        fi
    done
}

# Run the installed data-cleanup script. Reuses scripts/cleanup-claude-data.sh
# (installed by install_scripts) rather than duplicating its logic here.
# In DRY_RUN the cleanup runs in its own dry-run mode (no --apply), which only
# reports sizes and never deletes.
run_cleanup() {
    local script="$CLAUDE_DIR/scripts/cleanup-claude-data.sh"
    if [[ ! -f "$script" ]]; then
        info "Cleanup script not installed; skipping data cleanup"
        return
    fi
    if $DRY_RUN; then
        info "Would run data cleanup (dry-run report):"
        if [[ -d "$CLAUDE_DIR" ]]; then
            bash "$script" || true
        else
            info "  (skipped report — $CLAUDE_DIR does not exist yet)"
        fi
        return
    fi
    info "Running Claude data cleanup (--apply)..."
    bash "$script" --apply || warn "Data cleanup reported a non-fatal error"
}

install_shell_wrapper() {
    info "Installing shell wrapper (claude.zsh)..."
    local target="$CLAUDE_DIR/claude.zsh"
    [[ -f "$target" ]] && WRAPPER_PREEXISTED=true
    if $DRY_RUN; then
        info "Would copy: claude.zsh -> $target"
        info "Would copy: system-prompt.txt -> $CLAUDE_DIR/system-prompt.txt"
        info "Would install profiles/*.json (credentials preserved on upgrade)"
        info "Would prompt for the default backend among the installed profiles"
    else
        cp "$SCRIPT_DIR/claude.zsh" "$target"
        ok "Shell wrapper installed to $target"
        if [[ -f "$SCRIPT_DIR/system-prompt.txt" ]]; then
            # Compare with existing — skip if identical
            if [[ -f "$CLAUDE_DIR/system-prompt.txt" ]] && diff -q "$CLAUDE_DIR/system-prompt.txt" "$SCRIPT_DIR/system-prompt.txt" &>/dev/null; then
                ok "system-prompt.txt unchanged, skipping"
            else
                # Content differs: back up existing before overwriting
                if [[ -f "$CLAUDE_DIR/system-prompt.txt" ]]; then
                    cp "$CLAUDE_DIR/system-prompt.txt" "$CLAUDE_DIR/system-prompt.txt.bak"
                    warn "Existing system-prompt.txt backed up to system-prompt.txt.bak — merge your customizations manually"
                fi
                cp "$SCRIPT_DIR/system-prompt.txt" "$CLAUDE_DIR/system-prompt.txt"
                ok "system-prompt.txt installed"
            fi
        fi
        install_profiles

        # Reconcile the GPT CLIProxyAPI backend (idempotent, atomic, safe to
        # skip if no gpt profile is installed). Runs after profile/template
        # copies and before configure_ccr_profile.
        configure_gpt_backend || true   # coordinator records INSTALL_CRITICAL

        # Model slots for gateway backends, which only the live gateway can supply.
        configure_ccr_profile

        # Choose default profile
        choose_default_profile

        if shell_wrapper_is_sourced; then
            ok "Shell wrapper is sourced from ~/.zshrc"
        else
            info "Add to your .zshrc: source ~/.claude/claude.zsh"
        fi
        info "Commands: cl, cl_auto, cl_switch <name>, cl_profiles, and cl_<backend>/cl_<backend>_auto per profile"
    fi
}

# Fields in the user's copy ($2) that diverge from the template it was installed
# from ($1), excluding everything the template lists in credentialKeys (those are
# carried over, never reset). env entries are reported as "env.KEY", top-level
# fields by their own name. Prints one field per line; empty output means the
# file is a pristine template plus credentials.
profile_user_edits() {
    local base="$1" cur="$2"
    jq -r -n --slurpfile b "$base" --slurpfile c "$cur" '
        ($b[0].credentialKeys // []) as $cred
        | def strip: (.env // {}) | with_entries(select(.key as $k | $cred | index($k) | not));
          def top: del(.env);
          ($b[0] | strip) as $be | ($c[0] | strip) as $ce
        | ($b[0] | top) as $bt | ($c[0] | top) as $ct
        | (($be + $ce) | keys_unsorted | map(select($be[.] != $ce[.])) | map("env." + .))
          + (($bt + $ct) | keys_unsorted | map(select($bt[.] != $ct[.])))
        | .[]' 2>/dev/null || true
}

# Install ~/.claude/profiles/*.json. "claude" is always installed — it is the
# zero-config native backend and the fallback for an unknown default-profile.
# On upgrade the template supplies fresh model/service defaults while every key
# listed in the profile's own credentialKeys is carried over from the user's
# copy, so an API key survives any number of re-installs. A copy of the template
# each profile was installed from is kept in profiles/.baseline/ so a re-install
# can tell a hand-edit apart from an upstream template change and warn about the
# fields it is about to reset.
install_profiles() {
    local src_dir="$SCRIPT_DIR/profiles"
    local dst_dir="$CLAUDE_DIR/profiles"
    [[ -d "$src_dir" ]] || return 0

    # `${a[@]+...}` guards the empty-array expansion, which is fatal under set -u
    # on the bash 3.2 that ships with macOS.
    local -a wanted=()
    local p
    for p in claude ${SELECTED_PROFILES[@]+"${SELECTED_PROFILES[@]}"}; do
        case " ${wanted[*]-} " in *" $p "*) continue ;; esac
        wanted+=("$p")
    done

    if $DRY_RUN; then
        info "Would install profiles: ${wanted[*]} -> $dst_dir (credentials preserved on upgrade)"
        info "Would back up and warn about any hand-edited non-credential field a template refresh resets"
        if [[ -f "$CLAUDE_DIR/glm-env.json" && ! -f "$dst_dir/glm.json" ]]; then
            if command -v jq &>/dev/null; then
                info "Would migrate legacy glm-env.json -> $dst_dir/glm.json"
            else
                info "Would skip profile 'glm' (jq missing, cannot migrate glm-env.json without shadowing it)"
            fi
        fi
        return 0
    fi

    mkdir -p "$dst_dir"
    local base_dir="$dst_dir/.baseline"
    mkdir -p "$base_dir"

    # One-time migration of the pre-2.11 single-backend layout. The old flat file
    # is kept (renamed) rather than deleted so a downgrade can still find it.
    # Without jq the token cannot be carried over, and writing the placeholder
    # template would permanently shadow the legacy file in claude.zsh's lookup
    # order — so glm is skipped entirely instead, leaving the working legacy
    # file reachable.
    local legacy="$CLAUDE_DIR/glm-env.json"
    local skip_glm=false
    if [[ -f "$legacy" && ! -f "$dst_dir/glm.json" ]]; then
        if command -v jq &>/dev/null; then
            local migrated
            migrated=$(jq -n \
                --slurpfile ex "$legacy" \
                --slurpfile tpl "$src_dir/glm.json" \
                '$tpl[0] | .env = (.env + (
                    reduce ($tpl[0].credentialKeys // [])[] as $k ({};
                        if ($ex[0][$k] // null) != null then . + {($k): $ex[0][$k]} else . end)
                ))' 2>/dev/null)
            if [[ -n "$migrated" ]]; then
                printf '%s\n' "$migrated" > "$dst_dir/glm.json"
                cp "$src_dir/glm.json" "$base_dir/glm.json"
                mv "$legacy" "$legacy.migrated"
                ok "Migrated glm-env.json -> profiles/glm.json (credentials preserved; old file kept as glm-env.json.migrated)"
            else
                skip_glm=true
                warn "Could not migrate glm-env.json (jq failed to parse it) — skipping profile 'glm'"
                warn "  $legacy is untouched and 'cl_glm' keeps reading it"
                warn "  To finish by hand: cp $src_dir/glm.json $dst_dir/glm.json, then copy ANTHROPIC_AUTH_TOKEN from $legacy into its .env"
            fi
        else
            skip_glm=true
            warn "jq not found — cannot migrate $legacy to profiles/glm.json; skipping profile 'glm'"
            warn "  $legacy is untouched and 'cl_glm' keeps reading it"
            warn "  To finish: install jq and re-run this installer, or cp $src_dir/glm.json $dst_dir/glm.json and copy ANTHROPIC_AUTH_TOKEN from $legacy into its .env"
        fi
    fi

    local name src dst merged edits backup
    for name in "${wanted[@]}"; do
        src="$src_dir/$name.json"
        dst="$dst_dir/$name.json"
        [[ -f "$src" ]] || { warn "No profile template named '$name' — skipping"; continue; }
        [[ "$name" == "glm" ]] && $skip_glm && continue

        if [[ ! -f "$dst" ]]; then
            cp "$src" "$dst"
            cp "$src" "$base_dir/$name.json"
            ok "profile '$name' installed"
            continue
        fi

        if ! command -v jq &>/dev/null; then
            warn "profile '$name' exists but jq not found — leaving it untouched"
            continue
        fi

        merged=$(jq -n \
            --slurpfile ex "$dst" \
            --slurpfile tpl "$src" \
            '$tpl[0] | .env = (.env + (
                reduce ($tpl[0].credentialKeys // [])[] as $k ({};
                    ((($ex[0].env // $ex[0])[$k]) // null) as $v
                    | if $v != null then . + {($k): $v} else . end)
            ))' 2>/dev/null)

        if [[ -z "$merged" ]]; then
            warn "profile '$name' could not be parsed by jq — leaving it untouched"
            continue
        fi

        if [[ "$(printf '%s' "$merged" | jq -S .)" == "$(jq -S . "$dst")" ]]; then
            cp "$src" "$base_dir/$name.json"
            ok "profile '$name' already up to date"
            continue
        fi

        # Compare against the template this copy was installed from. Profiles
        # installed before baselines existed fall back to the new template,
        # which can attribute an upstream change to the user — an extra backup
        # and warning, never a lost edit.
        if [[ -f "$base_dir/$name.json" ]]; then
            edits=$(profile_user_edits "$base_dir/$name.json" "$dst")
        else
            edits=$(profile_user_edits "$src" "$dst")
        fi

        if [[ -n "$edits" ]]; then
            backup="$dst.$(date +%Y%m%d%H%M%S).bak"
            cp "$dst" "$backup"
            warn "profile '$name' had hand-edited fields, now reset to the repo template: $(printf '%s' "$edits" | tr '\n' ' ')"
            warn "  previous file saved as ${backup##*/} — re-apply your changes from it"
        fi
        printf '%s\n' "$merged" > "$dst"
        cp "$src" "$base_dir/$name.json"
        ok "profile '$name' updated (credentials preserved)"
    done
}

# The manual fallback for ccr model slots, printed whenever auto-detection cannot
# run. Deliberately spells out the same end state the interactive picker would have
# written, so following it by hand produces an identical profile.
ccr_manual_slot_hint() {
    local f="$1" base="$2"
    echo "     Fill the model slots later — or just re-run this installer once the gateway is up:"
    echo "     稍后补上模型槽位，或等网关起来后重跑本安装脚本:"
    echo "       1. ccr start                    # gateway on :3456"
    echo "       2. ccr ui                       # :3458 — add providers, then copy the 'Local Gateway' key"
    echo "                                       #   NOT a 'Profile: ...' key — those 401 on /v1/models"
    echo "       3. edit ${f/#$HOME/~}  ->  .env.ANTHROPIC_AUTH_TOKEN"
    echo "       4. curl -s -H 'Authorization: Bearer <that key>' $base/v1/models | jq -r '.data[].id'"
    echo "       5. put one of those ids into .env.ANTHROPIC_DEFAULT_OPUS_MODEL"
    echo "       6. put a cheap id into .env.ANTHROPIC_DEFAULT_FABLE_MODEL — not optional: while it"
    echo "          is empty, every background request (compact, titles, quota probes) goes out as"
    echo "          the literal id 'claude-fable-5' and comes back 400. You never issue those"
    echo "          requests yourself, so picking a model at runtime does not cover them."
    echo "          fable 是后台槽位，这些请求不是你主动发的，运行时选模型覆盖不到，留空必定 400。"
    echo "     Slots 1-5 are safe to skip: cl_ccr then starts without --model and you pick with /model."
    echo "     opus/sonnet/haiku 跳过没问题，cl_ccr 不传 --model，进去用 /model 选即可。"
}

# Fill the ccr profile's model slots from the live gateway.
#
# CCR model ids embed the provider display name the user typed into the web UI —
# "Zhipu AI (China) - Coding Plan/glm-5.3" is a real one — so no template can ship
# them and no installer can guess them. GET /v1/models on the running gateway is the
# only source of truth, which is why this step exists at all rather than being more
# static keys in profiles/ccr.json.
#
# Every failure path here is non-fatal and leaves a working profile: claude.zsh
# passes no --model when the slots are empty, so the user picks from the discovered
# list with /model. The slots live in the profile's credentialKeys, so whatever is
# written here survives later template refreshes untouched.
configure_ccr_profile() {
    local f="$CLAUDE_DIR/profiles/ccr.json"
    [[ -f "$f" ]] || return 0

    if $DRY_RUN; then
        info "Would offer to fill ccr model slots from GET /v1/models on the running gateway"
        info "Would print manual steps instead when the gateway is down, curl/jq are missing, or the key is still a placeholder"
        return 0
    fi

    command -v jq &>/dev/null || { warn "jq not found — skipping ccr model-slot setup"; return 0; }

    local base token
    base=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$f" 2>/dev/null)
    token=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$f" 2>/dev/null)
    [[ -n "$base" ]] || return 0

    echo ""
    info "Backend 'ccr': model slots"

    # No idempotent skip: a configured key means the user may have added/changed
    # providers in 'ccr ui', so re-map the slots on every install run.
    if [[ -z "$token" || "$token" == YOUR_* ]]; then
        warn "  ANTHROPIC_AUTH_TOKEN is still a placeholder — cannot query the gateway yet"
        ccr_manual_slot_hint "$f" "$base"
        return 0
    fi

    # Show what's currently mapped so the user has context when re-filling.
    local cur_o cur_s cur_h cur_b
    cur_o=$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // empty' "$f" 2>/dev/null)
    cur_s=$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty' "$f" 2>/dev/null)
    cur_h=$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // empty' "$f" 2>/dev/null)
    cur_b=$(jq -r '.env.ANTHROPIC_DEFAULT_FABLE_MODEL // empty' "$f" 2>/dev/null)
    if [[ -n "$cur_o$cur_s$cur_h$cur_b" ]]; then
        info "  current: opus=${cur_o:-<empty>} sonnet=${cur_s:-<empty>} haiku=${cur_h:-<empty>} fable=${cur_b:-<empty>}"
    fi

    if ! command -v curl &>/dev/null; then
        warn "  curl not found — cannot query the gateway"
        ccr_manual_slot_hint "$f" "$base"
        return 0
    fi

    # Both header styles: CCR has accepted either depending on version.
    local body=""
    body=$(curl -fsS --max-time 5 \
        -H "Authorization: Bearer $token" \
        -H "x-api-key: $token" \
        "$base/v1/models" 2>/dev/null) || body=""

    if [[ -z "$body" ]]; then
        warn "  $base/v1/models did not answer (gateway down, or the key is a 'Profile: ...' key, which 401s here)"
        ccr_manual_slot_hint "$f" "$base"
        return 0
    fi

    local -a ids=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(printf '%s' "$body" | jq -r '.data[]?.id // empty' 2>/dev/null)

    if [[ ${#ids[@]} -eq 0 ]]; then
        warn "  the gateway answered but published no models — add a provider in 'ccr ui' first"
        ccr_manual_slot_hint "$f" "$base"
        return 0
    fi

    ok "  gateway published ${#ids[@]} model(s)"

    if $FORCE || ! can_interact; then
        # Guessing which of a dozen ids should be "opus" is not the installer's call.
        info "  non-interactive run — not guessing which model belongs in which slot"
        ccr_manual_slot_hint "$f" "$base"
        return 0
    fi

    local i=1
    for id in "${ids[@]}"; do
        printf '     %2d) %s\n' "$i" "$id"
        i=$((i + 1))
    done
    echo "     Map claude's aliases onto these ids. Enter = leave that slot empty."
    echo "     把 claude 的模型别名映射到上面的 id。直接回车 = 该槽位留空。"

    # Slot names spelled out rather than derived via ${s^^}: that expansion is
    # bash 4 only and macOS still ships 3.2. The env var travels alongside the slot
    # in a parallel array instead of being re-derived at the write, so reordering
    # this list can never write one slot's model into another slot's variable.
    local -a slots=(opus sonnet haiku fable)
    local -a slot_vars=(
        ANTHROPIC_DEFAULT_OPUS_MODEL
        ANTHROPIC_DEFAULT_SONNET_MODEL
        ANTHROPIC_DEFAULT_HAIKU_MODEL
        ANTHROPIC_DEFAULT_FABLE_MODEL
    )
    local -a picked=("" "" "" "")
    local s idx choice prompt any_picked=""
    idx=0
    for s in "${slots[@]}"; do
        choice=""
        prompt="     $s [1-${#ids[@]}, Enter=skip]: "
        # Skipping fable is not the same class of decision as skipping opus, so the
        # prompt has to carry the consequence in both languages — "NOT recommended"
        # with no reason attached is worse than no warning at all. It also has to
        # travel with the prompt rather than being echoed separately: in the piped
        # branch the prompt goes to /dev/tty and stdout is not where the user looks.
        if [[ "$s" == fable ]]; then
            prompt="     fable = the background slot (compact / titles / quota probes); leaving it
     empty 400s every one of them, and you never issue those requests yourself.
     fable 是后台槽位，这些请求不是你主动发的：留空必定 400。建议选一个便宜的模型。
     fable [1-${#ids[@]}, Enter=skip — NOT recommended]: "
        fi
        # `|| choice=""` matters: the script runs under `set -e`, so an EOF on stdin
        # (Ctrl-D, or a piped installer whose input is exhausted) would otherwise
        # abort the whole run here — skipping the version stamp and every later step.
        if [[ -t 0 ]]; then
            printf '%s' "$prompt"
            read -r choice || choice=""
        else
            printf '%s' "$prompt" > /dev/tty
            read -r choice </dev/tty || choice=""
        fi
        # 10# forces base 10: a leading-zero answer like 08 is a valid match for the
        # regex but an invalid octal literal, and would abort with a raw arithmetic
        # error instead of the friendly warning below.
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#ids[@]} )); then
            picked[$idx]="${ids[$((10#$choice - 1))]}"
            any_picked=1
        elif [[ -n "$choice" ]]; then
            warn "     not a number in range — leaving $s empty"
        fi
        idx=$((idx + 1))
    done

    if [[ -z "$any_picked" ]]; then
        warn "  all slots empty — cl_ccr starts without --model (pick with /model), but fable has"
        warn "  is used for requests you never issue and will 400 on all of them until it is set"
        return 0
    fi

    # One --arg per *picked* slot, keyed by the slot's own variable name, so the
    # filter and the values cannot drift apart the way four hand-written lines can.
    local -a jq_args=()
    local jq_filter=".env |= (."
    idx=0
    while [[ $idx -lt ${#slots[@]} ]]; do
        if [[ -n "${picked[$idx]}" ]]; then
            jq_args+=(--arg "v$idx" "${picked[$idx]}")
            jq_filter="$jq_filter + {${slot_vars[$idx]}: \$v$idx}"
        fi
        idx=$((idx + 1))
    done
    jq_filter="$jq_filter)"

    local updated
    updated=$(jq "${jq_args[@]}" "$jq_filter" "$f" 2>/dev/null)

    if [[ -z "$updated" ]]; then
        warn "  jq failed to write the slots — profile left untouched"
        ccr_manual_slot_hint "$f" "$base"
        return 0
    fi

    printf '%s\n' "$updated" > "$f"
    idx=0
    while [[ $idx -lt ${#slots[@]} ]]; do
        if [[ -n "${picked[$idx]}" ]]; then
            ok "  ${slots[$idx]} -> ${picked[$idx]}"
        elif [[ "${slots[$idx]}" == fable ]]; then
            warn "  fable -> <empty> — background requests (compact, titles) will 400 until this is set"
        fi
        idx=$((idx + 1))
    done
    return 0
}

# Pick which backend bare `cl` uses. Offers exactly the profiles that are now on
# disk, so the list can never point at a backend the user did not install.
choose_default_profile() {
    local profile_file="$CLAUDE_DIR/default-profile"

    if [[ -f "$profile_file" ]]; then
        ok "default-profile already exists ($(cat "$profile_file")), keeping"
        return 0
    fi

    local -a avail=()
    local f
    for f in "$CLAUDE_DIR/profiles"/*.json; do
        [[ -e "$f" ]] || continue
        local base="${f##*/}"
        avail+=("${base%.json}")
    done
    [[ ${#avail[@]} -eq 0 ]] && avail=("claude")

    local default_profile="claude"
    if can_interact && [[ ${#avail[@]} -gt 1 ]]; then
        echo ""
        info "Which backend should a bare 'cl' use by default?"
        # The bracketed default must be the entry Enter actually selects, i.e. the
        # position of the fallback profile in the list — not a hardcoded 1.
        local default_index=""
        local i=1 n
        for n in "${avail[@]}"; do
            local label=""
            command -v jq &>/dev/null && label=$(jq -r '.label // empty' "$CLAUDE_DIR/profiles/$n.json" 2>/dev/null)
            printf '  %d) %-8s %s\n' "$i" "$n" "$label"
            [[ "$n" == "$default_profile" ]] && default_index="$i"
            i=$((i + 1))
        done
        # Fallback profile absent from the list (should not happen): show no number
        # rather than one that points at some other backend.
        local prompt="  Choose [$default_index]: "
        [[ -z "$default_index" ]] && prompt="  Choose (Enter = $default_profile): "
        local choice=""
        if [[ -t 0 ]]; then
            echo -n "$prompt"
            read -r choice
        else
            echo -n "$prompt" > /dev/tty
            read -r choice </dev/tty
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#avail[@]} )); then
            default_profile="${avail[$((choice - 1))]}"
        fi
    fi

    echo "$default_profile" > "$profile_file"
    ok "Default profile set to: $default_profile"
}

# Credential keys of $1 whose value is still a YOUR_* placeholder. Keys that ship
# with a real value (ANTHROPIC_BASE_URL) are therefore not reported, and a profile
# with no credentialKeys at all (native "claude") yields nothing.
profile_placeholder_keys() {
    jq -r '. as $p
        | (($p.credentialKeys // [])[]) as $k
        | (($p.env // {})[$k] // "")
        | select(type == "string" and startswith("YOUR_"))
        | $k' "$1" 2>/dev/null || true
}

# True when ~/.zshrc already sources the wrapper. Matches
# `source ~/.claude/claude.zsh` and `. $HOME/.claude/claude.zsh` alike, ignoring
# commented-out lines. A missing .zshrc simply means "not set up yet".
shell_wrapper_is_sourced() {
    local rc="$HOME/.zshrc"
    [[ -f "$rc" ]] || return 1
    grep -qE '^[[:space:]]*(source|\.)[[:space:]]+[^#]*claude\.zsh' "$rc" 2>/dev/null
}

# None of the cl* commands exist until the user sources the wrapper themselves —
# the installer never edits a shell rc file. The mid-install info line scrolls past
# during a long run, so repeat it in the closing summary. $1 is the step number;
# returns 1 without printing when the wrapper wasn't installed, so the caller
# keeps its numbering contiguous.
#
# A re-install that still finds no source line is a different situation from a
# first install: the one-time hint was already shown once and missed, so every
# cl* command has been unavailable the whole time. That case warns loudly instead
# of reading as a routine next step.
shell_wrapper_source_hint() {
    local step="$1"
    $INSTALL_SHELL_WRAPPER || return 1

    local wrapper="$CLAUDE_DIR/claude.zsh"
    local line="source ${wrapper/#$HOME/~}"

    if $DRY_RUN; then
        echo "  $step. Would remind you to add '$line' to your ~/.zshrc (the installer never edits it)"
        return 0
    fi

    if shell_wrapper_is_sourced; then
        echo "  $step. Shell wrapper already sourced from ~/.zshrc — nothing to do"
        return 0
    fi

    if $WRAPPER_PREEXISTED; then
        echo ""
        warn "STILL NOT SET UP: ~/.zshrc does not source the wrapper."
        warn "  This is not your first install, so cl, cl_auto, cl_switch, cl_profiles and"
        warn "  every cl_<backend> have never existed in your shell. Nothing you configured"
        warn "  through this installer's backends is reachable until you add the line below."
        echo ""
    fi

    echo "  $step. IMPORTANT: the cl* commands do nothing until you source the wrapper."
    echo "     The installer does not touch your shell config — add this line yourself:"
    echo ""
    echo "         echo '$line' >> ~/.zshrc"
    echo ""
    echo "     Then open a new terminal (or run: source ~/.zshrc)."
    echo "     Not on zsh? Source the same file from your shell's rc; it is written for zsh."
    return 0
}

# Every backend except native "claude" needs a login and/or a pasted credential
# before it works, and a curl|bash user reads this output, not the README. Prints
# one short block per installed profile that is still on placeholders. $1 is the
# step number in the "Next steps" list; returns 1 without printing when there is
# nothing left to do, so the caller keeps its numbering contiguous.
backend_setup_hints() {
    local step="$1"
    local dst_dir="$CLAUDE_DIR/profiles"

    if $DRY_RUN; then
        echo "  $step. Would list any backend still needing a login or an API key (docs/BACKENDS.md)"
        return 0
    fi

    [[ -d "$dst_dir" ]] || return 1

    if ! command -v jq &>/dev/null; then
        echo "  $step. Backends other than 'claude' need a login and an API key before 'cl' works — see docs/BACKENDS.md"
        echo "      除 'claude' 外的后端都需要先登录并填入 API key，'cl' 才能用 —— 见 docs/BACKENDS.zh-CN.md"
        return 0
    fi

    # GPT (CLIProxyAPI) is special-cased: its key is reconciled by the
    # configure_gpt_backend coordinator, so the user never invents or pastes
    # one. Binary install + OAuth (`cliproxyapi --codex-login`) are still
    # required even when the key is already in place, so gpt is always surfaced
    # here when its profile exists. Other backends stay pending-only.
    local gpt_prof="$dst_dir/gpt.json"
    local gpt_cfg_dir="${GPT_CONFIG_DIR:-$HOME/.cli-proxy-api}"
    local gpt_cfg="$gpt_cfg_dir/config.yaml"
    local gpt_configured=false gpt_cfg_key="" gpt_prof_token=""
    if [[ -f "$gpt_prof" ]]; then
        if [[ -f "$gpt_cfg" ]]; then
            gpt_cfg_key=$(gpt_extract_config_key "$gpt_cfg" 2>/dev/null) || gpt_cfg_key=""
        fi
        if [[ -n "$gpt_cfg_key" ]]; then
            gpt_prof_token=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // ""' "$gpt_prof" 2>/dev/null) || gpt_prof_token=""
            # Configured == a readable config key that matches the profile
            # token. Compared by value; neither is ever printed.
            if [[ -n "$gpt_prof_token" && "$gpt_cfg_key" == "$gpt_prof_token" ]]; then
                gpt_configured=true
            fi
        fi
    fi

    local -a pending=()
    local f name
    local gpt_present=false
    [[ -f "$gpt_prof" ]] && gpt_present=true
    for f in "$dst_dir"/*.json; do
        [[ -e "$f" ]] || continue
        name="${f##*/}"; name="${name%.json}"
        # gpt is surfaced unconditionally below regardless of placeholder state.
        [[ "$name" == "gpt" ]] && continue
        [[ -n "$(profile_placeholder_keys "$f")" ]] && pending+=("$name")
    done
    if $gpt_present; then
        if [[ ${#pending[@]} -eq 0 ]]; then
            pending=("gpt")
        else
            pending=("gpt" "${pending[@]}")
        fi
    fi
    [[ ${#pending[@]} -eq 0 ]] && return 1

    local default_profile=""
    [[ -f "$CLAUDE_DIR/default-profile" ]] && default_profile=$(cat "$CLAUDE_DIR/default-profile")

    echo "  $step. Finish setting up the backend(s) you installed:"
    echo "      完成已安装后端的配置（按下面的编号顺序走完即可）:"
    local bin cand hint fields k n
    for name in "${pending[@]}"; do
        f="$dst_dir/$name.json"
        echo ""
        echo "     [$name] $(jq -r '.label // empty' "$f" 2>/dev/null)"

        # Same resolution as claude.zsh: first candidate on PATH wins; when none
        # is installed, show how to get it and leave {bin} as <binary>.
        bin=""
        while IFS= read -r cand; do
            [[ -z "$cand" ]] && continue
            if command -v "$cand" &>/dev/null; then bin="$cand"; break; fi
        done < <(jq -r '.service.bins[]? // empty' "$f" 2>/dev/null)

        # Number sub-steps dynamically so they stay contiguous (1,2,3,...) even
        # when 'install' is skipped because the binary is already on PATH.
        n=0
        if [[ -z "$bin" ]]; then
            hint=$(jq -r '.service.installHint // empty' "$f" 2>/dev/null)
            if [[ -n "$hint" ]]; then
                n=$((n + 1))
                echo "       $n. install / 安装:  $hint"
            fi
            bin="<binary>"
        fi

        hint=$(jq -r '.service.loginHint // empty' "$f" 2>/dev/null)
        if [[ -n "$hint" ]]; then
            n=$((n + 1))
            echo "       $n. login   / 登录:  ${hint//\{bin\}/$bin}"
        fi

        if [[ "$name" == "gpt" ]]; then
            # CLIProxyAPI key is reconciled by configure_gpt_backend; the user
            # never pastes one. Surface completion state without exposing any
            # credential value. When reconciliation did not finish, print the
            # exact config/profile paths and a rerun instruction (no values).
            n=$((n + 1))
            if $gpt_configured; then
                echo "       $n. status / 状态:  GPT key auto-config complete (config ↔ profile synced). No paste needed."
                echo "                       GPT 密钥已自动写入 config.yaml 与 gpt.json，无需手动粘贴。"
            else
                echo "       $n. status / 状态:  GPT key auto-config did not finish — re-run this installer (do NOT paste a key)."
                echo "                       GPT 密钥未自动同步，请重新运行本安装器；不要手动粘贴密钥。"
                echo "          config  / 配置路径:   ${gpt_cfg/#$HOME/~}"
                echo "          profile / Profile:    ${gpt_prof/#$HOME/~}"
            fi
        else
            fields=""
            while IFS= read -r k; do
                [[ -z "$k" ]] && continue
                fields="${fields:+$fields, }.env.$k"
            done < <(profile_placeholder_keys "$f")
            n=$((n + 1))
            echo "       $n. key     / 密钥:  edit ${f/#$HOME/~}  ->  $fields"
            echo "                           把上一步拿到的凭证填进这个文件的对应字段"
        fi

        # No #anchor: GitHub slugifies "### `ccr` — one /model list…" into
        # #ccr--one-model-list-across-providers, so a bare #$name would 404.
        n=$((n + 1))
        echo "       $n. guide   / 详细步骤:  docs/BACKENDS.md  (中文: docs/BACKENDS.zh-CN.md)"
    done

    if [[ -n "$default_profile" ]]; then
        case " ${pending[*]} " in
            *" $default_profile "*)
                warn "Default profile '$default_profile' is not configured yet — a bare 'cl' will fail until the step above is done (use 'cl_claude' meanwhile)"
                ;;
        esac
    fi
    echo ""
    echo "     Nothing here is optional — a backend stays unusable until every step above is done."
    echo "     任何一步没做，对应的 cl_<backend> 都不能用。"
    return 0
}

# Prints one backend row only when that profile is actually on disk. Rows stay
# literal, pre-padded strings: the table is aligned by hand-counted display
# width (CJK cells are wider than their character count), so nothing here may
# recompute a width. Under --dry-run nothing has been written yet, so every row
# is shown.
cl_launcher_row() {
    local name="$1" row="$2"
    if $DRY_RUN || [[ -f "$CLAUDE_DIR/profiles/$name.json" ]]; then
        echo "      $row"
    fi
    return 0
}

# Lists the cl_* launchers this config exposes, so users know what they can run
# right after install. Backend rows are filtered against the installed profiles
# in $CLAUDE_DIR/profiles/ — a command whose profile is absent would be a
# command-not-found. Models are the ones each backend injects today; readers are
# pointed at docs/BACKENDS.md for the authoritative list.
cl_commands_hint() {
    local step="$1"
    echo "  $step. Launchers — every 'cl_*' starts Claude Code against one backend:"
    echo "      启动器——每个 cl_* 命令对应一个后端，直接进入 Claude Code："
    echo "      | 命令             | 后端 / Backend              | /model 列表                  |"
    echo "      |------------------|----------------------------|------------------------------|"
    cl_launcher_row claude "| cl_claude /_auto | 官方 Claude 订阅            | Opus / Sonnet / Haiku        |"
    cl_launcher_row glm    "| cl_glm    /_auto | 智谱 GLM (BigModel)        | glm-5.3 / glm-5.3-flash      |"
    cl_launcher_row or     "| cl_or     /_auto | OpenRouter (直连)          | DeepSeek V4 Pro / V4 Flash   |"
    cl_launcher_row gpt    "| cl_gpt    /_auto | ChatGPT 订阅 (CLIProxyAPI) | GPT / Codex (代理暴露的模型) |"
    cl_launcher_row ccr    "| cl_ccr    /_auto | CCR gateway                | GLM + GPT 合并成一个列表     |"
    echo "      | cl / cl_auto     | 默认 profile (cl_switch 设) | 同上                         |"
    echo "      | cl_switch [name] | 切换 / 查看默认 profile     | —                            |"
    echo "      | cl_profiles      | 列出全部 profile            | —                            |"
    echo "      | cl_stop [--all]  | 停掉本启动器拉起的 service  | —                            |"
    echo "      '_auto' 后缀 = 自动带 --dangerously-skip-permissions（免确认，仅信任环境用）。"
    echo "      The '_auto' suffix auto-adds --dangerously-skip-permissions (no prompts; trusted envs only)."
    echo "      Models shown in /model depend on each backend — see docs/BACKENDS.md  (中文: docs/BACKENDS.zh-CN.md)"
    return 0
}

# The exact `skills add` invocation. Scoped to the MATTPOCOCK_SKILLS names via
# repeated `--skill` flags — `--skill '*'` would pull every SKILL.md in the repo,
# including personal/in-progress ones we neither track nor uninstall. Installs
# globally to ~/.claude/skills/ for Claude Code only, as real copies (not
# symlinks). Returns the command as an array via the global _MP_NPX_CMD.
_mattpocock_npx_cmd() {
    _MP_NPX_CMD=(npx -y skills@latest add mattpocock/skills --global --agent claude-code --copy --yes)
    local s
    for s in "${MATTPOCOCK_SKILLS[@]}"; do
        _MP_NPX_CMD+=(--skill "$s")
    done
}

_mattpocock_npx() {
    env DO_NOT_TRACK=1 "${_MP_NPX_CMD[@]}" </dev/null
}

install_mattpocock_skills() {
    info "Installing mattpocock/skills (via npx skills)..."
    _mattpocock_npx_cmd
    if ! command -v npx &>/dev/null; then
        warn "npx not found (needs Node.js) — skipping mattpocock/skills (optional)."
        warn "  Install Node.js to get npx: https://nodejs.org"
        warn "  e.g. macOS: 'brew install node' · Debian/Ubuntu: 'sudo apt install nodejs npm' · or use nvm (https://github.com/nvm-sh/nvm)"
        warn "  Then run: DO_NOT_TRACK=1 ${_MP_NPX_CMD[*]}"
        # Optional add-on: do NOT count as an install warning (would block the version stamp).
        return 0
    fi
    if $DRY_RUN; then
        info "Would run: DO_NOT_TRACK=1 ${_MP_NPX_CMD[*]}"
        return 0
    fi
    if retry 3 5 "mattpocock/skills" _mattpocock_npx; then
        ok "mattpocock/skills installed (~/.claude/skills/)"
        # Record what we installed so uninstall removes only these (provenance), never a
        # user-authored skill that merely shares a generic name (teach, handoff, …).
        # Each record carries the SKILL.md digest, so a directory the user later
        # replaces with their own no longer matches and is preserved. Only skills
        # actually present on disk are recorded: a partial copy must not leave us
        # claiming ownership of something npx never wrote.
        local s digest
        local -a records=()
        for s in "${MATTPOCOCK_SKILLS[@]}"; do
            if digest="$(mattpocock_skill_digest "$s")"; then
                records+=("$(printf '%s\t%s' "$s" "$digest")")
            else
                warn "mattpocock/skills: '$s' not found after install; not recording ownership"
            fi
        done
        if ((${#records[@]} > 0)); then
            printf '%s\n' "${records[@]}" | write_mattpocock_manifest || \
                warn "mattpocock/skills installed but ownership was not recorded; '--uninstall' will not remove them"
        else
            warn "mattpocock/skills reported success but no skills were found on disk"
        fi
    else
        warn "Failed to install mattpocock/skills via npx (optional — install skipped)."
        warn "  Retry manually: DO_NOT_TRACK=1 ${_MP_NPX_CMD[*]}"
        # Optional add-on failure is non-fatal: do NOT block the version stamp.
    fi
}

# ============================================================
# image-gen (sinedied/agent-skills) always-installed network Skill.
#
# The upstream Skill is fetched through a bounded argument-array `skills` CLI helper — never vendored. After a successful download the installer
# augments the downloaded SKILL.md with an idempotent managed instructions
# block pointing Claude Code at the repository-owned wrapper, then writes a
# mode-600 ownership manifest so uninstall can delete only an installer-owned
# image-gen directory (never a user-authored one that shares the name).
#
# This component is always installed: it has no selectable flag and no menu
# item. Missing npx or a failed download is non-fatal — it increments
# INSTALL_WARNINGS so the summary surfaces it while letting the rest of the
# install complete.
# ============================================================

# Managed markers wrapping the integration block in the installed SKILL.md.
IMAGE_GEN_BEGIN_MARKER="<!-- BEGIN claude-code-config OpenRouter image-gen integration -->"
IMAGE_GEN_END_MARKER="<!-- END claude-code-config OpenRouter image-gen integration -->"

# Pre-OpenRouter markers. Recognized so an existing CLIProxyAPI-era install is
# still provably installer-owned (and therefore upgradable in place); never
# written. The legacy block is stripped during augmentation.
IMAGE_GEN_LEGACY_BEGIN_MARKER="<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->"
IMAGE_GEN_LEGACY_END_MARKER="<!-- END claude-code-config CLIProxyAPI image-gen integration -->"

# The exact `skills add` invocation. Installs globally to ~/.claude/skills/ as
# real copies (not symlinks) for Claude Code, scoped to the single image-gen
# Skill. Returns the command via the global _IMAGE_GEN_NPX_CMD array.
_image_gen_npx_cmd() {
    _IMAGE_GEN_NPX_CMD=(npx -y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen)
}

# Run the command with DO_NOT_TRACK=1 (so the skills CLI's telemetry stays off)
# and stdin detached from the caller's tty (so an interactive prompt can never
# block a non-interactive install). The key material is never on the command
# line; npx receives only the public source/skill identifiers.
_image_gen_npx() {
    env DO_NOT_TRACK=1 "${_IMAGE_GEN_NPX_CMD[@]}" </dev/null
}

# Render the canonical managed instructions block (the bytes between the
# markers). Pure: no side effects, unit-testable. Tells Claude Code to invoke
# the wrapper, which arguments carry over, where the key comes from, and that a
# key must never be requested from the user or passed on the command line.
# install.ps1's Get-ImageGenIntegrationBlock must emit these bytes verbatim, or
# running both installers against one ~/.claude rewrites SKILL.md each time.
image_gen_render_integration_block() {
    cat <<'EOF'
MANDATORY OVERRIDE — this section supersedes every conflicting instruction in
the rest of this file, including everything above it. Where the two disagree,
this section is correct and the text above is obsolete.

Image generation on this machine runs through OpenRouter, not the OpenAI
Platform. The one and only entry point is:

    python3 ~/.claude/scripts/image-gen-openrouter.py <arguments>

Never invoke `scripts/image_gen.py`, under any circumstances, not even as a
fallback after an error. Every example above that begins with
`python scripts/image_gen.py` is inoperative here — translate it to the wrapper
command before running anything.

## Instructions above that no longer apply

- `python scripts/image_gen.py ...` — superseded by the wrapper path above.
- `OPENAI_API_KEY` — never read. Do not set it, do not export it, do not ask
  the user for one, do not suggest obtaining one.
- A `.env` file in the working directory or any parent — never read. Do not
  create one, and do not tell the user to create one.
- `OPENAI_BASE_URL` — never read. The endpoint is fixed at
  `https://openrouter.ai/api/v1`.
- `OPENAI_IMAGE_MODEL` — never read. The default model is `openai/gpt-image-2`,
  overridable with `--model` or the `IMAGE_GEN_MODEL` environment variable.
- `--api-key` and `--base-url` — rejected by the wrapper. Do not pass either.
- The model table (`gpt-image-1`, `gpt-image-1-mini`, `gpt-image-1.5`,
  `gpt-image-2`) — those are OpenAI Platform ids. OpenRouter ids are
  namespaced, e.g. `openai/gpt-image-2`.
- `--mask` inpainting — rejected. OpenRouter has no mask; describe the region
  to change in the prompt instead.
- `--moderation` — accepted, then ignored.
- Size values like `1024x1024` are still accepted, and so are the tiers `512`,
  `1K`, `2K`, `4K`, `auto`; the wrapper additionally takes `--aspect-ratio` and
  `--resolution`.

The prompt-writing guidance and the `references/sample-prompts.md` recipe step
above remain in force. Only the invocation, authentication, model, and
parameter sections are replaced.

## Authentication

The wrapper resolves the key by itself, from `.env.ANTHROPIC_AUTH_TOKEN` in
`~/.claude/profiles/or.json`, and from nothing else. There is no key to request
from the user and no key to place on the command line. This path has no
relationship to OpenAI whatsoever: an `OPENAI_API_KEY` in the environment is
neither consulted nor helpful, and its absence is never the cause of a failure
here.

When the wrapper reports no usable key, the only correct guidance is: get a key
from https://openrouter.ai/keys and write it into `~/.claude/profiles/or.json`
under `env.ANTHROPIC_AUTH_TOKEN` (re-running the installer and selecting the
OpenRouter backend creates that profile). Never offer `export OPENAI_API_KEY=`
or a `.env` file as a workaround.

## Supported arguments

`generate` / `gen` and `edit`, the prompt, `-i/--image` (repeatable, up to 16,
`edit` only), `-o/--output` (default: current directory), `--model`, `--n`,
`--size`, `--aspect-ratio`, `--resolution`, `--quality`, `--background`,
`--output-format`, `--output-compression`, `--seed`. Image-to-image goes
through `edit` with one or more `-i` reference images. The wrapper posts to
`https://openrouter.ai/api/v1/images`, verifies the target model is listed by
`GET /api/v1/images/models` before generating, writes the returned images to
`--output`, and prints each saved path on stdout.

## Exit codes

- `2` — an argument was rejected (`--api-key`, `--base-url`, `--mask`, or an
  out-of-range value). Correct the command; never route around it by calling
  `image_gen.py` or by setting an OpenAI variable.
- `3` — no usable OpenRouter key. Follow the Authentication guidance above and
  nothing else.
- `4` — the model is not in OpenRouter's image-model list. Re-run with a
  `--model` chosen from the ids the error message prints; do not change
  endpoints and do not fall back to the upstream script.

Requires `python3` on PATH. On native Windows run it from WSL or another
Bash-compatible environment so the `~/.claude` layout matches.
EOF
}

# Idempotently augment the installed image-gen SKILL.md with the managed
# integration block. Single-pass exact-line state validation runs BEFORE any
# write, rejecting: missing layout, end-before-begin, nested/duplicate markers,
# embedded marker text (a line that contains a marker substring but is not an
# exact marker line), and one-sided/unterminated markers. Outside bytes are
# preserved. Atomic: the new content is written to a temp file in the SAME
# directory as the target (same-filesystem rename), the target's mode is
# preserved, and `mv -f` is the only mutation. Paths containing spaces are
# handled via fully-quoted expansion.
#
# $1 = skills directory root (defaults to $CLAUDE_DIR/skills)
image_gen_augment_skill() {
    local skills_dir="${1:-$CLAUDE_DIR/skills}"
    local skill_md="$skills_dir/image-gen/SKILL.md"
    # Download-integrity sanity check, not a runtime dependency: the wrapper no
    # longer invokes image_gen.py, but its presence still proves npx fetched the
    # image-gen layout we expect rather than something else under that name.
    local upstream="$skills_dir/image-gen/scripts/image_gen.py"

    if [[ ! -f "$skill_md" ]]; then
        warn "image-gen: SKILL.md not found at $skill_md — augmentation skipped"
        return 1
    fi
    if [[ ! -f "$upstream" ]]; then
        warn "image-gen: image_gen.py not found at $upstream — augmentation skipped"
        return 1
    fi

    local begin="$IMAGE_GEN_BEGIN_MARKER"
    local end="$IMAGE_GEN_END_MARKER"
    local block
    block="$(image_gen_render_integration_block)"

    local dir base mode_perm tmp
    dir=$(dirname "$skill_md")
    base=$(basename "$skill_md")
    mode_perm=$(stat -f "%Lp" "$skill_md" 2>/dev/null || stat -c "%a" "$skill_md" 2>/dev/null || echo "644")
    [[ -d "$dir" ]] || { warn "image-gen: skills directory missing"; return 1; }
    # Same-directory temp so the final rename is guaranteed atomic on one fs.
    tmp=$(mktemp "${dir}/${base}.augment.XXXXXX" 2>/dev/null) || { warn "image-gen: mktemp failed"; return 1; }

    # Strip any pre-OpenRouter managed block first, so a CLIProxyAPI-era
    # SKILL.md upgrades to exactly one current block instead of accumulating a
    # second one beside the stale text. Two passes over the same file: the first
    # counts and locates the legacy markers, the second removes the interval
    # only when it is a single ordered well-formed pair. Anything else (none,
    # duplicated, one-sided, or end-before-begin) is an identity transform,
    # leaving the text for the current-marker validation below to judge instead
    # of silently truncating the file. Matches install.ps1's legacy strip.
    local work
    work=$(mktemp "${dir}/${base}.legacy.XXXXXX" 2>/dev/null) || {
        rm -f "$tmp"; warn "image-gen: mktemp failed"; return 1
    }
    if ! awk -v lb="$IMAGE_GEN_LEGACY_BEGIN_MARKER" -v le="$IMAGE_GEN_LEGACY_END_MARKER" '
            NR == FNR {
                if ($0 == lb) { nb++; if (nb == 1) bl = FNR }
                else if ($0 == le) { ne++; if (ne == 1) el = FNR }
                next
            }
            FNR == 1 { strip = (nb == 1 && ne == 1 && bl < el) }
            strip && FNR >= bl && FNR <= el { next }
            { print }
        ' "$skill_md" "$skill_md" > "$work" 2>/dev/null; then
        rm -f "$tmp" "$work"
        warn "image-gen: legacy block strip failed"
        return 1
    fi

    # Decide mode via the SHARED strict validator (review round 3 #1): single
    # source of truth for marker-layout validity, identical to what ownership
    # checks use. No duplicated weak grep checks here.
    local mode="reject"
    if _image_gen_markers_strict "$work"; then
        mode="replace"
    elif ! grep -qF -- "$begin" "$work" 2>/dev/null \
         && ! grep -qF -- "$end" "$work" 2>/dev/null; then
        mode="append"
    fi
    if [[ "$mode" == "reject" ]]; then
        rm -f "$tmp" "$work"
        warn "image-gen: SKILL.md markers malformed (duplicate/embedded/mismatched) — augmentation skipped"
        return 1
    fi

    # Emit pass: assumes validated mode. The block carries newlines; BSD awk
    # rejects them in -v, so pass it through ENVIRON. The emit awk does NOT
    # re-validate (the shared validator already did); it only reconstructs.
    local emit_rc=0
    if [[ "$mode" == "replace" ]]; then
        IMAGE_GEN_AWK_BLOCK="$block" awk -v begin="$begin" -v end="$end" '
            BEGIN { in_block=0; block=ENVIRON["IMAGE_GEN_AWK_BLOCK"] }
            $0 == begin { print; print block; in_block=1; next }
            $0 == end   { print; in_block=0; next }
            !in_block { print }
        ' "$work" > "$tmp" 2>/dev/null || emit_rc=$?
    else
        { cat "$work"; printf '\n%s\n%s\n%s\n' "$begin" "$block" "$end"; } > "$tmp" 2>/dev/null || emit_rc=$?
    fi
    if [[ "$emit_rc" -ne 0 ]]; then
        rm -f "$tmp" "$work"
        warn "image-gen: augmentation emit failed"
        return 1
    fi

    # Post-write sanity: the result must itself be strictly valid (one exact
    # begin, one exact end, correct order, no embedded text). Deliberately the
    # CURRENT-marker validator, never the _any variant — what gets written is
    # only ever allowed to be the new format.
    if ! _image_gen_markers_strict "$tmp"; then
        rm -f "$tmp" "$work"
        warn "image-gen: augmentation produced malformed markers — skipped"
        return 1
    fi

    rm -f "$work"
    chmod "$mode_perm" "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$skill_md" 2>/dev/null; then
        rm -f "$tmp"
        warn "image-gen: failed to write SKILL.md"
        return 1
    fi
    return 0
}

# Exact canonical manifest bytes. Kept as a single literal so validation can
# compare byte-for-byte (order, one trailing newline, no extras/CRLF).
_IMAGE_GEN_MANIFEST_CANONICAL="skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-openrouter.py"

# Pre-OpenRouter manifest. Recognized for ownership so an existing install
# upgrades in place instead of being treated as user-authored; never written.
_IMAGE_GEN_MANIFEST_LEGACY="skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-cliproxyapi.sh"

# Write the ownership manifest atomically at mode 600. The manifest is the sole
# authority uninstall uses to decide whether ~/.claude/skills/image-gen was
# installed by this installer.
_image_gen_write_manifest() {
    local manifest="$CLAUDE_DIR/.image-gen-sinedied"
    local dir
    dir=$(dirname "$manifest")
    [[ -d "$dir" ]] || return 1
    local tmp restore_umask
    restore_umask=$(umask)
    umask 077
    tmp=$(mktemp "${dir}/.image-gen-sinedied.tmp.XXXXXX" 2>/dev/null) || {
        umask "$restore_umask"; return 1
    }
    printf '%s\n' "$_IMAGE_GEN_MANIFEST_CANONICAL" > "$tmp" || { rm -f "$tmp"; umask "$restore_umask"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; umask "$restore_umask"; return 1; }
    mv -f "$tmp" "$manifest" || { rm -f "$tmp"; umask "$restore_umask"; return 1; }
    umask "$restore_umask"
    return 0
}

# Validate that an image-gen ownership manifest is byte-for-byte identical to
# the canonical content this installer writes: exactly three lines in order,
# one trailing newline, no duplicates/extras, no CRLF. `cmp -s` gives a true
# byte comparison (a field-by-field grep would accept reordering/duplication).
# Pure: reads one file, returns 0/1.
_image_gen_manifest_valid() {
    local manifest="$1"
    [[ -r "$manifest" ]] || return 1
    printf '%s\n' "$_IMAGE_GEN_MANIFEST_CANONICAL" | cmp -s - "$manifest"
}

# Ownership-only validator: the canonical manifest OR the pre-OpenRouter one.
# The write path (_image_gen_write_manifest) stays canonical-only, so a legacy
# manifest is upgraded exactly once, on the next successful install. Without
# this, every existing install would fail the ownership proof after the wrapper
# rename and be skipped forever as "not installer-owned".
_image_gen_manifest_valid_any() {
    local manifest="$1"
    _image_gen_manifest_valid "$manifest" && return 0
    [[ -r "$manifest" ]] || return 1
    printf '%s\n' "$_IMAGE_GEN_MANIFEST_LEGACY" | cmp -s - "$manifest"
}

# Strict marker-layout validator (review round 3 #1). Single source of truth
# for "does this SKILL.md have a well-formed managed block?" Returns 0 iff the
# file contains exactly one exact-line BEGIN marker, exactly one exact-line END
# marker, BEGIN precedes END, and NO line carries marker text without being an
# exact marker line (embedded prose), with no duplicates, nesting, or
# unterminated state. This is the same validation the augmentation parser
# applies before it writes; ownership uses it so a hand-edited or hostile
# SKILL.md can never authorize deletion/overwrite.
_image_gen_markers_strict() {
    local skill_md="$1"
    [[ -f "$skill_md" && -r "$skill_md" ]] || return 1
    local begin="${2:-$IMAGE_GEN_BEGIN_MARKER}" end="${3:-$IMAGE_GEN_END_MARKER}"
    awk -v begin="$begin" -v end="$end" '
        BEGIN { b=0; e=0; in_block=0; bad=0; emb=0 }
        $0 == begin { if (in_block) bad=1; if (e>0) bad=1; b++; if (b>1) bad=1; in_block=1; next }
        $0 == end   { if (!in_block) bad=1; e++; if (e>1) bad=1; in_block=0; next }
        index($0, begin) > 0 || index($0, end) > 0 { emb=1; next }
        END {
            if (bad || emb) exit 1
            if (b != 1 || e != 1) exit 1
            exit 0
        }
    ' "$skill_md" 2>/dev/null
}

# Ownership-only: a strictly well-formed CURRENT block, or a strictly
# well-formed pre-OpenRouter one. Write paths keep using the strict validator
# above so nothing but the current format is ever emitted.
_image_gen_markers_strict_any() {
    local skill_md="$1"
    _image_gen_markers_strict "$skill_md" && return 0
    _image_gen_markers_strict "$skill_md" \
        "$IMAGE_GEN_LEGACY_BEGIN_MARKER" "$IMAGE_GEN_LEGACY_END_MARKER"
}

# Full ownership proof (review #1): a directory is installer-owned ONLY when a
# valid manifest exists AND the installed SKILL.md passes the STRICT marker
# layout validator. A completed install always writes a strictly-valid marker
# block before the manifest, so a user-created directory with a
# planted/leftover valid manifest but malformed/absent markers is treated as
# unowned and never mutated or deleted.
_image_gen_dir_owned() {
    local skill_dir="$1" manifest="$2"
    [[ -d "$skill_dir" ]] || return 1
    _image_gen_manifest_valid_any "$manifest" || return 1
    _image_gen_markers_strict_any "$skill_dir/SKILL.md" || return 1
    return 0
}

# Adoption proof for a directory whose manifest was lost or corrupted. A
# strictly well-formed managed marker block (current or pre-OpenRouter layout)
# is itself evidence this installer wrote the file: the markers are exact-line
# literals emitted only by image_gen_augment_skill, and the strict validator
# rejects duplicates, nesting, and embedded prose. A directory that carries one
# is therefore upgraded (and its manifest rewritten) instead of being frozen out
# forever. A directory with neither a valid manifest nor a well-formed block
# stays unowned and is never touched.
_image_gen_dir_adoptable() {
    local skill_dir="$1"
    [[ -d "$skill_dir" ]] || return 1
    _image_gen_markers_strict_any "$skill_dir/SKILL.md" || return 1
    return 0
}

# Coordinator. Always-installed (no flag gate). Transactional upgrade semantics:
#   - Prior valid ownership (manifest valid AND dir present): the prior skill
#     directory and manifest are backed up before npx mutation; on ANY later
#     failure (npx, wrapper, augment, manifest write) both are restored, so the
#     on-disk state is exactly the previous good install.
#   - Adoptable directory (dir present with a strictly well-formed managed
#     block but no usable manifest): treated as owned, backed up the same way,
#     upgraded, and given a fresh manifest on success.
#   - Unowned directory present (dir exists with neither proof): the user's
#     directory is NEVER overwritten. The run warns and skips.
#   - Fresh target (no dir): any stale/foreign manifest is removed first (a
#     failed run never claims ownership of nothing); on failure after npx, the
#     partially-downloaded directory is removed so the target returns to fresh.
# Failure is non-fatal to the rest of the install (increments
# INSTALL_WARNINGS, returns 0).
install_image_gen() {
    info "Installing image-gen Skill (sinedied/agent-skills, via npx skills)..."
    _image_gen_npx_cmd

    local skill_dir="$CLAUDE_DIR/skills/image-gen"
    local manifest="$CLAUDE_DIR/.image-gen-sinedied"
    local prior_owned=false
    if _image_gen_dir_owned "$skill_dir" "$manifest"; then
        prior_owned=true
    fi
    local adopt_owned=false
    if ! $prior_owned && _image_gen_dir_adoptable "$skill_dir"; then
        adopt_owned=true
    fi

    if $DRY_RUN; then
        info "Would run: DO_NOT_TRACK=1 ${_IMAGE_GEN_NPX_CMD[*]}"
        $prior_owned && info "Would upgrade prior installer-owned image-gen (backed up first, restored on failure)"
        $adopt_owned && info "Would adopt image-gen (managed block present, manifest missing/invalid), upgrade it, and rewrite the manifest"
        info "Would augment ~/.claude/skills/image-gen/SKILL.md with the managed integration block"
        info "Would write ownership manifest $manifest (mode 600)"
        return 0
    fi

    # Reconcile stale ownership BEFORE every other early return (review #1).
    # A valid manifest with no skill directory is stale ownership of nothing;
    # remove it so it can never later authorize deletion of a directory the
    # user creates themselves. The absent-directory test is the whole premise:
    # when the directory IS present the manifest is live ownership evidence,
    # even if the marker check happens to be failing, and deleting it would
    # destroy the only proof this installer has. (Dry-run returned above, so
    # this write is safe.)
    if [[ ! -d "$skill_dir" ]] && [[ -f "$manifest" ]] && _image_gen_manifest_valid_any "$manifest"; then
        rm -f "$manifest"
        warn "image-gen: removed stale ownership manifest (no image-gen directory present)"
    fi

    # npx availability check comes AFTER reconciliation so a missing-npx run
    # still cleans a stale manifest rather than leaving it to authorize a
    # later user-created directory.
    if ! command -v npx &>/dev/null; then
        warn "npx not found (needs Node.js) — skipping image-gen Skill (always-installed)."
        warn "  Install Node.js to get npx: https://nodejs.org"
        warn "  e.g. macOS: 'brew install node' · Debian/Ubuntu: 'sudo apt install nodejs npm' · or use nvm (https://github.com/nvm-sh/nvm)"
        warn "  Then run: DO_NOT_TRACK=1 ${_IMAGE_GEN_NPX_CMD[*]}"
        (( INSTALL_WARNINGS++ )) || true
        return 0
    fi

    # Unowned directory protection: never overwrite a user-authored/foreign
    # directory that merely collides with the image-gen name. A stale manifest
    # was already invalidated above, so it cannot authorize overwriting this.
    if [[ -d "$skill_dir" ]] && ! $prior_owned && ! $adopt_owned; then
        warn "image-gen: $skill_dir exists but is not installer-owned (no valid manifest, no well-formed managed block) — skipping to avoid overwriting user content"
        # install_scripts already deleted every superseded wrapper unconditionally,
        # with no knowledge of this ownership decision. When the skipped SKILL.md
        # still names one, the two stages have left the user with instructions
        # pointing at a file that no longer exists, so say so in actionable terms
        # rather than only bumping the warning counter.
        local stale_script stale_ref=""
        for stale_script in "${SUPERSEDED_USER_SCRIPTS[@]}"; do
            if [[ -f "$skill_dir/SKILL.md" ]] && grep -qF -- "$stale_script" "$skill_dir/SKILL.md" 2>/dev/null; then
                stale_ref="$stale_script"
                break
            fi
        done
        if [[ -n "$stale_ref" ]]; then
            warn "  BROKEN: $skill_dir/SKILL.md still calls $stale_ref, which this installer has already removed from $CLAUDE_DIR/scripts."
            warn "  Image generation will fail with a missing-file error until you do one of:"
            warn "    (a) rm -rf '$skill_dir' && rm -f '$manifest'   then re-run this installer for a clean managed install"
            warn "    (b) edit $skill_dir/SKILL.md by hand and replace $stale_ref with $CLAUDE_DIR/scripts/image-gen-openrouter.py"
        else
            warn "  To manage image-gen via this installer, remove the directory manually first, then re-run."
        fi
        (( INSTALL_WARNINGS++ )) || true
        return 0
    fi

    # Mandatory upgrade backup (review #2). For a prior-owned install, a verified
    # backup of skill+manifest MUST exist before npx is invoked; any failure
    # aborts the upgrade with prior bytes intact. The backup lives outside the
    # skill directory so the npx overwrite cannot disturb it.
    # An adopted install has no manifest worth preserving (that is why it needed
    # adopting), so backup_manifest records whether the manifest half of the
    # backup exists; restore consults the same flag.
    local backup_dir="" backup_manifest=false
    if $prior_owned || $adopt_owned; then
        backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/image-gen-prev.XXXXXX" 2>/dev/null)
        if [[ -z "$backup_dir" ]]; then
            warn "image-gen: failed to create upgrade backup — aborting upgrade (prior install left intact)"
            (( INSTALL_WARNINGS++ )) || true
            return 0
        fi
        if ! cp -a "$skill_dir" "$backup_dir/image-gen" 2>/dev/null; then
            rm -rf "$backup_dir" 2>/dev/null
            warn "image-gen: failed to copy prior install to backup — aborting upgrade (prior install left intact)"
            (( INSTALL_WARNINGS++ )) || true
            return 0
        fi
        if [[ -f "$manifest" ]] && _image_gen_manifest_valid_any "$manifest"; then
            if ! cp -a "$manifest" "$backup_dir/manifest" 2>/dev/null; then
                rm -rf "$backup_dir" 2>/dev/null
                warn "image-gen: failed to copy prior install to backup — aborting upgrade (prior install left intact)"
                (( INSTALL_WARNINGS++ )) || true
                return 0
            fi
            backup_manifest=true
        fi
        # Verified copies: the skill directory, and the manifest file when one
        # was backed up, must be present and non-empty before we are willing to
        # mutate the target.
        if [[ ! -d "$backup_dir/image-gen" ]] || { $backup_manifest && [[ ! -s "$backup_dir/manifest" ]]; }; then
            rm -rf "$backup_dir" 2>/dev/null
            warn "image-gen: upgrade backup verification failed — aborting upgrade (prior install left intact)"
            (( INSTALL_WARNINGS++ )) || true
            return 0
        fi
    fi

    # Restore helper (review round 3 #2). Returns 0 on verified success, 1 on
    # any failure. NEVER ignores target removal failure, NEVER copies into a
    # surviving target. On failure the backup is RETAINED (never deleted) so
    # manual recovery is possible; the caller emits its path + increments the
    # warning count. The backup is deleted ONLY after a fully verified restore.
    #
    # For a backed-up (prior-owned) install, restore proceeds to a fresh SIBLING
    # temp path, validates the expected layout (dir + scripts/image_gen.py + strict
    # markers + canonical manifest), then atomically renames into place — so a
    # crash never leaves a partially overwritten target.
    _image_gen_restore_prev() {
        if [[ -z "$backup_dir" ]]; then
            # Fresh: remove what npx created so no unowned half-install lingers.
            # Removal MUST succeed and leave no target behind.
            if ! rm -rf "$skill_dir" 2>/dev/null; then return 1; fi
            [[ -e "$skill_dir" ]] && return 1
            rm -f "$manifest" 2>/dev/null || true
            [[ -e "$manifest" ]] && return 1
            return 0
        fi
        # Require target removal success and confirmed absence before restore.
        if ! rm -rf "$skill_dir" 2>/dev/null; then return 1; fi
        [[ -e "$skill_dir" ]] && return 1
        # Restore into a fresh sibling temp dir (same filesystem as the target
        # so the final rename is atomic).
        local parent rtmp
        parent=$(dirname "$skill_dir")
        rtmp=$(mktemp -d "${parent}/.image-gen-restore.XXXXXX" 2>/dev/null) || return 1
        if ! cp -a "$backup_dir/image-gen" "$rtmp/image-gen" 2>/dev/null; then
            rm -rf "$rtmp" 2>/dev/null
            return 1
        fi
        if $backup_manifest && ! cp -a "$backup_dir/manifest" "$rtmp/manifest" 2>/dev/null; then
            rm -rf "$rtmp" 2>/dev/null
            return 1
        fi
        # Validate the restored layout BEFORE renaming: dir, upstream script,
        # strict marker block, and — when a manifest was backed up — a valid
        # manifest must all hold.
        if [[ ! -d "$rtmp/image-gen" ]] \
           || [[ ! -f "$rtmp/image-gen/scripts/image_gen.py" ]] \
           || ! _image_gen_markers_strict_any "$rtmp/image-gen/SKILL.md" 2>/dev/null; then
            rm -rf "$rtmp" 2>/dev/null
            return 1
        fi
        if $backup_manifest && ! _image_gen_manifest_valid_any "$rtmp/manifest" 2>/dev/null; then
            rm -rf "$rtmp" 2>/dev/null
            return 1
        fi
        # Atomic rename into place. The manifest lives one level up.
        if ! mv -f "$rtmp/image-gen" "$skill_dir" 2>/dev/null; then
            rm -rf "$rtmp" 2>/dev/null
            return 1
        fi
        if $backup_manifest; then
            if ! mv -f "$rtmp/manifest" "$manifest" 2>/dev/null; then
                rm -rf "$rtmp" 2>/dev/null
                return 1
            fi
            chmod 600 "$manifest" 2>/dev/null || true
        fi
        rm -rf "$rtmp" 2>/dev/null
        return 0
    }

    # Post-mutation failure handler: restore prior (or clean fresh install),
    # retain backup + emit its path when restoration itself fails. Always
    # increments INSTALL_WARNINGS and returns 0 (non-fatal).
    _image_gen_abort_after_mutation() {
        local label="$1"
        if ! _image_gen_restore_prev; then
            warn "image-gen: $label — restore FAILED, prior-install backup RETAINED at: $backup_dir (manual recovery needed)"
            (( INSTALL_WARNINGS++ )) || true
            return 0
        fi
        [[ -n "$backup_dir" ]] && rm -rf "$backup_dir" 2>/dev/null
        (( INSTALL_WARNINGS++ )) || true
        return 0
    }

    if ! retry 3 5 "image-gen Skill" _image_gen_npx; then
        warn "Failed to install image-gen Skill via npx (always-installed — install skipped)."
        warn "  Retry manually: DO_NOT_TRACK=1 ${_IMAGE_GEN_NPX_CMD[*]}"
        _image_gen_abort_after_mutation "npx failed"
        return 0
    fi
    ok "image-gen Skill installed (~/.claude/skills/image-gen/)"

    local wrapper="$CLAUDE_DIR/scripts/image-gen-openrouter.py"
    if [[ ! -x "$wrapper" ]]; then
        warn "image-gen wrapper not installed at $wrapper — augmentation/manifest skipped"
        _image_gen_abort_after_mutation "wrapper missing"
        return 0
    fi

    if ! image_gen_augment_skill "$CLAUDE_DIR/skills"; then
        warn "image-gen: SKILL.md augmentation failed — ownership manifest NOT written"
        _image_gen_abort_after_mutation "augmentation failed"
        return 0
    fi
    ok "image-gen: SKILL.md augmented with managed integration block"

    if ! _image_gen_write_manifest; then
        warn "image-gen: failed to write ownership manifest"
        _image_gen_abort_after_mutation "manifest write failed"
        return 0
    fi
    # Successful upgrade: the backup is no longer needed.
    [[ -n "$backup_dir" ]] && rm -rf "$backup_dir" 2>/dev/null
    ok "image-gen: ownership manifest written ($manifest)"
}

# ============================================================
# Pinned third-party skills (humanizer-zh, neat-freak, lieflat-charts,
# ResearchStudio Idea).
#
# These are NOT vendored. Each is fetched from its upstream repository at the
# revision pinned in platforms/sources.md, staged the same way the agent-guided
# recipe does (scripts/stage_lieflat.py, scripts/adapt_researchstudio.py), and
# published through scripts/managed_files.py. That records every copy in
# ~/.claude/agent-config/files.json, so ownership is content-verified (an
# existing, different or locally modified directory is preserved) and
# edit-config can take the copies over later. Records written by this script
# carry an origin starting with SCRIPT_ORIGIN_PREFIX; the script only ever
# removes copies that carry it.
# ============================================================

SCRIPT_ORIGIN_PREFIX="script-installer:"

# item|repository|revision|sparse directories (space-separated, may be empty)|target skill names
UPSTREAM_SKILL_ITEMS=(
    "humanizer-zh|https://github.com/op7418/Humanizer-zh|91f3d394db8419c20d67ebe22a96cf8fee0a404b||humanizer-zh"
    "neat-freak|https://github.com/KKKKhazix/khazix-skills|2b4a645cfdc894156ae347d897723562f719ce95|neat-freak|neat-freak"
    "lieflat-charts|https://github.com/larashero3-dotcom/lieflat-charts|eace082a317b696c5570c25826a53a7fa113e984|templates examples scripts agents|lieflat-charts"
    "researchstudio-idea|https://github.com/microsoft/ResearchStudio|0597891df1a153b8e4cbdc8c1c685f43a0a6abcf|ResearchStudio-Idea/skills/idea_spark ResearchStudio-Idea/skills/paper_search ResearchStudio-Idea/skills/scoop_check|idea_spark paper_search scoop_check"
)

# Vendored copies shipped by earlier releases of this installer (SKILL.md only).
# A directory holding exactly that one file with this digest is provably ours.
LEGACY_HUMANIZER_SHA256="a3163eb79525b9c4f12a201d5d271735f01d5593a41a616050427400982b8360"
LEGACY_HUMANIZER_ZH_SHA256="e0edbdbc9008644263d5573fb59beac95794e188fd99c35012bfd79e9ae4beeb"

# Field accessors for UPSTREAM_SKILL_ITEMS. Echo nothing for an unknown item.
upstream_skill_field() {
    local item="$1" field="$2" entry _i _u _r _s _t
    for entry in "${UPSTREAM_SKILL_ITEMS[@]}"; do
        IFS='|' read -r _i _u _r _s _t <<< "$entry"
        [[ "$_i" == "$item" ]] || continue
        case "$field" in
            url) echo "$_u" ;;
            rev) echo "$_r" ;;
            sparse) echo "$_s" ;;
            targets) echo "$_t" ;;
        esac
        return 0
    done
    return 1
}

upstream_skill_items() {
    local entry
    for entry in "${UPSTREAM_SKILL_ITEMS[@]}"; do echo "${entry%%|*}"; done
}

is_upstream_skill_selected() {
    local needle="$1" s
    for s in ${SELECTED_UPSTREAM_SKILLS[@]+"${SELECTED_UPSTREAM_SKILLS[@]}"}; do
        [[ "$s" == "$needle" ]] && return 0
    done
    return 1
}

# The Python interpreter used for the managed-file helper, or empty.
managed_python() {
    local py
    for py in python3 python; do
        if command -v "$py" &>/dev/null && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
            echo "$py"
            return 0
        fi
    done
    return 1
}

AGENT_FILES_JSON_REL="agent-config/files.json"

# 0 when agent-config/files.json records a copy at $1 (relative path) written by
# this script installer.
is_script_managed_copy() {
    local f="$CLAUDE_DIR/$AGENT_FILES_JSON_REL"
    [[ -f "$f" ]] && command -v jq &>/dev/null || return 1
    jq -e --arg t "$1" --arg p "$SCRIPT_ORIGIN_PREFIX" \
        '(.files[$t] // null) as $r | $r != null and $r.kind == "copy" and (($r.origin // "") | startswith($p))' \
        "$f" >/dev/null 2>&1
}

# 0 when agent-config/files.json records $1 but NOT as written by this script:
# the agent-guided path (edit-config) owns it, so the script leaves it alone.
is_agent_managed_elsewhere() {
    local f="$CLAUDE_DIR/$AGENT_FILES_JSON_REL"
    [[ -f "$f" ]] && command -v jq &>/dev/null || return 1
    jq -e --arg t "$1" --arg p "$SCRIPT_ORIGIN_PREFIX" \
        '(.files[$t] // null) as $r | $r != null and ((($r.origin // "") | startswith($p)) | not)' \
        "$f" >/dev/null 2>&1
}

# Remove a legacy vendored copy of skills/$1 when it is provably the unmodified
# file an earlier release of this installer shipped: the directory must hold
# exactly SKILL.md, and its digest must match $2. Anything else is preserved.
cleanup_legacy_vendored_skill() {
    local name="$1" expected="$2" dir="$CLAUDE_DIR/skills/$1" digest entries
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    is_agent_managed_elsewhere "skills/$name" && return 0
    is_script_managed_copy "skills/$name" && return 0
    entries="$(find "$dir" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$entries" != "1" || ! -f "$dir/SKILL.md" ]] \
       || ! digest="$(sha256_file "$dir/SKILL.md" 2>/dev/null)" || [[ "$digest" != "$expected" ]]; then
        info "Keeping $dir: it differs from the copy earlier releases installed (modified or your own)"
        return 0
    fi
    if $DRY_RUN; then
        info "Would remove legacy bundled skill: $name"
    elif rm -rf -- "$dir"; then
        ok "Removed legacy bundled skill: $name"
    else
        warn "Could not remove legacy bundled skill: $dir"
    fi
}

# Fetch $1 (repository URL) at revision $2 into a fresh directory $3, checking
# out only the directories in $4 (cone mode also keeps every root file).
# Blobless sparse clone first; a full clone of the same revision is the
# fallback for remotes/git versions without partial clone.
fetch_pinned_source() {
    local url="$1" rev="$2" dest="$3" sparse="$4"
    local -a dirs=()
    [[ -n "$sparse" ]] && read -r -a dirs <<< "$sparse"
    if git clone --quiet --depth=1 --filter=blob:none --no-checkout "$url" "$dest" >/dev/null 2>&1 \
       && git -C "$dest" fetch --quiet --depth=1 origin "$rev" >/dev/null 2>&1 \
       && git -C "$dest" sparse-checkout init --cone >/dev/null 2>&1 \
       && git -C "$dest" sparse-checkout set ${dirs[@]+"${dirs[@]}"} >/dev/null 2>&1 \
       && git -C "$dest" checkout --quiet --detach "$rev" >/dev/null 2>&1; then
        :
    else
        rm -rf -- "$dest"
        if ! retry 3 3 "Clone $url" bash -c 'rm -rf "$2" && git clone --quiet "$1" "$2" && git -C "$2" checkout --quiet --detach "$3"' _ "$url" "$dest" "$rev"; then
            return 1
        fi
    fi
    [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$rev" ]]
}

# Stage item $1 from checkout $2 into the fresh directory $3, producing one
# complete skill directory per target name ($3/<target>).
stage_upstream_skill() {
    local item="$1" checkout="$2" stage="$3" py
    mkdir -p "$stage" || return 1
    case "$item" in
        humanizer-zh)
            [[ -f "$checkout/SKILL.md" ]] || { error "humanizer-zh: SKILL.md missing upstream"; return 1; }
            mkdir -p "$stage/humanizer-zh" && cp "$checkout/SKILL.md" "$stage/humanizer-zh/" || return 1
            [[ -f "$checkout/LICENSE" ]] && { cp "$checkout/LICENSE" "$stage/humanizer-zh/" || return 1; }
            ;;
        neat-freak)
            [[ -f "$checkout/neat-freak/SKILL.md" ]] || { error "neat-freak: SKILL.md missing upstream"; return 1; }
            cp -R "$checkout/neat-freak" "$stage/neat-freak" || return 1
            # evals/ is upstream evaluation data, not runtime content.
            rm -rf -- "$stage/neat-freak/evals"
            if [[ ! -e "$stage/neat-freak/LICENSE" && -f "$checkout/LICENSE" ]]; then
                cp "$checkout/LICENSE" "$stage/neat-freak/LICENSE" || return 1
            fi
            ;;
        lieflat-charts)
            py="$(managed_python)" || return 1
            "$py" "$SCRIPT_DIR/scripts/stage_lieflat.py" "$checkout" "$stage/lieflat-charts" >/dev/null || return 1
            ;;
        researchstudio-idea)
            py="$(managed_python)" || return 1
            local name
            for name in idea_spark paper_search scoop_check; do
                [[ -f "$checkout/ResearchStudio-Idea/skills/$name/SKILL.md" ]] || { error "ResearchStudio: $name missing upstream"; return 1; }
                cp -R "$checkout/ResearchStudio-Idea/skills/$name" "$stage/$name" || return 1
            done
            "$py" "$SCRIPT_DIR/scripts/adapt_researchstudio.py" --stage "$stage" --agent claude --root "$CLAUDE_DIR" >/dev/null || return 1
            ;;
        *) return 1 ;;
    esac
    # Symbolic links are never deployed (managed_files.py refuses them too).
    if [[ -n "$(find "$stage" -type l 2>/dev/null | head -1)" ]]; then
        error "$item: upstream source contains symbolic links; refusing to install"
        return 1
    fi
}

# Publish $1 (staged directory) to skills/$2 through managed_files.py.
# Echoes the helper's status word; returns non-zero when the existing content
# was preserved or the helper failed.
publish_managed_skill() {
    local src="$1" name="$2" item="$3" origin="$4" py out
    py="$(managed_python)" || return 1
    if ! out="$("$py" "$SCRIPT_DIR/scripts/managed_files.py" --root "$CLAUDE_DIR" install "$src" "skills/$name" --item "$item" --origin "$origin" 2>&1)"; then
        warn "$name: ${out##*Preserved existing files: }" >&2
        return 1
    fi
    if command -v jq &>/dev/null; then
        jq -r '.status // "installed"' <<< "$out" 2>/dev/null || echo "installed"
    else
        echo "installed"
    fi
}

# Remove skills/$1 through managed_files.py when this script recorded it.
remove_script_managed_skill() {
    local name="$1" py out
    is_script_managed_copy "skills/$name" || return 0
    if $DRY_RUN; then
        info "Would remove unselected skill: $name (installer-managed copy)"
        return 0
    fi
    py="$(managed_python)" || { warn "$name: python3 unavailable — cannot verify ownership; kept"; return 0; }
    if out="$("$py" "$SCRIPT_DIR/scripts/managed_files.py" --root "$CLAUDE_DIR" remove "skills/$name" 2>&1)"; then
        ok "Removed skill: $name (backup kept under $CLAUDE_DIR/agent-config/backups/)"
    else
        warn "$name: ${out##*Preserved existing files: }"
    fi
}

# 0 when every target of $1 is an unmodified copy this script recorded from
# exactly origin $2 — the pinned revision is already installed, so the
# network fetch can be skipped.
upstream_item_current() {
    local item="$1" origin="$2" py status name f="$CLAUDE_DIR/$AGENT_FILES_JSON_REL"
    [[ -f "$f" ]] && command -v jq &>/dev/null || return 1
    py="$(managed_python)" || return 1
    status="$("$py" "$SCRIPT_DIR/scripts/managed_files.py" --root "$CLAUDE_DIR" status 2>/dev/null)" || return 1
    for name in $(upstream_skill_field "$item" targets); do
        jq -e --arg t "skills/$name" --arg o "$origin" '(.files[$t].origin // "") == $o' "$f" >/dev/null 2>&1 || return 1
        jq -e --arg t "skills/$name" '[.files[] | select(.target == $t and .matches)] | length == 1' <<< "$status" >/dev/null 2>&1 || return 1
    done
}

announce_lieflat_license() {
    warn "lieflat-charts is licensed under PolyForm Noncommercial 1.0.0 — noncommercial use only."
    warn "  https://github.com/larashero3-dotcom/lieflat-charts/blob/$(upstream_skill_field lieflat-charts rev)/LICENSE"
}

# Install one pinned upstream item. Optional add-on: failures are reported and
# counted as non-critical warnings, never fatal.
install_upstream_skill_item() {
    local item="$1" url rev sparse targets name
    url="$(upstream_skill_field "$item" url)" || return 1
    rev="$(upstream_skill_field "$item" rev)"
    sparse="$(upstream_skill_field "$item" sparse)"
    targets="$(upstream_skill_field "$item" targets)"
    local origin="${SCRIPT_ORIGIN_PREFIX}${url}@${rev}"

    info "Installing $item from ${url#https://} @ ${rev:0:12}..."
    [[ "$item" == "lieflat-charts" ]] && announce_lieflat_license
    [[ "$item" == "humanizer-zh" ]] && cleanup_legacy_vendored_skill humanizer-zh "$LEGACY_HUMANIZER_ZH_SHA256"

    local -a names=()
    read -r -a names <<< "$targets"
    for name in "${names[@]}"; do
        if is_agent_managed_elsewhere "skills/$name"; then
            info "$name is managed by edit-config (agent-config/files.json) — leaving it to that path"
            return 0
        fi
    done

    if upstream_item_current "$item" "$origin"; then
        ok "$item already at ${rev:0:12} (unmodified) — nothing to fetch"
        return 0
    fi

    if $DRY_RUN; then
        info "Would fetch $url @ $rev${sparse:+ (sparse: $sparse)}"
        for name in "${names[@]}"; do
            info "Would install skill: $name -> $CLAUDE_DIR/skills/$name/ (recorded in $AGENT_FILES_JSON_REL)"
        done
        return 0
    fi

    if ! command -v git &>/dev/null; then
        warn "$item: git not found — skipped (optional)"
        (( INSTALL_WARNINGS++ )) || true
        return 1
    fi
    if ! managed_python >/dev/null; then
        warn "$item: python3 (3.8+) not found — skipped (optional; needed for staging and ownership records)"
        (( INSTALL_WARNINGS++ )) || true
        return 1
    fi

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/accc-${item}.XXXXXX")" || { warn "$item: cannot create a temporary directory"; (( INSTALL_WARNINGS++ )) || true; return 1; }
    if ! fetch_pinned_source "$url" "$rev" "$work/src" "$sparse"; then
        warn "$item: could not fetch $url @ $rev — check network/proxy and re-run"
        (( INSTALL_WARNINGS++ )) || true
        rm -rf -- "$work"
        return 1
    fi
    if ! stage_upstream_skill "$item" "$work/src" "$work/stage"; then
        warn "$item: staging failed (upstream layout changed?) — nothing was installed"
        (( INSTALL_WARNINGS++ )) || true
        rm -rf -- "$work"
        return 1
    fi

    local status failed=false
    for name in "${names[@]}"; do
        if status="$(publish_managed_skill "$work/stage/$name" "$name" "$item" "$origin")"; then
            case "$status" in
                provided-externally) info "$name: identical copy already present (not taken over)" ;;
                already-managed)     ok "$name already up to date" ;;
                *)                   ok "Skill installed: $name ($item @ ${rev:0:12})" ;;
            esac
        else
            failed=true
            warn "  Move $CLAUDE_DIR/skills/$name aside (or remove it) and re-run to install the pinned copy."
        fi
    done
    rm -rf -- "$work"
    if $failed; then
        (( INSTALL_WARNINGS++ )) || true
        return 1
    fi
    if [[ "$item" == "researchstudio-idea" ]]; then
        info "ResearchStudio: runtime dependencies/API keys are set up on first use (see each SKILL.md)."
    fi
}

# Install the selected pinned items and migrate legacy copies. In an
# interactive run (a full selection), previously installed items that were
# deselected are removed — only copies this script recorded, unmodified.
install_upstream_skills() {
    # Legacy bundled humanizer: replaced by the humanizer@humanizer plugin.
    # Removed when humanizer is selected this run, or when a full selection
    # deselected it (matching the old unselected-skill cleanup).
    local humanizer_selected=false p
    for p in ${SELECTED_PLUGINS[@]+"${SELECTED_PLUGINS[@]}"}; do
        [[ "$p" == "humanizer@humanizer" ]] && humanizer_selected=true
    done
    if [[ ${#PLUGIN_GROUPS[@]} -gt 0 ]] && $INSTALL_PLUGINS; then
        humanizer_selected=true   # essential / all both include it
    fi
    if $humanizer_selected || $FULL_SELECTION; then
        cleanup_legacy_vendored_skill humanizer "$LEGACY_HUMANIZER_SHA256"
    fi

    local item name
    while IFS= read -r item; do
        if is_upstream_skill_selected "$item"; then
            install_upstream_skill_item "$item" || true
        elif $FULL_SELECTION; then
            [[ "$item" == "humanizer-zh" ]] && cleanup_legacy_vendored_skill humanizer-zh "$LEGACY_HUMANIZER_ZH_SHA256"
            for name in $(upstream_skill_field "$item" targets); do
                remove_script_managed_skill "$name"
            done
        fi
    done < <(upstream_skill_items)
}

install_deepxiv() {
    local repo_url="https://github.com/DeepXiv/deepxiv_sdk"
    info "Installing DeepXiv skills from github.com/DeepXiv/deepxiv_sdk..."
    $DRY_RUN || mkdir -p "$CLAUDE_DIR/skills"

    # Pre-flight: git must be available
    if ! command -v git &>/dev/null; then
        error "git is required to install DeepXiv skills but was not found. Please install git first."
        return 1
    fi

    # Use local copy; default to known list when nothing selected (--all mode)
    local -a skills_to_install=("${SELECTED_DEEPXIV_SKILLS[@]}")
    if [[ ${#skills_to_install[@]} -eq 0 ]]; then
        skills_to_install=("${DEEPXIV_KNOWN_SKILLS[@]}")
    fi

    # Dry-run: report only, NO filesystem writes (no mktemp, no clone, no copy).
    if $DRY_RUN; then
        info "Would clone $repo_url (shallow) to a temporary directory"
        for skill in "${skills_to_install[@]}"; do
            info "Would install DeepXiv skill: $skill -> $CLAUDE_DIR/skills/$skill/"
        done
        return 0
    fi

    # Non-dry-run: create the temp dir now and clone into it.
    local deepxiv_tmp
    deepxiv_tmp="$(mktemp -d "${TMPDIR:-/tmp}/deepxiv_sdk.XXXXXX")" || { error "Failed to create temporary directory"; return 1; }

    # Clone the deepxiv_sdk repo (shallow clone for speed)
    local clone_ok=false
    if retry 3 3 "Clone deepxiv_sdk" git clone --depth 1 "$repo_url" "$deepxiv_tmp/deepxiv_sdk"; then
        clone_ok=true
        ok "DeepXiv SDK repo cloned (latest)"
    else
        error "Failed to clone deepxiv_sdk repo. Check network/proxy and try again."
        (( INSTALL_WARNINGS++ )) || true
        rm -rf "$deepxiv_tmp"
        return 1
    fi

    if $clone_ok && ! $DRY_RUN; then
        local src_skills="$deepxiv_tmp/deepxiv_sdk/skills"
        if [[ ! -d "$src_skills" ]]; then
            error "deepxiv_sdk/skills directory not found in cloned repo"
            (( INSTALL_WARNINGS++ )) || true
            rm -rf "$deepxiv_tmp"
            return 1
        fi

        for skill in "${skills_to_install[@]}"; do
            local skill_src="$src_skills/$skill"
            if [[ -d "$skill_src" ]]; then
                rm -rf "$CLAUDE_DIR/skills/$skill"
                cp -r "$skill_src" "$CLAUDE_DIR/skills/$skill"
                ok "DeepXiv skill installed: $skill"
            else
                warn "DeepXiv skill not found in repo: $skill"
                (( INSTALL_WARNINGS++ )) || true
            fi
        done
    elif $DRY_RUN; then
        for skill in "${skills_to_install[@]}"; do
            info "Would install DeepXiv skill: $skill -> $CLAUDE_DIR/skills/$skill/"
        done
    fi

    # Clean up
    rm -rf "$deepxiv_tmp"
}

install_lessons() {
    info "Installing lessons.md template..."
    local target="$CLAUDE_DIR/lessons.md"

    if [[ -f "$target" ]]; then
        warn "lessons.md already exists -- skipping"
    else
        if $DRY_RUN; then
            info "Would copy: lessons.md -> $target"
        else
            cp "$CLAUDE_TEMPLATES_DIR/lessons.md" "$target"
            ok "lessons.md template installed to $target"
        fi
    fi
}

install_statusline() {
    info "Installing StatusLine..."
    $DRY_RUN || mkdir -p "$CLAUDE_DIR/hooks"

    local hook_file="$CLAUDE_TEMPLATES_DIR/hooks/statusline.sh"
    if [[ -f "$hook_file" ]]; then
        if $DRY_RUN; then
            info "Would copy: hooks/statusline.sh -> $CLAUDE_DIR/hooks/statusline.sh"
        else
            cp "$hook_file" "$CLAUDE_DIR/hooks/statusline.sh"
            chmod +x "$CLAUDE_DIR/hooks/statusline.sh"
            ok "Hook installed: statusline.sh"
        fi
    fi

    # Ensure jq is available (required by statusline hook)
    install_jq || true

    # Install Nerd Font for statusline icons
    install_nerd_font || true
}

install_mcp() {
    info "Installing MCP servers..."

    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found. Install it first: https://claude.com/claude-code"
        return 1
    fi

    # Helper: check if an MCP server already exists
    _mcp_exists() {
        claude mcp list 2>/dev/null | grep -q "^${1}:" 2>/dev/null
    }

    # Lark MCP — opt-in only (default off). Prompt for credentials in
    # interactive mode, skip in non-interactive. Not installed unless the user
    # explicitly selected the "Lark/Feishu MCP" item (or passed --all).
    if ! $INSTALL_LARK; then
        :  # Lark not selected — skip entirely
    elif $DRY_RUN; then
        info "Would add MCP server: lark-mcp (stdio)"
    else
        if _mcp_exists lark-mcp; then
            ok "MCP server lark-mcp already exists, skipping"
        elif ! can_interact; then
            warn "Skipping lark-mcp (requires interactive credential input)"
            warn "  Run interactively to set up, or add manually:"
            warn "  claude mcp add --scope user --transport stdio lark-mcp -- npx -y @larksuiteoapi/lark-mcp mcp -a <APP_ID> -s <APP_SECRET> -t $LARK_MCP_PRESET"
        else
            echo ""
            info "Lark MCP requires Feishu App credentials:"
            info "  Get them from: https://open.feishu.cn/app"
            local lark_app_id="" lark_app_secret=""
            echo -n "  App ID: " > /dev/tty
            read -r lark_app_id </dev/tty
            echo -n "  App Secret: " > /dev/tty
            read -r lark_app_secret </dev/tty
            if [[ -z "$lark_app_id" || -z "$lark_app_secret" ]]; then
                warn "Empty credentials — skipping lark-mcp (add manually later)"
            elif retry 3 3 "Add MCP server lark-mcp" claude mcp add --scope user --transport stdio lark-mcp \
                -- npx -y @larksuiteoapi/lark-mcp mcp -a "$lark_app_id" -s "$lark_app_secret" -t "$LARK_MCP_PRESET" 2>/dev/null; then
                ok "MCP server added: lark-mcp"
            else
                warn "MCP server lark-mcp could not be added, skipping"
            fi
        fi
    fi

    # Playwright MCP
    if ! $INSTALL_MCP; then
        :  # Playwright not selected — skip entirely
    elif $DRY_RUN; then
        info "Would add MCP server: playwright (stdio)"
    else
        if _mcp_exists playwright; then
            ok "MCP server playwright already exists, skipping"
        elif retry 3 3 "Add MCP server playwright" claude mcp add --scope user --transport stdio playwright \
            -- npx @playwright/mcp@latest 2>/dev/null; then
            ok "MCP server added: playwright"
        else
            warn "MCP server playwright could not be added, skipping"
        fi
    fi
}

# --- Pure plugin-resolution helpers (no side effects, unit-tested) ---------
#
# These functions contain the decision logic for the installer's plugin
# reconciliation. They never call the `claude` CLI and never touch the
# filesystem, so they are exercised directly by tests/test_plugin_resolution.sh.

# build_plugin_catalogue: echo the union of every installer-managed plugin
# group (newline-separated, deduplicated). This is the set the installer
# "owns". It only carries a preserve-it meaning under
# PLUGIN_PRUNE_SCOPE=catalogue (the default); under scope=all, plugins outside
# the catalogue are reconciled just like the ones inside it.
build_plugin_catalogue() {
    local all=(
        "${PLUGINS_ESSENTIAL[@]}"
        "${PLUGINS_OPTIONAL[@]}"
        "${PLUGINS_AI_RESEARCH[@]}"
        "${PLUGINS_REVIEW[@]}"
    )
    local seen="" entry
    for entry in "${all[@]}"; do
        if [[ "$seen" != *"|$entry|"* ]]; then
            printf '%s\n' "$entry"
            seen="$seen|$entry|"
        fi
    done
}

# compute_plugins_to_prune: pure decision logic. Reads three globals (set by
# the caller's real flow, or by tests as fixtures):
#   CATALOGUE_PLUGINS  - the installer-managed plugin catalogue
#   RESOLVED_PLUGINS   - plugins selected for THIS run
#   INSTALLED_PLUGINS  - plugins currently installed (from installed_plugins.json)
# Also reads PLUGIN_PRUNE_SCOPE. Echoes (newline-separated) the installed keys
# that should be UNINSTALLED: everything installed but not selected this run
# (rule 1). Under scope=catalogue the old rule 4 applies and plugins outside the
# catalogue are preserved; under scope=all (--prune-foreign-plugins) there is no such
# exemption. Selected plugins are reinstalled elsewhere, not pruned (rule 2).
# bash 3.2 compatible: pipe-delimited "set" strings, no assoc arrays.
compute_plugins_to_prune() {
    local catalogue_set="" selected_set="" entry
    # Under scope=all an empty selection means "prune nothing", never "prune
    # everything" — the same safety valve prune_unlisted_plugins() enforces,
    # repeated here so the invariant survives any future caller that forgets to
    # guard. Under the default catalogue scope an empty selection is a real
    # answer (the user unchecked every plugin item) and is bounded by the
    # catalogue, so it prunes the installer-owned plugins only.
    if [[ ${#RESOLVED_PLUGINS[@]} -eq 0 && "$PLUGIN_PRUNE_SCOPE" == "all" ]]; then
        return 0
    fi
    if [[ ${#CATALOGUE_PLUGINS[@]} -gt 0 ]]; then
        for entry in "${CATALOGUE_PLUGINS[@]}"; do
            catalogue_set="$catalogue_set|$entry|"
        done
    fi
    if [[ ${#RESOLVED_PLUGINS[@]} -gt 0 ]]; then
        for entry in "${RESOLVED_PLUGINS[@]}"; do
            selected_set="$selected_set|$entry|"
        done
    fi
    [[ ${#INSTALLED_PLUGINS[@]} -gt 0 ]] || return 0
    for entry in "${INSTALLED_PLUGINS[@]}"; do
        [[ -n "$entry" ]] || continue
        # Never touch local skills-dir pseudo-plugins. `claude plugin init`
        # scaffolds them under ~/.claude/skills/<name>/ and they auto-load as
        # <name>@skills-dir; they belong to no marketplace, so
        # `claude plugin uninstall` has nothing to act on. Hard exemption under
        # every scope.
        [[ "$entry" == *"@skills-dir" ]] && continue
        # Rule 4 (scope=catalogue only): preserve plugins outside our catalogue.
        # Under scope=all there is no exemption — not selected means uninstall.
        if [[ "$PLUGIN_PRUNE_SCOPE" != "all" ]]; then
            [[ "$catalogue_set" == *"|$entry|"* ]] || continue
        fi
        # Rule 2: selected this run -> reinstalled (update), not pruned.
        [[ "$selected_set" == *"|$entry|"* ]] && continue
        # Rule 1: installed, not selected -> prune.
        printf '%s\n' "$entry"
    done
}

# plugin_is_installed <name@marketplace>: 0 if the key is present in the
# installed_plugins.json state file, 1 otherwise (or if jq/the file is missing).
plugin_is_installed() {
    local pkg="$1"
    local list_json="$HOME/.claude/plugins/installed_plugins.json"
    [[ -f "$list_json" ]] || return 1
    command -v jq &>/dev/null || return 1
    jq -e --arg k "$pkg" '.plugins | has($k)' "$list_json" >/dev/null 2>&1
}

# read_installed_plugin_keys: echo every installed plugin's name@marketplace,
# one per line. Empty output is ambiguous — it means either "nothing installed"
# or "jq/the state file is missing" — so callers that act destructively on the
# result must guard those two cases themselves first (see prune_unlisted_plugins).
read_installed_plugin_keys() {
    local list_json="$HOME/.claude/plugins/installed_plugins.json"
    [[ -f "$list_json" ]] || return 0
    command -v jq &>/dev/null || return 0
    jq -r '.plugins | keys[]' "$list_json" 2>/dev/null
}

# 0 if the marketplace cache dir holds a usable catalog. A bare `.git` is not
# enough: `git clone` creates it within the first moments, so an interrupted
# clone leaves one behind. The manifest only lands once the checkout completes.
marketplace_dir_is_valid() {
    local dir="$1"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    [[ -f "$dir/.claude-plugin/marketplace.json" ]]
}

# read_local_marketplaces: echo the name of every locally configured
# marketplace whose catalog is complete, one per line. temp_<epoch> dirs are the
# CLI's in-flight scratch clones, not catalogs — same filter update_installed_plugins() uses.
read_local_marketplaces() {
    local root="$HOME/.claude/plugins/marketplaces" path name
    [[ -d "$root" ]] || return 0
    for path in "$root"/*; do
        [[ -d "$path" ]] || continue
        name="$(basename "$path")"
        [[ "$name" == temp_* ]] && continue
        marketplace_dir_is_valid "$path" || continue
        printf '%s\n' "$name"
    done
}

# compute_marketplaces_to_remove: pure decision logic. Reads three globals:
#   LOCAL_MARKETPLACES - marketplace names present on disk
#   SURVIVING_PLUGINS  - plugins still installed after pruning (name@marketplace)
#   PLUGIN_PRUNE_SCOPE - under "catalogue" (default) only marketplaces that
#                        catalogue plugins come from are candidates; a
#                        marketplace the user added by hand is never removed
# Echoes the marketplaces that exist locally but that no surviving plugin needs.
# The "needed" set must come from the survivors, NOT from this run's selection:
# under the default catalogue scope a hand-installed plugin is deliberately kept while
# never appearing in RESOLVED_PLUGINS, and a `claude plugin uninstall` that fails
# also leaves a plugin behind that the selection does not name. Judging by the
# selection would delete those plugins' marketplaces out from under them.
# bash 3.2 compatible: pipe-delimited "set" strings, no assoc arrays.
compute_marketplaces_to_remove() {
    local needed="" entry name
    # Under scope=all an empty survivor set means "remove nothing", never
    # "remove every marketplace". Same safety valve as compute_plugins_to_prune().
    # Under the catalogue scope only installer-owned marketplaces are candidates,
    # so an empty survivor set is safe to act on.
    if [[ ${#SURVIVING_PLUGINS[@]} -eq 0 && "$PLUGIN_PRUNE_SCOPE" == "all" ]]; then
        return 0
    fi
    for entry in ${SURVIVING_PLUGINS[@]+"${SURVIVING_PLUGINS[@]}"}; do
        needed="$needed|${entry##*@}|"
    done
    for entry in "${PROTECTED_MARKETPLACES[@]}"; do
        needed="$needed|$entry|"
    done
    [[ ${#LOCAL_MARKETPLACES[@]} -gt 0 ]] || return 0
    local owned=""
    if [[ "$PLUGIN_PRUNE_SCOPE" != "all" ]]; then
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && owned="$owned|${entry##*@}|"
        done < <(build_plugin_catalogue)
    fi
    for name in "${LOCAL_MARKETPLACES[@]}"; do
        [[ -n "$name" ]] || continue
        [[ "$needed" == *"|$name|"* ]] && continue
        if [[ "$PLUGIN_PRUNE_SCOPE" != "all" && "$owned" != *"|$name|"* ]]; then
            continue
        fi
        printf '%s\n' "$name"
    done
}

# resolve_plugin_selection: set RESOLVED_PLUGINS to this run's deduplicated
# plugin selection (SELECTED_PLUGINS plus PLUGIN_GROUPS expansion). Runs before
# the plugin step and independently of it, so reconciliation always judges
# against the real selection — even when install_plugins() bails out early
# (no git) or was not needed (every plugin item unchecked).
resolve_plugin_selection() {
    local plugins=() group entry seen=""
    if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
        plugins+=("${SELECTED_PLUGINS[@]}")
    fi
    for group in ${PLUGIN_GROUPS[@]+"${PLUGIN_GROUPS[@]}"}; do
        case "$group" in
            essential|core) plugins+=("${PLUGINS_ESSENTIAL[@]}") ;;
            ai-research)    plugins+=("${PLUGINS_AI_RESEARCH[@]}") ;;
            all)            plugins+=("${PLUGINS_ESSENTIAL[@]}" "${PLUGINS_OPTIONAL[@]}" "${PLUGINS_AI_RESEARCH[@]}") ;;
        esac
    done
    RESOLVED_PLUGINS=()
    for entry in ${plugins[@]+"${plugins[@]}"}; do
        [[ "$seen" == *"|$entry|"* ]] && continue
        RESOLVED_PLUGINS+=("$entry")
        seen="$seen|$entry|"
    done
}

# 0 when this run reconciles installed plugins against its selection
# (uninstalls unselected installer-owned plugins, drops their marketplaces and
# enabledPlugins entries). Only a complete interactive selection does; --all,
# --only and the non-interactive default run are additive. An explicit
# --prune-foreign-plugins keeps its documented meaning on non --only runs.
plugin_reconcile_enabled() {
    $FULL_SELECTION && return 0
    ! $ONLY_MODE && $INSTALL_PLUGINS && [[ "$PLUGIN_PRUNE_SCOPE" == "all" ]]
}

install_plugins() {
    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found. Install it first: https://claude.com/claude-code"
        return 1
    fi

    resolve_plugin_selection

    if ! command -v git &>/dev/null; then
        warn "git not found — skipping plugin installation (marketplaces are git clones)"
        return 0
    fi

    # Collect plugins from both SELECTED_PLUGINS and group-based collection
    local plugins=()
    # Add individually selected plugins (interactive mode / review selections)
    if [[ ${#SELECTED_PLUGINS[@]} -gt 0 ]]; then
        plugins+=("${SELECTED_PLUGINS[@]}")
    fi
    # Add group-based plugins (--all mode)
    if [[ ${#PLUGIN_GROUPS[@]} -gt 0 ]]; then
        for group in "${PLUGIN_GROUPS[@]}"; do
            case "$group" in
                essential|core)
                    plugins+=("${PLUGINS_ESSENTIAL[@]}")
                    ;;
                # No "optional" branch: PLUGIN_GROUPS only ever holds "all" or
                # "essential" (see parse_args). PLUGINS_OPTIONAL (e.g. ecc@ecc) is
                # surfaced via SELECTED_PLUGINS or the "all" group, never as an
                # "optional" group token, so it can never reach this case.
                ai-research)
                    plugins+=("${PLUGINS_AI_RESEARCH[@]}")
                    ;;
                all)
                    plugins+=("${PLUGINS_ESSENTIAL[@]}" "${PLUGINS_OPTIONAL[@]}" "${PLUGINS_AI_RESEARCH[@]}")
                    ;;
            esac
        done
    fi

    # Deduplicate
    local unique_plugins=()
    local seen=""
    for entry in "${plugins[@]}"; do
        if [[ "$seen" != *"|$entry|"* ]]; then
            unique_plugins+=("$entry")
            seen="$seen|$entry|"
        fi
    done
    plugins=("${unique_plugins[@]}")

    # The upstream humanizer plugin needs Claude Code >= 2.1.142.
    if [[ "$seen" == *"|humanizer@humanizer|"* ]] && ! claude_version_at_least 2 1 142; then
        warn "humanizer@humanizer needs Claude Code >= 2.1.142 ($(claude --version 2>/dev/null | head -1 || echo unknown) found) — update Claude Code if /humanizer:humanizer does not load"
    fi

    # RESOLVED_PLUGINS (set by resolve_plugin_selection above) is the same
    # deduped list; prune_unlisted_plugins() reconciles against it.

    # Collect required marketplaces from selected plugins
    local marketplace_list=(
        "anthropic-agent-skills|anthropics/skills"
        "ecc|affaan-m/everything-claude-code"
        "ai-research-skills|Orchestra-Research/AI-research-SKILLs"
        "humanizer|blader/humanizer"
        "claude-plugins-official|anthropics/claude-plugins-official"
        "openai-codex|openai/codex-plugin-cc"
        "karpathy-skills|forrestchang/andrej-karpathy-skills"
        "frontend-slides|zarazhangrui/frontend-slides"
        "ppt-master|hugohe3/ppt-master"
    )

    # Build set of needed marketplaces (bash 3.2 compatible, no associative arrays)
    local needed_marketplaces=""
    for entry in "${plugins[@]}"; do
        local marketplace="${entry##*@}"
        needed_marketplaces="$needed_marketplaces|$marketplace|"
    done

    # Step 1: Add required marketplaces
    info "Adding marketplaces (${NET_TIMEOUT}s cap per attempt via $(timeout_backend), 2 attempts each)..."
    for entry in "${marketplace_list[@]}"; do
        local marketplace="${entry%%|*}"
        local repo="${entry##*|}"
        [[ "$needed_marketplaces" != *"|$marketplace|"* ]] && continue

        local mkt_dir="$HOME/.claude/plugins/marketplaces/$marketplace"
        if marketplace_dir_is_valid "$mkt_dir"; then
            ok "Marketplace already exists: $marketplace"
            continue
        fi

        if $DRY_RUN; then
            info "Would add marketplace: $marketplace (github.com/$repo)"
            continue
        fi

        if [[ -d "$mkt_dir" ]]; then
            warn "Marketplace $marketplace has no catalog manifest — re-adding"
            warn "If it keeps failing, remove $mkt_dir by hand and re-run."
        fi

        info "Adding marketplace: $marketplace (github.com/$repo)"
        if retry 2 3 "Add marketplace $marketplace" \
            with_timeout "$NET_TIMEOUT" claude plugin marketplace add "https://github.com/$repo"; then
            ok "Marketplace added: $marketplace"
        else
            warn "Marketplace $marketplace may already exist or could not be added"
        fi
    done

    # Step 2: Install (or reinstall) plugins.
    # Update mechanism is uninstall-then-reinstall: if a selected plugin is
    # already installed (rule 2), uninstall it first so it is reinstalled fresh
    # from the refreshed catalog. Not-yet-installed plugins are a plain install.
    info "Installing ${#plugins[@]} plugins..."
    for entry in "${plugins[@]}"; do
        local plugin_name="${entry%%@*}"
        local marketplace="${entry##*@}"
        if $DRY_RUN; then
            if plugin_is_installed "$entry"; then
                info "Would reinstall plugin (update): $plugin_name from $marketplace"
            else
                info "Would install plugin: $plugin_name from $marketplace"
            fi
        else
            # Reinstall = update: uninstall the existing copy before installing.
            if plugin_is_installed "$entry"; then
                claude plugin uninstall "$entry" 2>/dev/null || true
            fi
            info "Installing plugin: $plugin_name from $marketplace"
            if retry 2 3 "Install plugin $plugin_name" \
                with_timeout "$NET_TIMEOUT" claude plugin install "${plugin_name}@${marketplace}"; then
                ok "Plugin installed: $plugin_name"
            else
                warn "Plugin $plugin_name could not be installed, skipping"
                (( INSTALL_WARNINGS++ )) || true
            fi
        fi
    done

    # Fix execute permissions on plugin shell scripts
    # Git clone / GitHub tarballs do not preserve the execute bit, causing
    # "Permission denied" errors when Claude Code runs hook scripts.
    if ! $DRY_RUN; then
        local fixed=0
        while IFS= read -r -d '' sh_file; do
            chmod +x "$sh_file"
            (( ++fixed ))
        done < <(find "$HOME/.claude/plugins/marketplaces" -name "*.sh" -type f ! -perm -u+x -print0 2>/dev/null)
        if (( fixed > 0 )); then
            ok "Fixed execute permissions on $fixed plugin shell script(s)"
        fi
    else
        info "Would fix execute permissions on plugin shell scripts"
    fi
}

# Refresh ALL marketplace catalogs and update every installed plugin to its
# latest version. This is what makes re-running install.sh keep third-party
# plugins current — the built-in session auto-update skips community
# marketplaces, and `claude plugin install` alone reads a possibly-stale
# catalog. Runs on every invocation, independent of which components were
# selected, so a plain `./install.sh` re-run keeps plugins fresh.
# (A Claude Code restart is required for updates to take effect.)
# Uninstall plugins and remove marketplaces that were renamed/removed upstream.
# This is the UNCONDITIONAL tombstone sweep: it runs on every invocation, even
# when the plugin step is skipped entirely, so hardcoded known-dead entries
# always get cleaned. The selection-driven reconciliation is a separate thing —
# see prune_unlisted_plugins() — and only runs when plugins were selected.
prune_retired_plugins() {
    command -v claude &>/dev/null || return 0
    local list_json="$HOME/.claude/plugins/installed_plugins.json"
    local pkg mkt
    for pkg in "${RETIRED_PLUGINS[@]}"; do
        if [[ ! -f "$list_json" ]]; then
            continue  # nothing installed yet
        elif command -v jq &>/dev/null; then
            jq -e --arg k "$pkg" '.plugins | has($k)' "$list_json" >/dev/null 2>&1 || continue
        fi
        if $DRY_RUN; then
            info "Would uninstall retired plugin: $pkg"
        elif claude plugin uninstall "$pkg" 2>/dev/null; then
            ok "Removed retired plugin: $pkg"
        else
            warn "Could not uninstall retired plugin: $pkg (may already be gone)"
        fi
    done
    for mkt in "${RETIRED_MARKETPLACES[@]}"; do
        [[ -d "$HOME/.claude/plugins/marketplaces/$mkt" ]] || continue
        if $DRY_RUN; then
            info "Would remove retired marketplace: $mkt"
        elif claude plugin marketplace remove "$mkt" 2>/dev/null; then
            ok "Removed retired marketplace: $mkt"
        else
            warn "Could not remove retired marketplace: $mkt"
        fi
    done
    prune_retired_github_mcp
}

# Remove the retired user-scope GitHub MCP server that very early releases
# registered. Only an entry that is still named "github" AND still points at
# RETIRED_GITHUB_MCP_URL is ours; any other "github" server is the user's.
prune_retired_github_mcp() {
    command -v claude &>/dev/null || return 0
    command -v jq &>/dev/null || return 0
    # User-scope MCP servers live in ~/.claude.json; reading it avoids
    # `claude mcp list`, which health-checks every configured server.
    local cfg="$HOME/.claude.json"
    [[ -f "$cfg" ]] || return 0
    jq -e --arg u "$RETIRED_GITHUB_MCP_URL" \
        '(.mcpServers.github.url // "") as $x | ($x == $u or $x == ($u | rtrimstr("/")))' \
        "$cfg" >/dev/null 2>&1 || return 0
    if $DRY_RUN; then
        info "Would remove retired MCP server: github ($RETIRED_GITHUB_MCP_URL)"
    elif claude mcp remove github --scope user >/dev/null 2>&1; then
        ok "Removed retired MCP server: github"
    else
        warn "Could not remove retired MCP server: github (remove it with: claude mcp remove github --scope user)"
    fi
}

# Reconcile installed plugins against this run's selection: uninstall every
# installed plugin that was NOT selected (rule 1). Under the default
# PLUGIN_PRUNE_SCOPE=catalogue only installer-managed plugins are considered;
# --prune-foreign-plugins widens it to plugins the user installed by hand.
# Reads the installed keys from installed_plugins.json, computes the prune set
# via the pure compute_plugins_to_prune(), and uninstalls each. Must run AFTER
# install_plugins() so RESOLVED_PLUGINS reflects this run's selection.
# Respects DRY_RUN.
prune_unlisted_plugins() {
    command -v claude &>/dev/null || return
    # Reset on every entry: an early return below must not leave a stale prune
    # list behind for prune_unlisted_marketplaces() to subtract.
    PRUNED_PLUGINS=()
    # Deliberate semantic boundary: an empty resolved set means "uninstall
    # NOTHING", never "uninstall everything". If the plugin step ran but ended
    # with zero selected plugins (user deselected them all), a full-scope
    # reconcile would otherwise wipe every installed plugin on the machine off
    # the back of an empty set. Losing the ability to deselect-all-to-remove-all
    # is the cheaper failure; do not "fix" this by removing the guard. The
    # $INSTALL_PLUGINS gate in main() does not cover this case.
    # Under the default catalogue scope the prune set is bounded by the
    # catalogue, so an empty selection (every plugin item unchecked in the
    # interactive selector) does uninstall the installer-owned plugins.
    if [[ ${#RESOLVED_PLUGINS[@]} -eq 0 && "$PLUGIN_PRUNE_SCOPE" == "all" ]]; then
        return
    fi
    local list_json="$HOME/.claude/plugins/installed_plugins.json"

    if ! command -v jq &>/dev/null || [[ ! -f "$list_json" ]]; then
        warn "jq or installed_plugins.json unavailable — skipping plugin reconciliation"
        return
    fi
    if ! jq empty "$list_json" 2>/dev/null; then
        warn "installed_plugins.json is not valid JSON — skipping plugin reconciliation"
        return
    fi

    # Populate the fixture globals that compute_plugins_to_prune() reads.
    INSTALLED_PLUGINS=()
    local key
    while IFS= read -r key; do
        [[ -n "$key" ]] && INSTALLED_PLUGINS+=("$key")
    done < <(read_installed_plugin_keys)

    CATALOGUE_PLUGINS=()
    while IFS= read -r key; do
        [[ -n "$key" ]] && CATALOGUE_PLUGINS+=("$key")
    done < <(build_plugin_catalogue)
    # RESOLVED_PLUGINS is set by install_plugins() (selected this run).

    local pkg prune_list=() kept=0
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && prune_list+=("$pkg")
    done < <(compute_plugins_to_prune)

    kept=$(( ${#INSTALLED_PLUGINS[@]} - ${#prune_list[@]} ))
    if [[ ${#prune_list[@]} -gt 0 ]]; then
        PRUNED_PLUGINS=("${prune_list[@]}")
    fi

    if [[ ${#prune_list[@]} -eq 0 ]]; then
        ok "Plugins already match your selection — nothing to uninstall ($kept kept)"
        return
    fi

    warn "Reconciling plugins: ${#prune_list[@]} installed plugin(s) are not in this run's selection and will be UNINSTALLED"
    for pkg in "${prune_list[@]}"; do
        if $DRY_RUN; then
            info "Would uninstall: $pkg"
        elif claude plugin uninstall --scope user "$pkg" 2>/dev/null; then
            ok "Uninstalled (not selected): $pkg"
        else
            warn "Could not uninstall: $pkg (may already be gone)"
            (( INSTALL_WARNINGS++ )) || true
        fi
    done
    info "Kept $kept selected plugin(s)"
}

# Remove marketplaces that no plugin selected this run needs any more. Must run
# AFTER prune_unlisted_plugins(): only once the plugin set has settled does
# "does anything still need this marketplace?" have a definite answer. Must run
# BEFORE update_installed_plugins(), which would otherwise spend NET_TIMEOUT
# refreshing a catalog that is about to be deleted. Respects DRY_RUN.
prune_unlisted_marketplaces() {
    command -v claude &>/dev/null || return
    # Same empty-selection safety valve as prune_unlisted_plugins().
    if [[ ${#RESOLVED_PLUGINS[@]} -eq 0 && "$PLUGIN_PRUNE_SCOPE" == "all" ]]; then
        return
    fi

    local list_json="$HOME/.claude/plugins/installed_plugins.json"
    if ! command -v jq &>/dev/null || [[ ! -f "$list_json" ]]; then
        warn "jq or installed_plugins.json unavailable — skipping marketplace reconciliation"
        return
    fi
    if ! jq empty "$list_json" 2>/dev/null; then
        warn "installed_plugins.json is not valid JSON — skipping marketplace reconciliation"
        return
    fi

    # Re-read the state file instead of reusing RESOLVED_PLUGINS: only the file
    # knows which plugins actually survived pruning (kept foreign plugins, failed
    # uninstalls), and those still need their marketplaces. See
    # compute_marketplaces_to_remove().
    SURVIVING_PLUGINS=()
    local key
    while IFS= read -r key; do
        [[ -n "$key" ]] && SURVIVING_PLUGINS+=("$key")
    done < <(read_installed_plugin_keys)

    # A dry run uninstalled nothing, so the file still lists the plugins a real
    # run would have removed. Subtract them so the preview matches what execution
    # would actually do.
    if $DRY_RUN && [[ ${#PRUNED_PLUGINS[@]} -gt 0 ]] && [[ ${#SURVIVING_PLUGINS[@]} -gt 0 ]]; then
        local pruned_set="" survivors=()
        for key in "${PRUNED_PLUGINS[@]}"; do
            pruned_set="$pruned_set|$key|"
        done
        for key in "${SURVIVING_PLUGINS[@]}"; do
            [[ "$pruned_set" == *"|$key|"* ]] && continue
            survivors+=("$key")
        done
        SURVIVING_PLUGINS=()
        if [[ ${#survivors[@]} -gt 0 ]]; then
            SURVIVING_PLUGINS=("${survivors[@]}")
        fi
    fi

    LOCAL_MARKETPLACES=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && LOCAL_MARKETPLACES+=("$name")
    done < <(read_local_marketplaces)

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if $DRY_RUN; then
            info "Would remove marketplace (no remaining plugin needs it): $name"
        elif claude plugin marketplace remove "$name" 2>/dev/null; then
            ok "Removed marketplace (no longer needed): $name"
        else
            warn "Could not remove marketplace: $name"
            (( INSTALL_WARNINGS++ )) || true
        fi
    done < <(compute_marketplaces_to_remove)
}

# Converge settings.json's enabledPlugins onto this run's selection by dropping
# keys that are neither selected nor installed. enabledPlugins is an
# enable/disable preference, not an install ledger, so it drifts into dead
# entries pointing at plugins that no longer exist once those are uninstalled.
# install_settings() only ever adds/flips keys it knows about, so it cannot
# clear these itself. Subtractive only: selected plugins are set true upstream.
sync_enabled_plugins_settings() {
    local settings="$CLAUDE_DIR/settings.json"
    [[ -f "$settings" ]] || return
    command -v jq &>/dev/null || return
    # Same empty-selection safety valve as prune_unlisted_plugins().
    if [[ ${#RESOLVED_PLUGINS[@]} -eq 0 && "$PLUGIN_PRUNE_SCOPE" == "all" ]]; then
        return
    fi

    local sel_json; sel_json="$(_effective_selected_plugins_json)"
    # Under the default catalogue scope, entries for plugins this installer
    # does not manage are the user's own and are kept.
    local keep_foreign=true
    [[ "$PLUGIN_PRUNE_SCOPE" == "all" ]] && keep_foreign=false
    local cat_json
    cat_json="$(build_plugin_catalogue | jq -R 'select(length > 0)' | jq -cs .)" || cat_json="[]"
    local keep_filter='($selected | reduce .[] as $p ({}; .[$p] = true)) as $sel |
        def keep($k): ($sel[$k] // false) or ($keep_foreign and (($catalogue | index($k)) == null));'
    local stale_count
    stale_count="$(jq --argjson selected "$sel_json" --argjson catalogue "$cat_json" \
        --argjson keep_foreign "$keep_foreign" "$keep_filter"'
        [(.enabledPlugins // {}) | keys[] | select(keep(.) | not)] | length
    ' "$settings" 2>/dev/null)" || return
    [[ "${stale_count:-0}" -gt 0 ]] || return

    if $DRY_RUN; then
        info "Would drop $stale_count stale enabledPlugins entr(ies) from settings.json"
        return
    fi
    local tmp
    tmp="$(mktemp "${settings}.tmp.XXXXXX")" || {
        warn "Could not create a temp file — left enabledPlugins unchanged"
        (( INSTALL_WARNINGS++ )) || true
        return
    }
    if jq --argjson selected "$sel_json" --argjson catalogue "$cat_json" \
        --argjson keep_foreign "$keep_foreign" "$keep_filter"'
        .enabledPlugins = ((.enabledPlugins // {}) | with_entries(select(keep(.key))))
    ' "$settings" > "$tmp" && jq empty "$tmp" 2>/dev/null; then
        # mktemp makes the temp file 0600; mv replaces the inode, so carry the
        # original mode over rather than silently tightening settings.json.
        chmod --reference="$settings" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$settings"
        ok "Cleaned $stale_count stale enabledPlugins entr(ies)"
    else
        rm -f "$tmp"
        warn "Could not clean enabledPlugins — left unchanged"
        (( INSTALL_WARNINGS++ )) || true
    fi
}

update_installed_plugins() {
    if ! command -v claude &>/dev/null; then
        info "claude CLI not found — skipping plugin updates"
        return
    fi

    local list_json="$HOME/.claude/plugins/installed_plugins.json"

    # SKIP the plugins this run already handled: the selected ones were just
    # reinstalled fresh by install_plugins(), and pruned ones were uninstalled
    # by prune_unlisted_plugins() (never resurrect those). Everything else that
    # is still installed — user-owned third-party plugins, and installer-owned
    # ones an additive run (--all/--only/default) left alone — is updated.
    local catalogue_set="" centry
    if $INSTALL_PLUGINS; then
        for centry in ${RESOLVED_PLUGINS[@]+"${RESOLVED_PLUGINS[@]}"}; do
            catalogue_set="$catalogue_set|$centry|"
        done
    fi
    for centry in ${PRUNED_PLUGINS[@]+"${PRUNED_PLUGINS[@]}"}; do
        catalogue_set="$catalogue_set|$centry|"
    done

    if $DRY_RUN; then
        info "Would refresh each marketplace catalog separately (${NET_TIMEOUT}s cap each)"
        if command -v jq &>/dev/null && [[ -f "$list_json" ]]; then
            local pkg
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] || continue
                [[ "$catalogue_set" == *"|$pkg|"* ]] && continue
                info "Would update plugin: $pkg"
            done < <(jq -r '.plugins | keys[]' "$list_json" 2>/dev/null)
        fi
        return
    fi

    # Refresh one catalog at a time rather than via the bare `marketplace
    # update` (which does all of them in a single opaque call). One unreachable
    # remote then costs NET_TIMEOUT seconds instead of blocking every other
    # catalog behind it, the per-marketplace name shows which one is slow, and
    # stderr is deliberately NOT sent to /dev/null so git's progress output
    # proves the step is alive instead of looking frozen.
    local mkt_root="$HOME/.claude/plugins/marketplaces"
    local mkt_path mkt_name mkt_failed=0
    info "Refreshing marketplace catalogs (official + third-party, ${NET_TIMEOUT}s cap each)..."
    if [[ -d "$mkt_root" ]]; then
        for mkt_path in "$mkt_root"/*; do
            [[ -d "$mkt_path" ]] || continue
            mkt_name="$(basename "$mkt_path")"
            # temp_<epoch> are the CLI's in-flight scratch clones, not catalogs.
            [[ "$mkt_name" == temp_* ]] && continue
            marketplace_dir_is_valid "$mkt_path" || continue
            info "Refreshing marketplace: $mkt_name"
            if retry 2 3 "Refresh marketplace $mkt_name" \
                with_timeout "$NET_TIMEOUT" claude plugin marketplace update "$mkt_name"; then
                ok "Marketplace refreshed: $mkt_name"
            else
                warn "Could not refresh marketplace: $mkt_name (skipped, using cached catalog)"
                mkt_failed=$((mkt_failed + 1))
            fi
        done
    fi
    if (( mkt_failed > 0 )); then
        warn "$mkt_failed marketplace catalog(s) could not be refreshed — plugin versions may be stale"
    fi

    if ! command -v jq &>/dev/null || [[ ! -f "$list_json" ]]; then
        warn "jq or installed_plugins.json unavailable — cannot enumerate installed plugins to update"
        return
    fi
    if ! jq empty "$list_json" 2>/dev/null; then
        warn "installed_plugins.json is not valid JSON — skipping plugin updates"
        return
    fi

    info "Updating preserved third-party plugins to latest (restart required to apply)..."
    local pkg
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        # Skip plugins already reinstalled or pruned above.
        [[ "$catalogue_set" == *"|$pkg|"* ]] && continue
        if retry 3 3 "Update plugin $pkg" with_timeout "$NET_TIMEOUT" claude plugin update "$pkg"; then
            ok "Plugin updated: ${pkg%@*}"
        else
            warn "Could not update plugin: $pkg"
        fi
    done < <(jq -r '.plugins | keys[]' "$list_json" 2>/dev/null)
}

# ============================================================
# Selection record: ~/.claude/agent-config/selection.json
#
# The agent-guided path (INSTALL.md, skills/edit-config) keeps its per-target
# selection record here. The script installer writes the same record so that
# edit-config can take over later: the repository object (url / revision /
# update policy, see INSTALL.md#repository-source), the selected catalog IDs
# and one entry per item with its status. File ownership stays in
# agent-config/files.json (managed_files.py); this file never claims it.
#
# Menu IDs that have no catalog.md row (fork-only or script-only items such
# as the model backends) are listed under script_installer.script_only.
# Records written by the agent path (items without "source": "script") are
# never removed by the script.
# ============================================================

# Map a menu ID to its catalog.md ID(s) (space-separated), or nothing for a
# script-only item. scripts/check-catalog-sync.sh verifies this table against
# catalog.md; install.ps1 carries the same table (Get-CatalogIdForMenuId).
catalog_id_for_menu_id() {
    case "$1" in
        claude-md)                   echo "instructions" ;;
        settings)                    echo "settings permissions" ;;
        rules-writing-style)         echo "rules-writing-style" ;;
        statusline)                  echo "statusline" ;;
        lessons)                     echo "lessons" ;;
        rules-python)                echo "rules-python" ;;
        rules-ts)                    echo "rules-typescript" ;;
        rules-go)                    echo "rules-golang" ;;
        review-code-review)          echo "claude-pr-review" ;;
        review-adversarial)          echo "adversarial-review" ;;
        review-codex)                echo "codex-in-claude" ;;
        plug-andrej-karpathy-skills) echo "karpathy" ;;
        plug-superpowers)            echo "superpowers" ;;
        skill-mattpocock)            echo "matt-workflow" ;;
        plug-feature-dev)            echo "feature-dev" ;;
        plug-ralph-loop)             echo "ralph-loop" ;;
        plug-commit-commands)        echo "commit-commands" ;;
        plug-code-simplifier)        echo "code-simplifier" ;;
        plug-everything-claude-code) echo "ecc" ;;
        skill-update-config)         echo "update-config" ;;
        skill-neat-freak)            echo "neat-freak" ;;
        plug-context7)               echo "context7" ;;
        plug-playwright)             echo "playwright" ;;
        plug-document-skills)        echo "documents" ;;
        plug-example-skills)         echo "examples" ;;
        skill-humanizer)             echo "humanizer" ;;
        skill-humanizer-zh)          echo "humanizer-zh" ;;
        lieflat-charts)              echo "lieflat-charts" ;;
        plug-frontend-slides)        echo "frontend-slides" ;;
        plug-ppt-master)             echo "ppt-master" ;;
        skill-storage-analyzer)      echo "storage-analyzer" ;;
        skill-paper-reading)         echo "paper-reading" ;;
        skill-cheatsheet-creator)    echo "cheatsheet-creator" ;;
        ai-research)                 echo "ai-research" ;;
        researchstudio-idea)         echo "researchstudio-idea" ;;
        deepxiv-cli|deepxiv-trending-digest|deepxiv-baseline-table) echo "$1" ;;
        mcp)                         echo "playwright-mcp" ;;
        mcp-lark)                    echo "lark" ;;
        # Script-only: search agent, shell wrapper, co-author, model backends.
        *)                           echo "" ;;
    esac
}

# Repository identity of the source this run installs from, per
# INSTALL.md#repository-source. Sets SOURCE_REPO_URL, SOURCE_REVISION and
# SOURCE_UPDATE_JSON. SOURCE_REVISION may already hold the tarball commit
# (remote mode, set by detect_script_dir).
SOURCE_REVISION="${SOURCE_REVISION:-}"
SOURCE_REPO_URL=""
SOURCE_UPDATE_JSON=""
resolve_source_identity() {
    local canonical="${REPO_URL}.git"
    if $REMOTE_MODE; then
        SOURCE_REPO_URL="$canonical"
        local version="${VERSION:-$REPO_BRANCH}"
        if [[ "$version" =~ ^v[0-9] && -n "$SOURCE_REVISION" ]]; then
            SOURCE_UPDATE_JSON="$(jq -cn --arg r "$SOURCE_REVISION" '{kind:"pinned",ref:$r}')"
        else
            SOURCE_UPDATE_JSON="$(jq -cn --arg r "$version" '{kind:"branch",ref:$r}')"
        fi
        return 0
    fi
    # Local checkout: a clean branch with a known origin tracks that branch;
    # a detached HEAD is pinned; anything else (no git, local edits) is local.
    local head="" branch="" origin="" dirty=""
    if command -v git &>/dev/null && git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null; then
        head="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)" || head=""
        branch="$(git -C "$SCRIPT_DIR" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
        origin="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)" || origin=""
        dirty="$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | head -1)"
    fi
    # Never record credentials embedded in a remote URL.
    origin="$(sed -E 's#^(https?://)[^/@]+@#\1#' <<< "$origin")"
    SOURCE_REVISION="$head"
    SOURCE_REPO_URL="${origin:-}"
    if [[ -z "$head" || -n "$dirty" || -z "$origin" ]]; then
        SOURCE_UPDATE_JSON="$(jq -cn --arg p "$SCRIPT_DIR" '{kind:"local",path:$p}')"
    elif [[ -z "$branch" ]]; then
        SOURCE_UPDATE_JSON="$(jq -cn --arg r "$head" '{kind:"pinned",ref:$r}')"
    else
        SOURCE_UPDATE_JSON="$(jq -cn --arg r "$branch" '{kind:"branch",ref:$r}')"
    fi
}

# Effective plugin selection of this run as a "|a|b|" set string.
_effective_plugin_set() {
    local json p set="|"
    json="$(_effective_selected_plugins_json)"
    while IFS= read -r p; do
        [[ -n "$p" ]] && set+="$p|"
    done < <(jq -r '.[]' <<< "$json" 2>/dev/null)
    echo "$set"
}

# Effective local-skill selection of this run as a "|a|b|" set string.
_effective_skill_set() {
    local set="|" s opt skip
    $INSTALL_SKILLS || { echo "$set"; return; }
    if [[ ${#SELECTED_SKILLS[@]} -gt 0 ]]; then
        for s in "${SELECTED_SKILLS[@]}"; do set+="$s|"; done
    else
        for s in "${SCRIPT_OWNED_SKILLS[@]}"; do
            skip=false
            for opt in "${SCRIPT_OPT_IN_SKILLS[@]}"; do [[ "$opt" == "$s" ]] && skip=true; done
            $skip || set+="$s|"
        done
    fi
    echo "$set"
}

_in_list() {
    local needle="$1" x; shift
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# 0 when menu item $1 was part of this run's effective selection. $2/$3 are
# the plugin and skill set strings.
menu_id_selected_this_run() {
    local id="$1" plugins="$2" skills="$3" pkg
    case "$id" in
        claude-md)           $INSTALL_CLAUDE_MD ;;
        settings)            $INSTALL_SETTINGS ;;
        rules-writing-style) $INSTALL_RULES && $INSTALL_WRITING_STYLE ;;
        statusline)          $INSTALL_STATUSLINE ;;
        lessons)             $INSTALL_LESSONS ;;
        agents)              $INSTALL_AGENTS ;;
        shell-wrapper)       $INSTALL_SHELL_WRAPPER ;;
        co-author)           $CO_AUTHOR ;;
        backend-glm|backend-or|backend-gpt|backend-ccr)
            $INSTALL_SHELL_WRAPPER && _in_list "${id#backend-}" ${SELECTED_PROFILES[@]+"${SELECTED_PROFILES[@]}"} ;;
        rules-python|rules-ts|rules-go)
            local lang
            case "$id" in rules-python) lang=python ;; rules-ts) lang=typescript ;; *) lang=golang ;; esac
            $INSTALL_RULES || return 1
            if [[ ${#RULE_LANGS[@]} -gt 0 ]]; then _in_list "$lang" "${RULE_LANGS[@]}"
            else ! $RULE_LANGS_EXPLICIT && ! $ONLY_MODE; fi ;;
        review-code-review)  [[ "$plugins" == *"|code-review@claude-plugins-official|"* ]] ;;
        review-codex)        [[ "$plugins" == *"|codex@openai-codex|"* ]] ;;
        review-adversarial)  [[ "$skills" == *"|adversarial-review|"* ]] ;;
        skill-humanizer)     [[ "$plugins" == *"|humanizer@humanizer|"* ]] ;;
        skill-mattpocock)    $INSTALL_MATTPOCOCK ;;
        skill-humanizer-zh)  is_upstream_skill_selected humanizer-zh ;;
        skill-neat-freak)    is_upstream_skill_selected neat-freak ;;
        lieflat-charts)      is_upstream_skill_selected lieflat-charts ;;
        researchstudio-idea) is_upstream_skill_selected researchstudio-idea ;;
        skill-*)             [[ "$skills" == *"|${id#skill-}|"* ]] ;;
        ai-research)
            for pkg in "${PLUGINS_AI_RESEARCH[@]}"; do [[ "$plugins" == *"|$pkg|"* ]] || return 1; done ;;
        deepxiv-*)
            $INSTALL_DEEPXIV || return 1
            [[ ${#SELECTED_DEEPXIV_SKILLS[@]} -eq 0 ]] || _in_list "$id" "${SELECTED_DEEPXIV_SKILLS[@]}" ;;
        mcp)                 $INSTALL_MCP ;;
        mcp-lark)            $INSTALL_LARK ;;
        plug-*)
            pkg="$(plug_id_to_pkg "$id")"
            [[ -n "$pkg" && "$plugins" == *"|$pkg|"* ]] ;;
        *) return 1 ;;
    esac
}

# Echo a JSON object describing item $1 after the run: status plus the native
# selectors / skill paths / pinned upstream revision it covers.
selection_item_json() {
    local id="$1" status="installed" pkg name
    local -a selectors=() paths=()
    case "$id" in
        claude-md)       [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] || status="failed"; paths=("CLAUDE.md") ;;
        settings)        [[ -f "$CLAUDE_DIR/settings.json" ]] || status="failed"; paths=("settings.json") ;;
        rules-writing-style) [[ -f "$CLAUDE_DIR/rules/writing-style.md" ]] || status="failed"; paths=("rules/writing-style.md") ;;
        statusline)      [[ -f "$CLAUDE_DIR/hooks/statusline.sh" ]] || status="failed"; paths=("hooks/statusline.sh") ;;
        lessons)         [[ -f "$CLAUDE_DIR/lessons.md" ]] || status="failed"; paths=("lessons.md") ;;
        rules-python)    [[ -d "$CLAUDE_DIR/rules/python" ]] || status="failed"; paths=("rules/python") ;;
        rules-ts)        [[ -d "$CLAUDE_DIR/rules/typescript" ]] || status="failed"; paths=("rules/typescript") ;;
        rules-go)        [[ -d "$CLAUDE_DIR/rules/golang" ]] || status="failed"; paths=("rules/golang") ;;
        skill-mattpocock)
            for name in "${MATTPOCOCK_SKILLS[@]}"; do
                paths+=("skills/$name")
                [[ -d "$CLAUDE_DIR/skills/$name" ]] || status="failed"
            done ;;
        skill-humanizer-zh|skill-neat-freak|lieflat-charts|researchstudio-idea)
            local item="${id#skill-}"
            for name in $(upstream_skill_field "$item" targets); do
                paths+=("skills/$name")
                [[ -d "$CLAUDE_DIR/skills/$name" ]] || status="failed"
            done ;;
        review-adversarial) [[ -d "$CLAUDE_DIR/skills/adversarial-review" ]] || status="failed"; paths=("skills/adversarial-review") ;;
        skill-humanizer)  selectors=("humanizer@humanizer") ;;
        skill-*)          [[ -d "$CLAUDE_DIR/skills/${id#skill-}" ]] || status="failed"; paths=("skills/${id#skill-}") ;;
        deepxiv-*)        [[ -d "$CLAUDE_DIR/skills/$id" ]] || status="failed"; paths=("skills/$id") ;;
        review-code-review) selectors=("code-review@claude-plugins-official") ;;
        review-codex)     selectors=("codex@openai-codex") ;;
        ai-research)      selectors=("${PLUGINS_AI_RESEARCH[@]}") ;;
        plug-*)           selectors=("$(plug_id_to_pkg "$id")") ;;
        mcp)              jq -e '.mcpServers.playwright' "$HOME/.claude.json" &>/dev/null || status="pending" ;;
        mcp-lark)         jq -e '.mcpServers["lark-mcp"]' "$HOME/.claude.json" &>/dev/null || status="pending" ;;
    esac
    if [[ ${#selectors[@]} -gt 0 ]]; then
        local ok_count=0
        for pkg in "${selectors[@]}"; do plugin_is_installed "$pkg" && ok_count=$((ok_count + 1)); done
        if (( ok_count == 0 )); then status="failed"
        elif (( ok_count < ${#selectors[@]} )); then status="partial"; fi
    fi
    local rev=""
    case "$id" in
        skill-humanizer-zh|skill-neat-freak|lieflat-charts|researchstudio-idea)
            rev="$(upstream_skill_field "${id#skill-}" rev)" ;;
    esac
    jq -cn --arg menu "$id" --arg status "$status" --arg rev "$rev" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson selectors "$(printf '%s\n' ${selectors[@]+"${selectors[@]}"} | jq -R 'select(length > 0)' | jq -cs .)" \
        --argjson paths "$(printf '%s\n' ${paths[@]+"${paths[@]}"} | jq -R 'select(length > 0)' | jq -cs .)" \
        '{source: "script", menu_id: $menu, status: $status, updated: $now}
         + (if ($selectors | length) > 0 then {selectors: $selectors} else {} end)
         + (if ($paths | length) > 0 then {paths: $paths} else {} end)
         + (if $rev != "" then {upstream_revision: $rev} else {} end)'
}

# Catalog IDs that have a row in this source's catalog.md.
_catalog_ids_in_source() {
    local catalog="$SCRIPT_DIR/catalog.md"
    [[ -f "$catalog" ]] || return 0
    sed -nE 's/^\| ([a-z0-9][a-z0-9-]*) \|.*/\1/p' "$catalog"
}

write_selection_record() {
    local dest_dir="$CLAUDE_DIR/agent-config" dest
    dest="$dest_dir/selection.json"
    if $DRY_RUN; then
        info "Would record this selection in $dest (for edit-config)"
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        warn "jq unavailable — selection record $dest not updated"
        return 0
    fi
    if [[ -L "$dest" ]]; then
        warn "Refusing to write the selection record through a symlink: $dest"
        return 0
    fi
    resolve_source_identity

    local catalog_set="|" c
    while IFS= read -r c; do [[ -n "$c" ]] && catalog_set+="$c|"; done < <(_catalog_ids_in_source)

    local plugins skills entry id _df _group cid
    plugins="$(_effective_plugin_set)"
    skills="$(_effective_skill_set)"
    local items="{}" known="[]" script_only="[]"
    while IFS='|' read -r id _df _group; do
        local cids; cids="$(catalog_id_for_menu_id "$id")"
        local in_catalog=false
        for cid in $cids; do [[ "$catalog_set" == *"|$cid|"* ]] && in_catalog=true; done
        if ! $in_catalog; then
            if menu_id_selected_this_run "$id" "$plugins" "$skills"; then
                script_only="$(jq -c --arg i "$id" '. + [$i]' <<< "$script_only")"
            fi
            continue
        fi
        local item_json=""
        menu_id_selected_this_run "$id" "$plugins" "$skills" && item_json="$(selection_item_json "$id")"
        for cid in $cids; do
            [[ "$catalog_set" == *"|$cid|"* ]] || continue
            known="$(jq -c --arg c "$cid" '. + [$c]' <<< "$known")"
            [[ -n "$item_json" ]] && items="$(jq -c --arg c "$cid" --argjson v "$item_json" '.[$c] = $v' <<< "$items")"
        done
    done < <(menu_item_ids)

    local existing="{}"
    if [[ -f "$dest" ]]; then
        if jq -e 'type == "object"' "$dest" &>/dev/null; then
            existing="$(cat "$dest")"
        else
            warn "Existing $dest is not a JSON object; keeping it as ${dest}.invalid"
            cp -f "$dest" "${dest}.invalid" 2>/dev/null || true
        fi
    fi

    local mode="default"
    if $ONLY_MODE; then mode="only"; elif $FULL_SELECTION; then mode="interactive"; elif $EXPLICIT_ALL; then mode="all"; fi

    mkdir -p "$dest_dir" && chmod 700 "$dest_dir" 2>/dev/null || true
    local tmp
    tmp="$(mktemp "$dest_dir/.selection.json.XXXXXX")" || { warn "Could not write $dest"; return 0; }
    if jq --argjson items "$items" --argjson known "$known" --argjson scriptOnly "$script_only" \
          --arg mode "$mode" --arg url "$SOURCE_REPO_URL" --arg rev "$SOURCE_REVISION" \
          --argjson update "${SOURCE_UPDATE_JSON:-null}" \
          --arg version "$(get_source_version)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        . as $old
        | ($old.items // {}) as $prev
        # A full selection drops script-written records for known items that
        # were not selected; agent-written records and --only runs keep them.
        | (if $mode == "only" then $prev
           else ($prev | with_entries(select(
                    (.key as $k | ($known | index($k)) == null)
                    or ((.value.source // "") != "script"))))
           end) as $kept
        | ($kept + $items) as $merged
        | (if ($old.repository.url? // null) != null and ($old.repository.url != ($url | select(. != "") // null))
             then {repository_previous: $old.repository} else {} end) as $prevRepo
        | $old + $prevRepo + {
            agent: "claude",
            client: "claude-code",
            repository: {
                url: (if $url == "" then null else $url end),
                revision: (if $rev == "" then null else $rev end),
                update: $update
            },
            selected: ($merged | keys),
            items: $merged,
            script_installer: {
                name: "install.sh",
                version: $version,
                mode: $mode,
                updated: $now,
                script_only: (if $mode == "only"
                              then ((($old.script_installer.script_only // []) + $scriptOnly) | unique)
                              else $scriptOnly end)
            }
          }' <<< "$existing" > "$tmp" && jq empty "$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$dest"
        ok "Selection recorded for edit-config: $dest"
    else
        rm -f "$tmp"
        warn "Could not update the selection record $dest"
    fi
}

# --uninstall: drop the records this script wrote; agent-written ones stay.
clear_script_selection_records() {
    local dest="$CLAUDE_DIR/agent-config/selection.json" tmp
    [[ -f "$dest" && ! -L "$dest" ]] || return 0
    command -v jq &>/dev/null || return 0
    tmp="$(mktemp "$CLAUDE_DIR/agent-config/.selection.json.XXXXXX")" || return 0
    if jq '.items = ((.items // {}) | with_entries(select((.value.source // "") != "script")))
           | .selected = (.items | keys) | del(.script_installer)' "$dest" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$dest" && ok "Removed script-installer entries from $dest"
    else
        rm -f "$tmp"
    fi
}

# --- Uninstall ----------------------------------------------------------

uninstall() {
    echo ""
    warn "The following will be removed:"
    echo "  - $CLAUDE_DIR/CLAUDE.md"
    echo "  - $CLAUDE_DIR/settings.json (backed up first)"
    echo "  - $CLAUDE_DIR/rules/"
    echo "  - $CLAUDE_DIR/skills/ (installer-managed only; pinned upstream skills only when unmodified)"
    echo "  - $CLAUDE_DIR/agents/ (installer-managed only)"
    echo "  - $CLAUDE_DIR/scripts/ (installer-managed only)"
    echo "  - $CLAUDE_DIR/skills/image-gen/ (when installer-owned, via .image-gen-sinedied)"
    echo "  - $CLAUDE_DIR/scripts/image-gen-openrouter.py (image-gen wrapper)"
    echo "  - $CLAUDE_DIR/.image-gen-sinedied (image-gen ownership manifest)"
    echo "  - $CLAUDE_DIR/skills/deepxiv-* (DeepXiv skills)"
    echo "  - $CLAUDE_DIR/lessons.md"
    echo "  - $CLAUDE_DIR/hooks/ (installer-managed only)"
    echo "  - Installed plugins (requires claude CLI)"
    echo "  - MCP servers: playwright, lark-mcp (if present; requires claude CLI)"
    [[ -f "$VERSION_STAMP_FILE" ]] && echo "  - $VERSION_STAMP_FILE"
    echo ""

    if $DRY_RUN; then
        warn "DRY RUN -- nothing will be removed"
        return
    fi

    if ! confirm "Proceed with uninstall?"; then
        info "Cancelled."
        exit 0
    fi

    rm -f "$CLAUDE_DIR/CLAUDE.md" && ok "Removed CLAUDE.md"

    if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
        cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.bak"
        ok "Backed up settings.json -> settings.json.bak"
        rm -f "$CLAUDE_DIR/settings.json" && ok "Removed settings.json"
    fi

    rm -rf "$CLAUDE_DIR/rules" && ok "Removed rules/"

    # Only remove the skills this script installer owns. Skills managed by the
    # agent-guided path (edit-config, storage-analyzer, ...) and user-authored
    # skills are left alone; image-gen is governed by its manifest below.
    local skill
    for skill in "${SCRIPT_OWNED_SKILLS[@]}"; do
        is_agent_managed_elsewhere "skills/$skill" && continue
        if [[ -d "$CLAUDE_DIR/skills/$skill" ]]; then
            rm -rf "$CLAUDE_DIR/skills/$skill" && ok "Removed skill: $skill"
        fi
    done
    # Pinned upstream skills: only unmodified copies this installer recorded
    # in agent-config/files.json. Legacy bundled humanizer copies only when
    # they still match what earlier releases shipped.
    local up_item up_name
    while IFS= read -r up_item; do
        for up_name in $(upstream_skill_field "$up_item" targets); do
            remove_script_managed_skill "$up_name" || true
        done
    done < <(upstream_skill_items)
    cleanup_legacy_vendored_skill humanizer "$LEGACY_HUMANIZER_SHA256" || true
    cleanup_legacy_vendored_skill humanizer-zh "$LEGACY_HUMANIZER_ZH_SHA256" || true

    # Only remove agents that ship with this repo
    if [[ -d "$SCRIPT_DIR/agents" ]]; then
        for agent_file in "$SCRIPT_DIR"/agents/*.md; do
            [[ -f "$agent_file" ]] || continue
            local agent
            agent=$(basename "$agent_file")
            rm -f "$CLAUDE_DIR/agents/$agent" && ok "Removed agent: $agent"
        done
    else
        rm -rf "$CLAUDE_DIR/agents" && ok "Removed agents/"
    fi

    # Only remove maintenance scripts that this installer manages
    for script in "${USER_SCRIPTS[@]}"; do
        rm -f "$CLAUDE_DIR/scripts/$script" && ok "Removed script: $script"
    done
    rmdir "$CLAUDE_DIR/scripts" 2>/dev/null || true

    rm -f "$CLAUDE_DIR/claude.zsh" && ok "Removed claude.zsh"
    rm -f "$CLAUDE_DIR/system-prompt.txt" && ok "Removed system-prompt.txt"
    # profiles/ and default-profile are deliberately left in place: the profile
    # files hold API keys the user pasted in, and silently deleting credentials
    # on uninstall is not recoverable.
    if [[ -d "$CLAUDE_DIR/profiles" ]]; then
        warn "Kept $CLAUDE_DIR/profiles (contains your API keys) — delete it manually if you want them gone"
    fi

    # Remove DeepXiv skills (glob to catch any installed by --all)
    for deepxiv_skill in "$CLAUDE_DIR"/skills/deepxiv-*/; do
        [[ -d "$deepxiv_skill" ]] || continue
        rm -rf "$deepxiv_skill" && ok "Removed DeepXiv skill: $(basename "$deepxiv_skill")"
    done

    # --all: uninstall purges every manifest-owned mattpocock skill, including
    # the curated keep list that a normal install run preserves.
    cleanup_retired_skills --all

    # Remove the image-gen Skill ONLY when the ownership manifest proves this
    # installer installed it. Validates EVERY fixed field (skill/source/wrapper)
    # before any delete, so a user-authored directory whose name collides with
    # image-gen — or a manifest tampered with / left stale by another tool — is
    # never recursively deleted. The wrapper is removed by the USER_SCRIPTS
    # loop above; here we only handle the Skill directory and the manifest.
    local ig_manifest="$CLAUDE_DIR/.image-gen-sinedied"
    if [[ -f "$ig_manifest" ]]; then
        if _image_gen_dir_owned "$CLAUDE_DIR/skills/image-gen" "$ig_manifest"; then
            if [[ -d "$CLAUDE_DIR/skills/image-gen" ]]; then
                rm -rf "$CLAUDE_DIR/skills/image-gen" && ok "Removed image-gen Skill (installer-owned)"
            fi
            rm -f "$ig_manifest" && ok "Removed image-gen ownership manifest"
        else
            warn "image-gen: ownership proof incomplete (valid manifest + augmentation markers both required) — leaving ~/.claude/skills/image-gen untouched and removing only the stale manifest"
            rm -f "$ig_manifest" 2>/dev/null || true
        fi
    fi

    rm -f "$CLAUDE_DIR/lessons.md" && ok "Removed lessons.md"

    # Only remove hooks that ship with this repo
    if [[ -d "$CLAUDE_TEMPLATES_DIR/hooks" ]]; then
        for hook_file in "$CLAUDE_TEMPLATES_DIR"/hooks/*; do
            [[ -f "$hook_file" ]] || continue
            local fname
            fname=$(basename "$hook_file")
            rm -f "$CLAUDE_DIR/hooks/$fname" && ok "Removed hook: $fname"
        done
    else
        rm -rf "$CLAUDE_DIR/hooks" && ok "Removed hooks/"
    fi

    if command -v claude &>/dev/null; then
        local all_plugins=("${PLUGINS_ESSENTIAL[@]}" "${PLUGINS_OPTIONAL[@]}" "${PLUGINS_AI_RESEARCH[@]}" "${PLUGINS_REVIEW[@]}" "${PLUGINS_REMOVED[@]}")
        for entry in "${all_plugins[@]}"; do
            local plugin_name="${entry%%@*}"
            claude plugin uninstall "$entry" 2>/dev/null && \
                ok "Uninstalled plugin: $plugin_name" || \
                warn "Could not uninstall: $plugin_name"
        done
        claude mcp remove lark-mcp 2>/dev/null && \
            ok "Removed MCP server: lark-mcp" || \
            warn "Could not remove lark-mcp"
        claude mcp remove playwright 2>/dev/null && \
            ok "Removed MCP server: playwright" || \
            warn "Could not remove playwright"
    else
        warn "Claude CLI not found — cannot uninstall plugins or MCP servers"
    fi

    clear_script_selection_records || true
    rm -f "$VERSION_STAMP_FILE"
    echo ""
    ok "Uninstall complete."
}

# ============================================================
# GPT CLIProxyAPI auto-configuration: pure key-resolution helpers.
#
# These functions are side-effect-free (no writes to HOME, no network, no
# logging) so they can be unit-tested by sourcing this script. The atomic
# coordinator (install step) will call gpt_resolve_key and gpt_render_config
# to assemble ~/.cli-proxy-api/config.yaml.
#
# Key resolution order: existing config > active profile token > generated.
# gpt_resolve_key sets the global GPT_KEY_SOURCE to one of
# "config" | "profile" | "generated" so the coordinator can report the
# provenance. Note: when invoked through command substitution the source
# assignment is lost (subshell), so the coordinator must call it directly
# and capture stdout via a redirect, not $(...).
# ============================================================

# Print a fresh 32-byte CSPRNG key as 64 lowercase hex chars to stdout.
# Returns 1 if neither openssl nor /dev/urandom yields a valid key. No logging.
gpt_generate_key() {
    local key=""
    if command -v openssl >/dev/null 2>&1; then
        key=$(openssl rand -hex 32 2>/dev/null) || key=""
    fi
    if [[ -z "$key" && -r /dev/urandom ]]; then
        key=$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n') || key=""
    fi
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$key"
}

# Validate a candidate key scalar from either reuse source. Restrict reused
# values to an unambiguous portable token alphabet so quotes, backslashes,
# whitespace/control characters, comments, mappings and flow syntax can never
# alter the normalized YAML document.
_gpt_valid_key_value() {
    local v="$1"
    [[ -n "$v" && "$v" != YOUR_* ]] || return 1
    [[ "$v" =~ ^[A-Za-z0-9._~-]+$ ]]
}

# Extract the first valid top-level key from a CLIProxyAPI config.yaml.
# Constrained awk/shell parser: only a column-0 `api-keys:` block or inline
# sequence is considered; nested keys, mappings, anchors/aliases, flow
# mappings, placeholders and empty values are rejected. Quotes and inline
# whitespace are stripped. Prints the key and returns 0, else returns 1.
gpt_extract_config_key() {
    local path="$1" cand
    [[ -r "$path" ]] || return 1
    while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        # Strip matching surrounding quotes (single or double).
        if [[ "$cand" =~ ^\"(.*)\"$ ]]; then
            cand="${BASH_REMATCH[1]}"
        elif [[ "$cand" =~ ^\'(.*)\'$ ]]; then
            cand="${BASH_REMATCH[1]}"
        fi
        # Trim leading/trailing inline whitespace.
        cand="${cand#"${cand%%[![:space:]]*}"}"
        cand="${cand%"${cand##*[![:space:]]}"}"
        if _gpt_valid_key_value "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
    done < <(
        awk '
            BEGIN { in_block = 0 }
            {
                # A column-0, non-blank, non-comment line ends any block.
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
                # Top-level api-keys: must start at column 0.
                if ($0 ~ /^api-keys:/) {
                    rest = $0
                    sub(/^api-keys:[ \t]*/, "", rest)
                    sub(/[ \t]+#.*/, "", rest)
                    # A header whose value is a pure comment (`api-keys: # note`)
                    # must fall through to block mode, not be emitted as a key.
                    if (rest ~ /^#/) rest = ""
                    if (rest ~ /^\[/) {
                        sub(/^\[/, "", rest)
                        sub(/\][ \t]*$/, "", rest)
                        m = split(rest, arr, ",")
                        for (i = 1; i <= m; i++) {
                            v = arr[i]
                            sub(/^[ \t]+/, "", v)
                            sub(/[ \t]+$/, "", v)
                            if (length(v) > 0) print v
                        }
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

# Extract ANTHROPIC_AUTH_TOKEN from a Claude Code profile JSON. Returns 1 if
# the file is unreadable, the field is absent/empty, or it is a YOUR_* placeholder.
gpt_extract_profile_token() {
    local path="$1" token
    [[ -r "$path" ]] || return 1
    token=$(jq -er '.env.ANTHROPIC_AUTH_TOKEN // empty' "$path" 2>/dev/null) || return 1
    _gpt_valid_key_value "$token" || return 1
    printf '%s' "$token"
}

# Resolve a CLIProxyAPI key by trying config, then profile, then generation.
# Prints the key to stdout and sets GPT_KEY_SOURCE in the calling shell
# (only when not invoked through command substitution).
gpt_resolve_key() {
    local config="$1" profile="$2" key=""
    if key=$(gpt_extract_config_key "$config" 2>/dev/null) && [[ -n "$key" ]]; then
        GPT_KEY_SOURCE="config"
        printf '%s' "$key"
        return 0
    fi
    if key=$(gpt_extract_profile_token "$profile" 2>/dev/null) && [[ -n "$key" ]]; then
        GPT_KEY_SOURCE="profile"
        printf '%s' "$key"
        return 0
    fi
    if key=$(gpt_generate_key) && [[ -n "$key" ]]; then
        GPT_KEY_SOURCE="generated"
        printf '%s' "$key"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# proxy-url helpers (CLIProxyAPI outbound proxy).
#
# CLIProxyAPI consumes an optional top-level `proxy-url:` scalar from
# config.yaml to route its upstream HTTPS requests through a local forwarder.
# The installer never invents a value: it only preserves an existing valid
# config value or honours an explicit GPT_PROXY_URL env var. Standard proxy
# env vars (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY) are deliberately NOT read —
# they routinely carry short-lived credentials and silently persisting them
# would break idempotency. The URL value itself is never logged.
# ------------------------------------------------------------

# Validate a candidate proxy-url scalar. Restricts the value to a safe URL
# shape (http/https/socks5/socks5h scheme + non-empty authority) drawn from a
# portable character set, rejecting the YAML-injection and control characters
# (quotes, backslash, whitespace, CR/LF/tab) that could break or rewrite the
# normalized document. Returns 0/1; never prints.
_gpt_valid_proxy_url_value() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    # Reject YAML-injection / control characters wholesale.
    case "$v" in
        *'"'*|*"'"*|*'\'*|*' '*|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
    esac
    # Scheme + non-empty remainder.
    local rest
    if [[ "$v" =~ ^(https?|socks5h?)://(.*)$ ]]; then
        rest="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    [[ -n "$rest" ]] || return 1
    # Split authority from path/query. The authority ends at the first '/' or
    # '?' (or end of string) and MUST be non-empty: `http:///path` and
    # `http://?x=y` both yield an empty authority and are rejected. A missing
    # host is the primary authority-less trap.
    local authority pathquery
    if [[ "$rest" =~ ^([^/?]*)(.*)$ ]]; then
        authority="${BASH_REMATCH[1]}"
        pathquery="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    [[ -n "$authority" ]] || return 1
    # Validate the authority structurally. Two legal host shapes:
    #   (A) bracketed IPv6:   [userinfo@][host](:port)?   — host inside [..]
    #   (B) plain hostname:   [userinfo@]host(:port)?     — host has no ':'
    # Constraints enforced by the regexes + port range check below:
    #   - userinfo is optional, drawn from a safe charset that EXCLUDES '@', so
    #     at most one '@' can ever appear in the authority (`a@@host` rejected).
    #   - host is non-empty. A bracketed IPv6 host requires balanced [..]; a
    #     plain host excludes ':', '[', ']' so unbracketed IPv6 (`::1:1080`),
    #     port-with-no-host (`:1080`), and userinfo-with-no-host (`user@/path`)
    #     all fail to match.
    #   - a port, when its ':' separator is present, MUST be all digits (the
    #     regex `:[0-9]+` rejects empty/non-numeric) and is then range-checked
    #     to 1..65535 below (rejects 0 and 99999).
    # The regexes are held in variables so bracket/colon metacharacters are not
    # re-parsed by the [[ ]] word splitter (Bash 3.2-safe form).
    local _br_ipv6_re='^([A-Za-z0-9._~%:+-]*@)?\[([A-Za-z0-9:.]+)\](:[0-9]+)?$'
    local _plain_re='^([A-Za-z0-9._~%:+-]*@)?([A-Za-z0-9._~%-]+)(:[0-9]+)?$'
    local host="" port_str=""
    if [[ "$authority" =~ $_br_ipv6_re ]]; then
        host="${BASH_REMATCH[2]}"
        port_str="${BASH_REMATCH[3]}"
    elif [[ "$authority" =~ $_plain_re ]]; then
        host="${BASH_REMATCH[2]}"
        port_str="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    [[ -n "$host" ]] || return 1
    # Port range: 1..65535 when the optional :port is present.
    if [[ -n "$port_str" ]]; then
        local port="${port_str#:}"
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        # Reject an oversized numeric string BEFORE the arithmetic comparison:
        # Bash uses 64-bit signed integers, so a >5-digit value (e.g. a 20-digit
        # uint64-overflow probe) would wrap/saturate and could slip past a bare
        # `-le 65535` check. The largest legal port (65535) is 5 digits, so a
        # length cap is a safe, branch-shared pre-filter for both authority
        # shapes before the precise 1..65535 range test.
        [[ "${#port}" -le 5 ]] || return 1
        [[ "$port" -ge 1 && "$port" -le 65535 ]] || return 1
    fi
    # Optional path/query charset (may be empty).
    if [[ -n "$pathquery" ]]; then
        local _pq_re='^[]A-Za-z0-9._~%:@/?&=+-]+$'
        [[ "$pathquery" =~ $_pq_re ]] || return 1
    fi
    return 0
}

# Return 0 if <path> contains a top-level (column-0) `proxy-url:` mapping key,
# regardless of whether its value is valid. Used by the resolver/coordinator
# to distinguish "absent" (fall through to env) from "present but malformed"
# (fail safe). Nested (indented) proxy-url keys are top-level invisible.
_gpt_proxy_url_key_present() {
    local path="$1"
    [[ -r "$path" ]] || return 1
    awk 'BEGIN{f=0} /^proxy-url:/{f=1} END{exit f?0:1}' "$path" 2>/dev/null
}

# Extract and parse a top-level `proxy-url:` scalar from a CLIProxyAPI
# config.yaml. Accepts http://, https://, socks5:// and socks5h://, quoted
# (single/double) or unquoted, with an optional trailing comment. Rejects
# nested keys, empty/bare values, unsupported schemes, malformed URLs,
# control characters, and YAML-injection attempts (trailing non-comment
# content after a quoted scalar). Prints the validated value and returns 0
# on a clean hit; returns 1 (printing nothing) for absent/rejected values.
gpt_extract_proxy_url() {
    local path="$1" raw_value
    [[ -r "$path" ]] || return 1
    raw_value=$(awk '
        BEGIN { found = 0; bad = 0; value = "" }
        /^proxy-url:/ {
            if (found) { bad = 1; next }
            found = 1
            line = $0
            sub(/^proxy-url:[ \t]*/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") { bad = 1; next }
            q = substr(line, 1, 1)
            if (q == "\"" || q == "\x27") {
                body = substr(line, 2)
                i = index(body, q)
                if (i == 0) { bad = 1; next }
                value = substr(body, 1, i - 1)
                trail = substr(body, i + 1)
                gsub(/^[ \t]+/, "", trail)
                if (trail != "" && substr(trail, 1, 1) != "#") bad = 1
                next
            }
            # Unquoted scalar: drop a trailing inline comment, then trim.
            value = line
            sub(/[ \t]+#.*/, "", value)
            sub(/[ \t]+$/, "", value)
            if (value == "") bad = 1
            next
        }
        END {
            if (bad || !found) exit 1
            print value
        }
    ' "$path" 2>/dev/null) || return 1
    [[ -n "$raw_value" ]] || return 1
    _gpt_valid_proxy_url_value "$raw_value" || return 1
    printf '%s' "$raw_value"
}

# Resolve the effective proxy-url with fixed precedence
#   existing valid config proxy-url  >  GPT_PROXY_URL env  >  none (empty)
# and set GPT_PROXY_SOURCE to "config" | "env" | "none" in the calling shell.
# Standard proxy env vars are intentionally ignored. A top-level proxy-url
# that is present but malformed (or an explicit GPT_PROXY_URL that fails
# validation) returns 1 so the coordinator can fail safe WITHOUT writing.
# The URL value is printed only on a successful config/env resolution.
gpt_resolve_proxy_url() {
    local config="$1" v=""
    GPT_PROXY_SOURCE="none"
    if _gpt_proxy_url_key_present "$config"; then
        if v=$(gpt_extract_proxy_url "$config" 2>/dev/null) && [[ -n "$v" ]]; then
            GPT_PROXY_SOURCE="config"
            printf '%s' "$v"
            return 0
        fi
        # Present but unparseable/invalid: fail safe (no value emitted).
        return 1
    fi
    if [[ -n "${GPT_PROXY_URL:-}" ]] && _gpt_valid_proxy_url_value "$GPT_PROXY_URL"; then
        GPT_PROXY_SOURCE="env"
        printf '%s' "$GPT_PROXY_URL"
        return 0
    fi
    if [[ -n "${GPT_PROXY_URL:-}" ]]; then
        # Explicit env value present but invalid: fail safe.
        return 1
    fi
    return 0
}

# Render the normalized CLIProxyAPI config.yaml body for a given key. Rejects
# an empty key. Output is deterministic and byte-for-byte stable. The optional
# second argument is the auth-dir value (defaults to the literal
# "~/.cli-proxy-api" so CLIProxyAPI expands it at runtime); a custom auth_dir
# is rendered as a double-quoted YAML scalar, and values containing a double
# quote, backslash, or control char are rejected. The optional third argument
# is a proxy-url: when empty (or omitted) the original 5-line body is emitted
# unchanged; when non-empty it must pass _gpt_valid_proxy_url_value and is
# appended as a quoted `proxy-url:` scalar on its own line between auth-dir
# and api-keys, yielding a stable 6-line document.
gpt_render_config() {
    local key="$1" auth_dir="${2:-~/.cli-proxy-api}" proxy_url="${3:-}"
    _gpt_valid_key_value "$key" || return 1
    case "$auth_dir" in
        *'"'*|*'\'*|*$'\n'*|*$'\t'*|*$'\r'*) return 1 ;;
    esac
    if [[ -n "$proxy_url" ]]; then
        _gpt_valid_proxy_url_value "$proxy_url" || return 1
    fi
    printf '%s\n' 'host: "127.0.0.1"'
    printf '%s\n' 'port: 8317'
    printf 'auth-dir: "%s"\n' "$auth_dir"
    if [[ -n "$proxy_url" ]]; then
        printf 'proxy-url: "%s"\n' "$proxy_url"
    fi
    printf '%s\n' 'api-keys:'
    printf '  - "%s"\n' "$key"
}

# ============================================================
# GPT CLIProxyAPI auto-configuration: atomic reconciliation layer.
#
# gpt_backup_file, gpt_atomic_write, gpt_sync_profile_token and the
# configure_gpt_backend coordinator build on the pure helpers above. They
# are the only functions here that touch the filesystem. Failures are
# propagated: a random/permission/parse/write error increments
# INSTALL_CRITICAL and returns non-zero so the caller can surface it.
#
# Paths are read from the environment so tests (and users) can relocate the
# whole tree without editing the script:
#   GPT_CONFIG_DIR  default ~/.cli-proxy-api   (holds config.yaml + backups)
#   GPT_PROFILE     default $CLAUDE_DIR/profiles/gpt.json
# Key material is never logged and never appears in a path component.
# ============================================================

# Create a 600-mode timestamped backup of <path> next to it. Prints the backup
# path to stdout and returns 0 on success, 1 otherwise. The destination is
# reserved ATOMICALLY (noclobber create) so two concurrent same-timestamp calls
# can never collide on one path: the loser of the primary slot walks a numeric
# suffix until its own atomic reservation succeeds. Both snapshots survive. The
# trailing ".bak" is preserved on every variant so `config.yaml.*.bak` style
# globs keep matching, and mode 600 is set before any bytes are copied (no
# cp -p mode-inheritance window). The original file is never modified.
gpt_backup_file() {
    local path="$1" dir base stamp candidate restore_umask i=0
    [[ -f "$path" ]] || return 1
    dir=$(dirname "$path")
    base=$(basename "$path")
    stamp=$(date '+%Y%m%d%H%M%S')
    restore_umask=$(umask)
    umask 077
    candidate="${dir%/}/${base}.${stamp}.bak"
    # Atomic reservation: `( set -C; : > "$candidate" )` creates the path only
    # if it does not already exist (noclobber), so the check-and-create is a
    # single indivisible step that survives a concurrent same-timestamp race.
    # On collision, walk a numeric suffix (still ending in .bak) until a free
    # slot is reserved. The bound guards against a wedged filesystem loop.
    while ! ( set -C; : > "$candidate" ) 2>/dev/null; do
        i=$((i + 1))
        candidate="${dir%/}/${base}.${stamp}.${i}.bak"
        if [[ "$i" -ge 1000 ]]; then
            umask "$restore_umask"
            return 1
        fi
    done
    # We now exclusively own `candidate` (created under umask 077 -> mode 600).
    # A failure here must release the reservation so a later run can retry.
    if ! chmod 600 "$candidate" 2>/dev/null || ! cp "$path" "$candidate" 2>/dev/null; then
        rm -f "$candidate" 2>/dev/null
        umask "$restore_umask"
        return 1
    fi
    umask "$restore_umask"
    printf '%s' "$candidate"
}

# Atomically replace <path> with <content>. The temp file is created in the
# same directory (so the rename stays on one filesystem), written, chmod'd
# 600, then mv -f into place. On ANY failure the temp file is removed and the
# original is left byte-for-byte intact. Returns 0/1.
gpt_atomic_write() {
    local path="$1" content="$2" dir base tmp restore_umask
    [[ -n "$path" ]] || return 1
    dir=$(dirname "$path")
    base=$(basename "$path")
    [[ -d "$dir" ]] || return 1
    restore_umask=$(umask)
    umask 077
    tmp=$(mktemp "${dir%/}/${base}.tmp.XXXXXX" 2>/dev/null) || {
        umask "$restore_umask"
        return 1
    }
    if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; umask "$restore_umask"; return 1
    fi
    if ! chmod 600 "$tmp" 2>/dev/null; then
        rm -f "$tmp"; umask "$restore_umask"; return 1
    fi
    if ! mv -f "$tmp" "$path" 2>/dev/null; then
        rm -f "$tmp"; umask "$restore_umask"; return 1
    fi
    umask "$restore_umask"
    return 0
}

# Sync .env.ANTHROPIC_AUTH_TOKEN in <profile> to <key>, writing atomically.
# Skips the write when the normalized JSON is unchanged. Returns 0/1; never
# prints the key. Leaves the profile with mode 600.
gpt_sync_profile_token() {
    local profile="$1" key="$2" updated
    [[ -r "$profile" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    updated=$(jq --arg key "$key" '.env.ANTHROPIC_AUTH_TOKEN = $key' "$profile" 2>/dev/null) || return 1
    # Reject malformed output.
    printf '%s' "$updated" | jq -e . >/dev/null 2>&1 || return 1
    # Skip the write when the normalized JSON is already identical.
    if [[ "$(printf '%s' "$updated" | jq -S .)" == "$(jq -S . "$profile" 2>/dev/null)" ]]; then
        chmod 600 "$profile" 2>/dev/null || true
        return 0
    fi
    if ! gpt_atomic_write "$profile" "$updated"; then
        return 1
    fi
    chmod 600 "$profile" 2>/dev/null || true
    return 0
}

# Apply mode 600 to credential-bearing profile artifacts without recursing
# into unrelated trees. Any chmod failure is fatal because these files can
# contain live credentials.
_gpt_secure_profile_artifacts() {
    local profiles_dir="$1" artifact
    [[ -d "$profiles_dir" ]] || return 0
    for artifact in "$profiles_dir"/*.json "$profiles_dir"/.baseline/*.json "$profiles_dir"/*.json.*.bak; do
        [[ -e "$artifact" ]] || continue
        chmod 600 "$artifact" 2>/dev/null || return 1
    done
}

# Coordinator: reconcile ~/.cli-proxy-api/config.yaml with the installed gpt
# profile so both share a single key. Idempotent: a normalized config with a
# matching profile token is a no-op (no backup, no write). On a config/profile
# divergence the config key wins. Both target contents are computed BEFORE any
# write, so a parse failure cannot leave only one file updated; if the config
# write succeeds but the profile sync fails, the just-created backup restores
# the config (or, for a brand-new config, it is removed). Reports the key
# provenance category only — never the key itself.
configure_gpt_backend() {
    local _gpt_had_xtrace=false _gpt_selected=false _gpt_profile _gpt_rc
    case $- in *x*) _gpt_had_xtrace=true; set +x ;; esac

    # Selection, not the presence of a stale installed profile, controls this
    # invocation. Iterate explicitly for Bash 3.2 empty-array/set -u safety.
    local _gpt_choice
    for _gpt_choice in ${SELECTED_PROFILES[@]+"${SELECTED_PROFILES[@]}"}; do
        [[ "$_gpt_choice" == "gpt" ]] && { _gpt_selected=true; break; }
    done
    if ! $_gpt_selected; then
        $_gpt_had_xtrace && set -x
        return 0
    fi

    _configure_gpt_backend_impl
    _gpt_rc=$?
    # Secret-bearing locals belong to the inner function and are gone before
    # the caller's xtrace state is restored.
    $_gpt_had_xtrace && set -x
    return "$_gpt_rc"
}

_configure_gpt_backend_impl() {
    local config_dir profile config
    config_dir="${GPT_CONFIG_DIR:-$HOME/.cli-proxy-api}"
    profile="${GPT_PROFILE:-$CLAUDE_DIR/profiles/gpt.json}"
    config="$config_dir/config.yaml"

    # Not selected: no installed gpt profile -> nothing to do.
    [[ -r "$profile" ]] || return 0

    if $DRY_RUN; then
        info "GPT backend: would reconcile $config and sync profile token (dry run)"
        return 0
    fi

    command -v jq >/dev/null 2>&1 || {
        warn "GPT backend: jq not found — skipping CLIProxyAPI reconciliation"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    }

    # Clear the provenance global before resolution so a stale value from an
    # earlier run can never leak into the report.
    GPT_KEY_SOURCE=""
    local key="" _key_tmp
    _key_tmp=$(mktemp 2>/dev/null) || { warn "GPT backend: mktemp failed"; INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1)); return 1; }
    # Run gpt_resolve_key with a stdout redirect (NOT command substitution):
    # the GPT_KEY_SOURCE side effect is lost inside a subshell, so we must keep
    # the call in this shell and capture the key via the temp file.
    if ! gpt_resolve_key "$config" "$profile" > "$_key_tmp" 2>/dev/null; then
        rm -f "$_key_tmp"
        warn "GPT backend: could not resolve a CLIProxyAPI key"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    fi
    key=$(cat "$_key_tmp" 2>/dev/null)
    rm -f "$_key_tmp"
    [[ -n "$key" ]] || { warn "GPT backend: resolved empty key"; INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1)); return 1; }
    local source="$GPT_KEY_SOURCE"

    # Resolve the outbound proxy-url with fixed precedence
    #   existing valid config  >  GPT_PROXY_URL env  >  omitted
    # BEFORE any filesystem write. A top-level proxy-url that is present but
    # malformed (or an explicit GPT_PROXY_URL that fails validation) is
    # fail-safe: increment INSTALL_CRITICAL and return without touching config
    # or profile. The URL value is captured through a temp-file redirect (not
    # command substitution) so the GPT_PROXY_SOURCE side effect lands in this
    # shell and the value is never echoed. xtrace is already suppressed by the
    # configure_gpt_backend wrapper for this whole inner function.
    GPT_PROXY_SOURCE=""
    local proxy_url="" _proxy_tmp
    _proxy_tmp=$(mktemp 2>/dev/null) || { warn "GPT backend: mktemp failed"; INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1)); return 1; }
    if ! gpt_resolve_proxy_url "$config" > "$_proxy_tmp" 2>/dev/null; then
        rm -f "$_proxy_tmp"
        warn "GPT backend: malformed proxy-url in $(basename "$config") — leaving config and profile untouched"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    fi
    proxy_url=$(cat "$_proxy_tmp" 2>/dev/null)
    rm -f "$_proxy_tmp"

    # Compute BOTH target bodies up front; a parse failure aborts before any
    # write so the on-disk state stays consistent. The auth-dir value tracks
    # GPT_CONFIG_DIR so a custom config directory is reflected in the rendered
    # config. The canonical default is the literal "~/.cli-proxy-api" (which
    # CLIProxyAPI expands at runtime); a GPT_CONFIG_DIR that merely reproduces
    # the default location keeps the literal so a hand-written canonical config
    # is a byte-for-byte idempotent no-op. Only a directory that diverges from
    # $HOME/.cli-proxy-api forces its absolute path into the rendered scalar.
    local rendered updated auth_dir="~/.cli-proxy-api" custom_dir=false service_cfg=""
    if [[ -n "${GPT_CONFIG_DIR:-}" && "$GPT_CONFIG_DIR" != "$HOME/.cli-proxy-api" ]]; then
        auth_dir="$GPT_CONFIG_DIR"
        custom_dir=true
        service_cfg="${GPT_CONFIG_DIR%/}/config.yaml"
    fi
    rendered=$(gpt_render_config "$key" "$auth_dir" "$proxy_url") || {
        warn "GPT backend: failed to render config"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    }
    # Sync the profile token. When GPT_CONFIG_DIR diverges from the default,
    # also rewrite the launcher-facing .service.configFile and the config path
    # embedded in .service.start so claude.zsh launches CLIProxyAPI against the
    # SAME config the installer just wrote. The default path is left untouched
    # (the shipped profile already points at ~/.cli-proxy-api/config.yaml). The
    # rewrite is guarded so a profile whose .service is a string or lacks the
    # expected string fields is passed through unchanged. The whole normalized
    # body is computed before any write, so the existing transactional rollback
    # (config restored from backup if the profile atomic write fails) still
    # holds: either both the token AND the service paths land together or
    # nothing does.
    if $custom_dir; then
        updated=$(jq --arg key "$key" --arg cfg "$service_cfg" '
            .env.ANTHROPIC_AUTH_TOKEN = $key
            | if (.service | type) == "object"
                and (.service.configFile | type) == "string"
                and (.service.start | type) == "string"
                and ($cfg | . != "")
              then .service.configFile = $cfg
                 | .service.start |= gsub("[^ \"]*config\\.yaml"; $cfg)
              else . end
        ' "$profile" 2>/dev/null) || {
            warn "GPT backend: profile JSON parse failed"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        }
    else
        updated=$(jq --arg key "$key" '.env.ANTHROPIC_AUTH_TOKEN = $key' "$profile" 2>/dev/null) || {
            warn "GPT backend: profile JSON parse failed"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        }
    fi
    printf '%s' "$updated" | jq -e . >/dev/null 2>&1 || {
        warn "GPT backend: normalized profile JSON invalid"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    }

    # Provision the config directory with mode 700.
    if ! mkdir -p "$config_dir" 2>/dev/null; then
        warn "GPT backend: cannot create $config_dir"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    fi
    chmod 700 "$config_dir" 2>/dev/null || {
        warn "GPT backend: cannot chmod 700 $config_dir"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    }

    local had_config=false prior_config=""
    if [[ -f "$config" ]]; then
        had_config=true
        prior_config=$(cat "$config" 2>/dev/null) || prior_config=""
    fi

    local need_config_write=true
    if $had_config && [[ "$prior_config" == "$rendered" ]]; then
        need_config_write=false
    fi

    # Back up a divergent existing config before touching it.
    local backup=""
    if $need_config_write && $had_config; then
        if ! backup=$(gpt_backup_file "$config"); then
            warn "GPT backend: backup failed — leaving config untouched"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        fi
    fi

    if $need_config_write; then
        if ! gpt_atomic_write "$config" "$rendered"; then
            [[ -n "$backup" ]] && rm -f "$backup" 2>/dev/null
            warn "GPT backend: atomic config write failed"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        fi
    elif ! chmod 600 "$config" 2>/dev/null; then
        warn "GPT backend: cannot chmod 600 $config"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    fi

    # Sync the profile token. If this fails after a successful config write,
    # roll the config back from the just-created backup (or remove a new one).
    local profile_normalized
    profile_normalized=$(printf '%s' "$updated" | jq -S . 2>/dev/null)
    if [[ -n "$profile_normalized" && "$profile_normalized" == "$(jq -S . "$profile" 2>/dev/null)" ]]; then
        if ! chmod 600 "$profile" 2>/dev/null; then
            warn "GPT backend: cannot chmod 600 $profile"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        fi
    else
        if ! gpt_atomic_write "$profile" "$updated"; then
            # Roll the config back ONLY if we actually wrote it this run. A
            # pristine config (need_config_write=false) is left untouched; the
            # mv -f and the gpt_atomic_write fallback are both atomic so the
            # restore can never leave a partial file behind.
            if $need_config_write; then
                if $had_config; then
                    if [[ -n "$backup" ]]; then
                        mv -f "$backup" "$config" 2>/dev/null || gpt_atomic_write "$config" "$prior_config" 2>/dev/null || true
                    else
                        gpt_atomic_write "$config" "$prior_config" 2>/dev/null || true
                    fi
                else
                    rm -f "$config" 2>/dev/null || true
                    [[ -n "$backup" ]] && rm -f "$backup" 2>/dev/null
                fi
            fi
            warn "GPT backend: profile token sync failed — config rolled back"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        fi
        if ! chmod 600 "$profile" 2>/dev/null; then
            warn "GPT backend: cannot chmod 600 $profile"
            INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
            return 1
        fi
    fi

    # Secure all credential-bearing profile artifacts.
    local profiles_dir
    profiles_dir=$(dirname "$profile")
    if ! _gpt_secure_profile_artifacts "$profiles_dir"; then
        warn "GPT backend: cannot secure credential-bearing profile artifacts"
        INSTALL_CRITICAL=$((INSTALL_CRITICAL + 1))
        return 1
    fi

    unset key rendered updated prior_config profile_normalized proxy_url
    ok "GPT CLIProxyAPI backend configured (key source: $source)"
    return 0
}

# --- Main ---------------------------------------------------------------

main() {
    detect_script_dir
    parse_args "$@"

    if $LIST_IDS; then
        print_menu_ids
        exit 0
    fi

    # Handle --version
    if $SHOW_VERSION; then
        show_version
        exit 0
    fi

    # Handle --uninstall
    if $UNINSTALL; then
        echo ""
        echo "========================================="
        echo "  Claude Code Config — Uninstaller"
        echo "========================================="
        uninstall
        exit 0
    fi

    # Interactive mode: show menu first
    if $INTERACTIVE; then
        interactive_menu
    fi
    if $ONLY_MODE; then
        apply_only_selection
    fi

    # --all mode: set all flags
    if $INSTALL_ALL; then
        INSTALL_CLAUDE_MD=true
        INSTALL_SETTINGS=true
        INSTALL_RULES=true
        INSTALL_WRITING_STYLE=true
        INSTALL_SKILLS=true
        INSTALL_AGENTS=true
        INSTALL_LESSONS=true
        INSTALL_STATUSLINE=true
        INSTALL_SHELL_WRAPPER=true
        INSTALL_PLUGINS=true
        # All backend profiles; each is just a template until credentials are added
        SELECTED_PROFILES=("glm" "or" "gpt" "ccr")
        # Review defaults for --all: both OFF, so CLAUDE.md points at the
        # code-reviewer agent. --all does not install the codex CLI, and the
        # adversarial-review skill hard-requires `codex exec`, so flipping this
        # on here would wire the review rule to a path that cannot run.
        # The skill files themselves are still installed by --all.
        REVIEW_ADVERSARIAL=false
        # Curated mattpocock/skills subset is on by default
        INSTALL_MATTPOCOCK=true
        if $EXPLICIT_ALL; then
            # Explicit --all: install everything including MCP, DeepXiv, and all plugin groups.
            # This deliberately keeps the standalone playwright MCP, even though
            # it shadows the playwright plugin that --all also installs: --all
            # means everything, and the duplicate is resolvable afterwards with
            # `claude mcp remove playwright`.
            INSTALL_MCP=true
            INSTALL_LARK=true   # --all means everything; lark still self-skips without credentials
            INSTALL_DEEPXIV=true
            SELECTED_DEEPXIV_SKILLS=("${DEEPXIV_KNOWN_SKILLS[@]}")
            # Pinned upstream skills (storage-analyzer stays opt-in, see
            # SCRIPT_OPT_IN_SKILLS).
            SELECTED_UPSTREAM_SKILLS=()
            local _item
            while IFS= read -r _item; do SELECTED_UPSTREAM_SKILLS+=("$_item"); done < <(upstream_skill_items)
            PLUGIN_GROUPS=("all")
            # Add code-review plugin (normally from Review group)
            SELECTED_PLUGINS+=("code-review@claude-plugins-official")
        else
            # Implicit (non-TTY fallback): essential plugins plus the
            # default-selected third-party plugins, so a `curl | bash` install
            # without --all still brings them along.
            # No MCP server is registered here: lark-mcp needs credentials, and
            # the standalone playwright MCP would take the `playwright` name at
            # user scope and shadow the playwright plugin this same branch
            # installs. Opt in with --mcp or the interactive selector.
            PLUGIN_GROUPS=("essential")
            SELECTED_PLUGINS+=("${PLUGINS_OPTIONAL[@]+"${PLUGINS_OPTIONAL[@]}"}")
        fi
    fi

    # image-gen (sinedied/agent-skills) is an always-installed component with
    # no selectable flag and no menu item, so there is no "nothing selected"
    # early exit: even when every selectable item is off, the installer still
    # proceeds to install maintenance scripts and the image-gen Skill. A user
    # who interactively deselects everything still gets the always-on floor.

    echo ""
    echo "========================================="
    echo "  Awesome Claude Code Config Installer"
    echo "  $(get_source_version)"
    echo "========================================="
    echo ""

    if $DRY_RUN; then
        warn "DRY RUN MODE -- no changes will be made"
        echo ""
    fi

    local installed_ver
    installed_ver="$(get_installed_version)"
    if [[ "$installed_ver" != "not installed" ]]; then
        info "Upgrading from $installed_ver -> $(get_source_version)"
    fi

    # In dry-run, perform NO filesystem writes at all (no mkdir, no cp, no
    # chmod) so the run is fully side-effect-free and previewable from an empty
    # HOME. Each install_* function also guards its own writes on $DRY_RUN.
    $DRY_RUN || mkdir -p "$CLAUDE_DIR"
    cleanup_retired_skills
    cleanup_retired_enabled_plugins

    $INSTALL_CLAUDE_MD && install_claude_md
    $INSTALL_SETTINGS && install_settings
    $INSTALL_RULES && install_rules
    $INSTALL_SKILLS && install_skills
    install_upstream_skills || true
    $INSTALL_AGENTS && install_agents
    install_scripts
    # image-gen is always-installed (no flag gate). Runs after install_scripts
    # so the wrapper (a USER_SCRIPT) is already in place when augmentation and
    # the ownership-manifest write check for it.
    install_image_gen
    # Runs AFTER cleanup_retired_skills (above) so the retired-skill prune can
    # never delete what we just installed, and so the manifest ends the run
    # holding exactly MATTPOCOCK_SKILLS.
    $INSTALL_MATTPOCOCK && install_mattpocock_skills
    $INSTALL_LESSONS && install_lessons
    $INSTALL_STATUSLINE && install_statusline
    { $INSTALL_MCP || $INSTALL_LARK; } && install_mcp
    prune_retired_plugins || true
    resolve_plugin_selection
    if plugin_reconcile_enabled && [[ "$PLUGIN_PRUNE_SCOPE" == "all" ]] && ! $DRY_RUN; then
        info "This run aligns your installed plugins to this run's selection — anything not selected is uninstalled. Preview it any time with: $(basename "$0") --dry-run"
    fi
    $INSTALL_PLUGINS && install_plugins
    # Reconcile what is installed against what was selected this run: uninstall
    # unselected plugins, then drop the marketplaces and enabledPlugins entries
    # they leave behind. Only an interactive (full-selection) run reconciles —
    # including one where every plugin item was unchecked, so the plugin step
    # itself was skipped. --all, --only and the non-interactive default run are
    # additive (see plugin_reconcile_enabled). Order matters: plugins first (a
    # marketplace is only orphaned once its plugins are gone), and all of it
    # before update_installed_plugins() so we never spend NET_TIMEOUT refreshing
    # a catalog we are about to delete.
    # (`|| true` keeps the old `a && f` semantics: these helpers return
    # non-zero on their early-exit paths, which must not trip errexit.)
    if plugin_reconcile_enabled; then
        prune_unlisted_plugins || true
        prune_unlisted_marketplaces || true
        sync_enabled_plugins_settings || true
    fi
    # Always refresh marketplaces and update installed plugins, even when no
    # plugins were selected this run — keeps third-party plugins current.
    update_installed_plugins
    $INSTALL_SHELL_WRAPPER && install_shell_wrapper
    $INSTALL_DEEPXIV && install_deepxiv
    write_selection_record || warn "Could not update agent-config/selection.json"

    # Stamp version (skip only on critical warnings — non-critical like plugin failures are OK).
    # A partial --only run does not claim the whole configuration version.
    if ! $DRY_RUN && ! $ONLY_MODE; then
        if [[ $INSTALL_CRITICAL -eq 0 ]]; then
            stamp_version
        else
            warn "Skipping version stamp due to $INSTALL_CRITICAL critical warning(s)"
        fi
    fi

    # Data cleanup runs last so it also sweeps temp dirs created during this run
    # (e.g. plugin marketplace temp dirs from updates above).
    run_cleanup

    echo ""
    if [[ $INSTALL_WARNINGS -gt 0 || $INSTALL_CRITICAL -gt 0 ]]; then
        local total=$((INSTALL_WARNINGS + INSTALL_CRITICAL))
        warn "Installation completed with $total issue(s) ($INSTALL_CRITICAL critical, $INSTALL_WARNINGS non-critical) — review messages above"
    else
        ok "Installation complete! ($(get_source_version))"
    fi
    echo ""
    info "Next steps:"
    local step=1
    echo "  $((step++)). Restart Claude Code for changes to take effect"
    echo "  $((step++)). Customize CLAUDE.md for your specific projects"
    shell_wrapper_source_hint "$step" && step=$((step + 1))
    if $INSTALL_LARK; then
        echo "  $((step++)). Lark/Feishu MCP is installed but needs a Feishu app you create yourself."
        echo "      飞书 MCP 已安装，但还需要你自己在开放平台建一个应用并填入凭证。"
        echo "       1. app / 建应用:  https://open.feishu.cn/  ->  开发者后台  ->  创建企业自建应用"
        echo "       2. key / 取凭证:  应用左栏「凭证与基础信息」里的 App ID (cli_...) 和 App Secret"
        echo "       3. 权限 / scopes: 「权限管理 -> 开通权限」。免审权限即时生效；"
        echo "                          需审核权限还要「版本管理与发布 -> 创建版本 -> 申请线上发布」+ 管理员审批"
        echo "       4. add / 添加:"
        echo "            claude mcp add lark-mcp --scope user -- \\"
        echo "              npx -y @larksuiteoapi/lark-mcp mcp -a <APP_ID> -s <APP_SECRET> -t $LARK_MCP_PRESET"
        echo "          The '--' is required: 'claude mcp add' also uses -s (for --scope) and would eat your secret."
        echo "          '--' 不能省：claude mcp add 自己也用 -s（表示 --scope），会把你的 secret 吃掉。"
        echo "          '-t $LARK_MCP_PRESET' keeps the tool list small; the default preset can blow the context window."
        echo "          '-t $LARK_MCP_PRESET' 限制暴露的工具数量；默认预设会撑爆上下文。"
        echo "       5. check / 验证:  claude mcp list      # expect 'Connected' / 期待显示已连接"
        echo "       Full guide / 完整指引: docs/LARK-MCP.md  (中文: docs/LARK-MCP.zh-CN.md)"
    fi
    backend_setup_hints "$step" && step=$((step + 1))
    cl_commands_hint "$step"
    echo ""
}

# Source guard: only run main when executed directly, not when sourced (e.g. by
# a test harness exercising the pure resolution functions). ACCC_LIB_ONLY is the
# same escape hatch for harnesses that must `bash install.sh` rather than source
# it, and costs nothing at runtime.
if [[ "${BASH_SOURCE[0]}" == "${0}" && -z "${ACCC_LIB_ONLY:-}" ]]; then
    main "$@"
fi

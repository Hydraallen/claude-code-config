#!/usr/bin/env bash
# Clean up Claude Code data directories that are NOT auto-pruned by cleanupPeriodDays.
#
# Claude Code's built-in cleanup only removes old session transcripts under
# ~/.claude/projects (default 30 days, via settings.json "cleanupPeriodDays").
# It never touches telemetry, debug logs, file-history snapshots, homunculus
# state, shell snapshots, paste cache, or leftover plugin marketplace temp dirs.
# This script prunes those by age, plus optionally the oversized claude-mem
# observer-session logs.
#
# SAFE BY DEFAULT: runs in dry-run mode. Pass --apply to actually delete.
#
# Usage:
#   scripts/cleanup-claude-data.sh                  # dry-run, 30-day threshold
#   scripts/cleanup-claude-data.sh --apply          # actually delete (>30 days)
#   scripts/cleanup-claude-data.sh --days 14 --apply # custom age threshold
#   scripts/cleanup-claude-data.sh --include-mem --apply  # also prune claude-mem observer logs
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DAYS=30
APPLY=false
INCLUDE_MEM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --days) DAYS="${2:?--days needs a number}"; shift 2 ;;
        --include-mem) INCLUDE_MEM=true; shift ;;
        -h|--help)
            sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -d "$CLAUDE_DIR" ]]; then
    echo "No Claude data directory at $CLAUDE_DIR" >&2
    exit 1
fi

# Directories that Claude Code never auto-cleans. Files older than $DAYS are removed.
AGE_TARGETS=(
    "telemetry"
    "debug"
    "file-history"
    "homunculus"
    "shell-snapshots"
    "paste-cache"
)

human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

freed_note() {
    local label="$1" path="$2"
    [[ -e "$path" ]] || { printf '  %-26s (absent)\n' "$label"; return; }
    printf '  %-26s %s\n' "$label" "$(human "$path")"
}

echo "=== Claude data cleanup ==="
echo "Dir:       $CLAUDE_DIR"
echo "Threshold: files older than ${DAYS} days"
$APPLY && echo "Mode:      APPLY (will delete)" || echo "Mode:      DRY-RUN (no deletion; pass --apply to delete)"
echo
echo "Current sizes:"
for t in "${AGE_TARGETS[@]}"; do freed_note "$t/" "$CLAUDE_DIR/$t"; done
freed_note "plugins marketplace temp" "$CLAUDE_DIR/plugins/marketplaces"

prune_age() {
    # Delete files older than $DAYS in a directory, then drop empty dirs.
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    local files
    files=$(find "$dir" -type f -mtime "+$DAYS" 2>/dev/null | wc -l | tr -d ' ')
    echo "  $dir -> $files file(s) older than ${DAYS}d"
    $APPLY || return 0
    find "$dir" -type f -mtime "+$DAYS" -delete 2>/dev/null || true
    find "$dir" -type d -empty -delete 2>/dev/null || true
}

echo
echo "Pruning age-based targets:"
for t in "${AGE_TARGETS[@]}"; do prune_age "$CLAUDE_DIR/$t"; done

echo
echo "Pruning leftover plugin marketplace temp/backup dirs:"
mkt="$CLAUDE_DIR/plugins/marketplaces"
if [[ -d "$mkt" ]]; then
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        echo "  remove $(basename "$d") ($(human "$d"))"
        $APPLY && rm -rf "$d"
    done < <(find "$mkt" -maxdepth 1 -type d \( -name 'temp_*' -o -name '*.bak' \) 2>/dev/null)
else
    echo "  (no marketplaces dir)"
fi

if $INCLUDE_MEM; then
    echo
    echo "Pruning claude-mem observer-session logs older than ${DAYS}d:"
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        prune_age "$d"
    done < <(find "$CLAUDE_DIR/projects" -maxdepth 1 -type d -name '*claude-mem-observer-sessions' 2>/dev/null)
else
    echo
    echo "(claude-mem observer logs left untouched; rerun with --include-mem to prune them)"
fi

echo
$APPLY && echo "Done." || echo "Dry-run complete. Re-run with --apply to delete."

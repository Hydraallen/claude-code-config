#!/usr/bin/env bash
# ============================================================
# Unit tests for the PURE plugin-resolution logic in install.sh.
#
# We source install.sh (guarded so main() does not run) and exercise the
# side-effect-free functions `compute_plugins_to_prune` and
# `build_plugin_catalogue` against in-memory fixtures. These tests never call
# the `claude` CLI and never touch the filesystem.
# ============================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$DIR/install.sh"
# install.sh enables `set -euo pipefail`; relax it so assertion failures don't
# abort the whole script and empty-array fixtures are safe to assign.
set +euo pipefail

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        echo "  expected: [$expected]"
        echo "  actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# Run the pure function against the currently-set fixture globals and return a
# stable, sorted, space-joined string for easy comparison.
run_prune() {
    compute_plugins_to_prune | sort | tr '\n' ' ' | sed 's/ *$//'
}

# Does the prune output contain a given key?
prune_contains() {
    compute_plugins_to_prune | grep -qx "$1"
}

# --- Case 1: catalogue plugin installed but NOT selected -> pruned ----------
CATALOGUE_PLUGINS=( "a@m" "b@m" )
RESOLVED_PLUGINS=( )
INSTALLED_PLUGINS=( "a@m" )
assert_eq "catalogue installed, not selected -> appears in prune list" \
    "a@m" "$(run_prune)"

# --- Case 2: catalogue plugin installed AND selected -> NOT pruned ----------
CATALOGUE_PLUGINS=( "a@m" "b@m" )
RESOLVED_PLUGINS=( "a@m" )
INSTALLED_PLUGINS=( "a@m" )
assert_eq "catalogue installed AND selected -> not pruned (reinstall instead)" \
    "" "$(run_prune)"

# --- Case 3: non-catalogue plugin installed -> preserved -------------------
CATALOGUE_PLUGINS=( "a@m" )
RESOLVED_PLUGINS=( )
INSTALLED_PLUGINS=( "code-review@claude-plugins-official" )
assert_eq "non-catalogue installed -> preserved (not pruned)" \
    "" "$(run_prune)"

# --- Case 4: selected plugin not installed -> not pruned -------------------
CATALOGUE_PLUGINS=( "a@m" )
RESOLVED_PLUGINS=( "a@m" )
INSTALLED_PLUGINS=( )
assert_eq "selected but not installed -> not pruned" \
    "" "$(run_prune)"

# --- Case 5: empty installed set -> empty prune list -----------------------
CATALOGUE_PLUGINS=( "a@m" "b@m" )
RESOLVED_PLUGINS=( "a@m" )
INSTALLED_PLUGINS=( )
assert_eq "empty installed set -> empty prune list" \
    "" "$(run_prune)"

# --- Case 6: real-world fixture --------------------------------------------
# Catalogue = full union of the installer's plugin groups.
CATALOGUE_PLUGINS=( )
while IFS= read -r _k; do
    [[ -n "$_k" ]] && CATALOGUE_PLUGINS+=( "$_k" )
done < <(build_plugin_catalogue)

# Selected this run = ESSENTIAL only (note: no ecc, and superpowers is now optional).
RESOLVED_PLUGINS=( "${PLUGINS_ESSENTIAL[@]}" )

# Installed = the user's actual installed_plugins.json keys.
INSTALLED_PLUGINS=(
    "andrej-karpathy-skills@karpathy-skills"
    "code-review@claude-plugins-official"
    "code-simplifier@claude-plugins-official"
    "commit-commands@claude-plugins-official"
    "context7@claude-plugins-official"
    "document-skills@anthropic-agent-skills"
    "ecc@ecc"
    "example-skills@anthropic-agent-skills"
    "feature-dev@claude-plugins-official"
    "frontend-design@claude-plugins-official"
    "github@claude-plugins-official"
    "playwright@claude-plugins-official"
    "ralph-loop@claude-plugins-official"
    "superpowers@claude-plugins-official"
)
assert_eq "real fixture: ecc + superpowers pruned (both optional, installed, not selected)" \
    "ecc@ecc superpowers@claude-plugins-official" "$(run_prune)"

# code-review is a user third-party plugin -> must never be pruned.
if prune_contains "code-review@claude-plugins-official"; then
    echo "FAIL: real fixture: code-review must NOT be pruned"
    FAIL=$((FAIL + 1))
else
    echo "PASS: real fixture: code-review preserved (not pruned)"
    PASS=$((PASS + 1))
fi

# --- Case 7: the GATE (prune_unlisted_plugins layer) -----------------------
# compute_plugins_to_prune() is PURE and correctly returns ALL catalogue keys
# when the selected set is empty. The safety guard against mass-deletion must
# therefore live in prune_unlisted_plugins(): an empty RESOLVED_PLUGINS must be
# a no-op even when the installed set contains catalogue plugins. We run the
# function with a stubbed `claude`, DRY_RUN=true, and a fixture
# installed_plugins.json full of catalogue plugins, in an isolated subshell, and
# assert it emits NO "Would uninstall" line. (Without the guard this is RED:
# every installed catalogue plugin would be reported for pruning.)
test_prune_guard_empty_resolved() {
(
    tmp="$(mktemp -d)"
    export HOME="$tmp"
    mkdir -p "$HOME/.claude/plugins"
    cat > "$HOME/.claude/plugins/installed_plugins.json" <<'JSON'
{ "plugins": { "ecc@ecc": {}, "superpowers@claude-plugins-official": {} } }
JSON
    DRY_RUN=true
    # Stub claude so `command -v claude` succeeds without a real CLI.
    claude() { return 0; }
    RESOLVED_PLUGINS=()
    local out
    out="$(prune_unlisted_plugins 2>&1)"
    rm -rf "$tmp"
    if printf '%s' "$out" | grep -q "Would uninstall"; then
        echo "FAIL: empty RESOLVED_PLUGINS must be a no-op (got prune output)"
        return 1
    fi
    echo "PASS: empty RESOLVED_PLUGINS -> prune_unlisted_plugins is a no-op"
    return 0
)
}

if test_prune_guard_empty_resolved; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

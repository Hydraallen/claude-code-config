#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/install.sh"
set +euo pipefail
PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check(){ local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
contains(){ local d="$1" n="$2" h="$3"; if printf '%s\n' "$h"|grep -Fq "$n"; then pass "$d"; else fail "$d"; fi; }
has(){ local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]]&&return 0; done; return 1; }
count(){ local n="$1"; shift; local x c=0; for x in "$@"; do [[ "$x" == "$n" ]]&&c=$((c+1)); done; printf %s "$c"; }
for fn in is_safe_retired_skill_name sha256_file cleanup_retired_mattpocock_skills cleanup_retired_harness_workflow cleanup_retired_enabled_plugins cleanup_retired_skills; do declare -F "$fn" >/dev/null&&pass "$fn exists"||fail "$fn exists"; done
if declare -F cleanup_retired_mattpocock_skills >/dev/null; then
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR/skills/recorded-skill" "$CLAUDE_DIR/skills/unrecorded-skill" "$CLAUDE_DIR/skills/tdd"; printf 'recorded-skill\n' >"$CLAUDE_DIR/.mattpocock-skills"; cleanup_retired_mattpocock_skills >/dev/null; check "owned removed" test ! -e "$CLAUDE_DIR/skills/recorded-skill"; check "unrecorded preserved" test -e "$CLAUDE_DIR/skills/unrecorded-skill"; check "familiar preserved" test -e "$CLAUDE_DIR/skills/tdd"; check "manifest removed" test ! -e "$CLAUDE_DIR/.mattpocock-skills" )
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR/skills/safe-owned-skill" "$t/outside-sentinel" "$CLAUDE_DIR/skills/nested/name"; printf '../outside-sentinel\n/absolute/path\nnested/name\nnested\\name\n.\n..\nsafe-owned-skill\n' >"$CLAUDE_DIR/.mattpocock-skills"; o="$(cleanup_retired_mattpocock_skills 2>&1)"; check "safe removed" test ! -e "$CLAUDE_DIR/skills/safe-owned-skill"; check "escape preserved" test -e "$t/outside-sentinel"; check "nested preserved" test -e "$CLAUDE_DIR/skills/nested/name"; contains "unsafe warns" "unsafe retired skill manifest entry" "$o" )
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=true; mkdir -p "$CLAUDE_DIR/skills/owned"; printf 'owned\n' >"$CLAUDE_DIR/.mattpocock-skills"; o="$(cleanup_retired_mattpocock_skills 2>&1)"; check "Matt dry-run dir" test -d "$CLAUDE_DIR/skills/owned"; check "Matt dry-run manifest" test -f "$CLAUDE_DIR/.mattpocock-skills"; contains "Matt dry-run skill report" "Would remove retired manifest-owned skill:" "$o"; contains "Matt dry-run manifest report" "Would remove retired skill manifest:" "$o" )
fi
if declare -F cleanup_retired_harness_workflow >/dev/null; then
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR/skills/harness-workflow"; git -C "$DIR" show 385532d^:skills/harness-workflow/SKILL.md >"$CLAUDE_DIR/skills/harness-workflow/SKILL.md"; check "digest exact" test "$(sha256_file "$CLAUDE_DIR/skills/harness-workflow/SKILL.md")" = d897cbfec20f87b553cbbe0f0541a1169f045492881b78b566149d15af1e68ba; cleanup_retired_harness_workflow >/dev/null; check "exact harness removed" test ! -e "$CLAUDE_DIR/skills/harness-workflow" )
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR/skills/harness-workflow"; git -C "$DIR" show 385532d^:skills/harness-workflow/SKILL.md >"$CLAUDE_DIR/skills/harness-workflow/SKILL.md"; printf '\nmodified\n' >>"$CLAUDE_DIR/skills/harness-workflow/SKILL.md"; o="$(cleanup_retired_harness_workflow 2>&1)"; check "modified harness preserved" test -d "$CLAUDE_DIR/skills/harness-workflow"; contains "modified harness warns" "modified or user-authored" "$o" )
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR/skills/harness-workflow"; o="$(cleanup_retired_harness_workflow 2>&1)"; check "missing file preserved" test -d "$CLAUDE_DIR/skills/harness-workflow"; contains "missing file warns" "cannot verify ownership" "$o" )
fi
# Exact managed SKILL.md cleanup must preserve extra user files.
if declare -F cleanup_retired_harness_workflow >/dev/null; then
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR/skills/harness-workflow"; git -C "$DIR" show 385532d^:skills/harness-workflow/SKILL.md >"$CLAUDE_DIR/skills/harness-workflow/SKILL.md"; printf 'user data\n' >"$CLAUDE_DIR/skills/harness-workflow/notes.txt"; o="$(cleanup_retired_harness_workflow 2>&1)"; check "managed harness SKILL removed with extras" test ! -e "$CLAUDE_DIR/skills/harness-workflow/SKILL.md"; check "extra harness file preserved" test -f "$CLAUDE_DIR/skills/harness-workflow/notes.txt"; contains "extra harness content reported" "preserved additional content" "$o" )
fi
# Retired enabledPlugins cleanup runs independently of install_settings.
if declare -F cleanup_retired_enabled_plugins >/dev/null; then
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=false; mkdir -p "$CLAUDE_DIR"; printf '%s\n' '{"enabledPlugins":{"frontend-design@claude-plugins-official":true,"superpowers@claude-plugins-official":true,"user-plugin@example":true}}' >"$CLAUDE_DIR/settings.json"; cleanup_retired_enabled_plugins >/dev/null; check "retired enabled key removed" test "$(jq -r '.enabledPlugins | has("frontend-design@claude-plugins-official")' "$CLAUDE_DIR/settings.json")" = false; check "Superpowers enabled key preserved" test "$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' "$CLAUDE_DIR/settings.json")" = true; check "user enabled key preserved" test "$(jq -r '.enabledPlugins["user-plugin@example"]' "$CLAUDE_DIR/settings.json")" = true )
( t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; CLAUDE_DIR="$t/.claude"; DRY_RUN=true; mkdir -p "$CLAUDE_DIR"; printf '%s\n' '{"enabledPlugins":{"frontend-design@claude-plugins-official":true}}' >"$CLAUDE_DIR/settings.json"; before="$(cat "$CLAUDE_DIR/settings.json")"; o="$(cleanup_retired_enabled_plugins 2>&1)"; check "enabled cleanup dry-run preserves bytes" test "$(cat "$CLAUDE_DIR/settings.json")" = "$before"; contains "enabled cleanup dry-run reports" "Would remove retired enabled plugin:" "$o" )
fi
has frontend-design@claude-plugins-official "${PLUGINS_ESSENTIAL[@]}" "${PLUGINS_OPTIONAL[@]}"&&fail "frontend absent active"||pass "frontend absent active"
check "frontend retired once" test "$(count frontend-design@claude-plugins-official "${RETIRED_PLUGINS[@]}")" = 1
check "frontend removed once" test "$(count frontend-design@claude-plugins-official "${PLUGINS_REMOVED[@]}")" = 1
check "Superpowers essential" has superpowers@claude-plugins-official "${PLUGINS_ESSENTIAL[@]}"
check "ECC optional" has ecc@ecc "${PLUGINS_OPTIONAL[@]}"
build_plugin_catalogue|grep -Fxq frontend-design@claude-plugins-official&&fail "frontend absent catalogue"||pass "frontend absent catalogue"
b="$(<"$DIR/install.sh")"; p="$(<"$DIR/install.ps1")"
for s in INSTALL_MATTPOCOCK MATTPOCOCK_SKILLS install_mattpocock_skills skill-mattpocock skill-harness-workflow plug-frontend-design; do printf %s "$b"|grep -Fq "$s"&&fail "Bash active absent: $s"||pass "Bash active absent: $s"; done
for s in '$MATTPOCOCK_SKILLS' Install-MattpocockSkills doMattpocock skill-mattpocock skill-harness-workflow plug-frontend-design; do printf %s "$p"|grep -Fq "$s"&&fail "PS active absent: $s"||pass "PS active absent: $s"; done
if command -v pwsh >/dev/null; then pwsh -NoLogo -NoProfile -Command '$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $args[0]),[ref]$t,[ref]$e);if($e.Count){exit 1}' "$DIR/install.ps1"&&pass "PowerShell parses"||fail "PowerShell parses"; else echo "SKIP: pwsh not installed; PowerShell behavioral/parser validation unavailable"; fi
echo "----"; echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]

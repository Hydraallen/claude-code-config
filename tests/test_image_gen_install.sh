#!/usr/bin/env bash
# ============================================================
# Installer/augmentation/manifest/uninstall tests for the
# sinedied/agent-skills:image-gen network Skill integration.
#
# Covers plan Tasks 4-5:
#   - _image_gen_npx_cmd / _image_gen_npx: exact command, DO_NOT_TRACK,
#     detached stdin, three retry attempts, transient recovery, final warning
#   - install_image_gen: dry-run writes nothing; missing npx warns + continues;
#     manifest only after wrapper+layout+augment success
#   - image_gen_render_integration_block / image_gen_augment_skill: insert,
#     replace-once, preserve outside bytes, reject missing layout and
#     malformed/duplicate markers, spaced paths
#   - ownership manifest: mode 600, atomic, exact fields
#   - uninstall: valid ownership deletion, stale/wrong manifest, untracked
#     directory, wrapper removal, dry-run preview
#   - always-installed wiring: no menu flag, exactly one ungated call in main
#
# No real HOME, credentials, npx, or network. Fake npx binds nothing and
# records state in a temp dir. No pkill; no background PIDs that outlive runs.
# ============================================================

# Set HOME BEFORE sourcing install.sh so CLAUDE_DIR resolves to a temp dir.
TMP="$(mktemp -d)"
export HOME="$TMP"
export FAKE_HOME="$TMP"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$DIR/install.sh"
# install.sh enables `set -euo pipefail`; relax for assertion ergonomics.
set +euo pipefail

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"; echo "  expected: [$expected]"; echo "  actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (missing: $needle)"; FAIL=$((FAIL + 1))
    fi
}

assert_match_count() {
    local desc="$1" haystack="$2" needle="$3" expected_count="$4"
    local n
    n=$(printf '%s' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || n=0
    if [[ "$n" -eq "$expected_count" ]]; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected $expected_count, got $n)"; FAIL=$((FAIL + 1))
    fi
}

# Speed up retry() by no-op'ing sleep.
sleep() { :; }

# ---- Fake npx factory ----------------------------------------------------
# Creates a fake `npx` on PATH that records calls and optionally fails N times
# before simulating a successful Skill install (writes the image-gen layout).
# Args: [FAIL_N]
make_fake_npx() {
    local fail_n="${1:-0}"
    local bindir="$TMP/bin"
    mkdir -p "$bindir"
    cat > "$bindir/npx" <<NPXEOF
#!/usr/bin/env bash
state="\${FAKE_NPX_STATE:-$TMP/npx_state}"
mkdir -p "\$state"
c=0
[ -f "\$state/calls" ] && c=\$(cat "\$state/calls")
c=\$((c+1))
echo "\$c" > "\$state/calls"
echo "\${DO_NOT_TRACK:-}" > "\$state/dnt"
if [ -t 0 ]; then echo "tty" > "\$state/stdin"; else echo "detached" > "\$state/stdin"; fi
printf '%s\n' "\$*" > "\$state/argv"
if [ "\$c" -le "$fail_n" ]; then
    exit 1
fi
mkdir -p "\$HOME/.claude/skills/image-gen/scripts"
cat > "\$HOME/.claude/skills/image-gen/SKILL.md" <<'MD'
# image-gen

Upstream skill instructions.

\`\`\`
python3 image_gen.py
\`\`\`
MD
cat > "\$HOME/.claude/skills/image-gen/scripts/image_gen.py" <<'PY'
#!/usr/bin/env python3
print("upstream image_gen")
PY
exit 0
NPXEOF
    chmod +x "$bindir/npx"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$bindir:$PATH"
}

install_wrapper() {
    mkdir -p "$CLAUDE_DIR/scripts"
    cp "$DIR/scripts/image-gen-cliproxyapi.sh" "$CLAUDE_DIR/scripts/image-gen-cliproxyapi.sh"
    chmod +x "$CLAUDE_DIR/scripts/image-gen-cliproxyapi.sh"
}

reset_claude_dir() {
    rm -rf "$CLAUDE_DIR"
    mkdir -p "$CLAUDE_DIR"
}

# ============================================================
# Task 4 - exact network command
# ============================================================

if declare -F _image_gen_npx_cmd >/dev/null 2>&1; then
    _image_gen_npx_cmd
    assert_eq "exact npx command array" \
        "npx -y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen" \
        "${_IMAGE_GEN_NPX_CMD[*]}"
    assert_eq "command has exactly one --skill and it is image-gen" \
        "1" \
        "$(printf '%s\n' "${_IMAGE_GEN_NPX_CMD[@]}" | grep -cF -- '--skill')"
    assert_eq "no selectable image-gen flag is declared" \
        "0" \
        "$(grep -cE 'INSTALL_IMAGE_GEN' "$DIR/install.sh" 2>/dev/null)"
else
    echo "FAIL: _image_gen_npx_cmd is not defined"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Task 4 - DO_NOT_TRACK=1 + detached stdin + exact argv recorded by fake npx
# ============================================================

test_dnt_and_stdin() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    assert_eq "DO_NOT_TRACK=1 passed to npx env" "1" "$(cat "$TMP/npx_state/dnt" 2>/dev/null)"
    assert_eq "stdin detached from tty" "detached" "$(cat "$TMP/npx_state/stdin" 2>/dev/null)"
    assert_eq "fake npx received exact argv" \
        "-y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen" \
        "$(cat "$TMP/npx_state/argv" 2>/dev/null)"
}
test_dnt_and_stdin

# ============================================================
# Task 4 - three retry attempts, transient recovery, final warning
# ============================================================

test_transient_recovery() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 2
    local out rc
    out=$(DRY_RUN=false install_image_gen 2>&1); rc=$?
    assert_eq "transient recovery: npx tried exactly 3 times" "3" "$(cat "$TMP/npx_state/calls" 2>/dev/null)"
    assert_eq "transient recovery: install_image_gen returns 0" "0" "$rc"
    if printf '%s' "$out" | grep -q "image-gen Skill installed"; then
        echo "PASS: transient recovery reports success"; PASS=$((PASS + 1))
    else
        echo "FAIL: transient recovery did not report success"; FAIL=$((FAIL + 1))
    fi
}
test_transient_recovery

test_final_warning() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 999
    local rc before after
    before=$INSTALL_WARNINGS
    DRY_RUN=false install_image_gen >/dev/null 2>&1; rc=$?
    after=$INSTALL_WARNINGS
    assert_eq "final failure: npx tried exactly 3 times" "3" "$(cat "$TMP/npx_state/calls" 2>/dev/null)"
    assert_eq "final failure: install_image_gen returns 0 (non-fatal)" "0" "$rc"
    if [[ "$after" -gt "$before" ]]; then
        echo "PASS: final failure increments INSTALL_WARNINGS"; PASS=$((PASS + 1))
    else
        echo "FAIL: final failure did not increment warnings"; FAIL=$((FAIL + 1))
    fi
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: no manifest written after npx failure"; PASS=$((PASS + 1))
    else
        echo "FAIL: manifest written despite npx failure"; FAIL=$((FAIL + 1))
    fi
}
test_final_warning

# ============================================================
# Task 4 - missing npx warns and continues (no manifest)
# ============================================================

test_missing_npx() {
    reset_claude_dir
    install_wrapper
    export PATH="/usr/bin:/bin"
    local rc before after
    before=$INSTALL_WARNINGS
    DRY_RUN=false install_image_gen >/dev/null 2>&1; rc=$?
    after=$INSTALL_WARNINGS
    assert_eq "missing npx: returns 0 (non-fatal)" "0" "$rc"
    if [[ "$after" -gt "$before" ]]; then
        echo "PASS: missing npx increments INSTALL_WARNINGS"; PASS=$((PASS + 1))
    else
        echo "FAIL: missing npx did not increment warnings"; FAIL=$((FAIL + 1))
    fi
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: missing npx writes no manifest"; PASS=$((PASS + 1))
    else
        echo "FAIL: missing npx wrote a manifest"; FAIL=$((FAIL + 1))
    fi
}
test_missing_npx

# ============================================================
# Task 4 - dry-run performs no network call and no HOME writes
# ============================================================

test_dry_run() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    local snap_before snap_after
    snap_before=$(find "$CLAUDE_DIR" -type f 2>/dev/null | sort)
    DRY_RUN=true install_image_gen >/dev/null 2>&1
    snap_after=$(find "$CLAUDE_DIR" -type f 2>/dev/null | sort)
    if [[ ! -f "$TMP/npx_state/calls" ]]; then
        echo "PASS: dry-run made no npx call"; PASS=$((PASS + 1))
    else
        echo "FAIL: dry-run invoked npx"; FAIL=$((FAIL + 1))
    fi
    if [[ "$snap_before" == "$snap_after" ]]; then
        echo "PASS: dry-run wrote no files into CLAUDE_DIR"; PASS=$((PASS + 1))
    else
        echo "FAIL: dry-run changed CLAUDE_DIR file set"; FAIL=$((FAIL + 1))
    fi
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: dry-run wrote no manifest"; PASS=$((PASS + 1))
    else
        echo "FAIL: dry-run wrote a manifest"; FAIL=$((FAIL + 1))
    fi
}
test_dry_run

# ============================================================
# Task 4 - augmentation: render block has canonical content
# ============================================================

if declare -F image_gen_render_integration_block >/dev/null 2>&1; then
    BLOCK_OUT="$(image_gen_render_integration_block)"
    assert_contains "block mentions wrapper script path" "$BLOCK_OUT" "image-gen-cliproxyapi.sh"
    assert_contains "block mentions gpt-image-2" "$BLOCK_OUT" "gpt-image-2"
    assert_contains "block forbids OpenAI Platform key" "$BLOCK_OUT" "OpenAI Platform API key"
    assert_contains "block mentions loopback endpoint" "$BLOCK_OUT" "127.0.0.1:8317"
    assert_contains "block states Windows limitation" "$BLOCK_OUT" "Windows"
else
    echo "FAIL: image_gen_render_integration_block not defined"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Task 4 - augmentation: insert / replace / preserve / reject
# ============================================================

make_skill_layout() {
    local root="$1"
    mkdir -p "$root/image-gen/scripts"
    cat > "$root/image-gen/SKILL.md" <<'MD'
# image-gen

Upstream instructions line A.

```python
python3 image_gen.py generate --prompt "a cat"
```
MD
    echo '#!/usr/bin/env python3' > "$root/image-gen/scripts/image_gen.py"
}

test_augment_insert() {
    local root="$TMP/aug_insert/skills"
    make_skill_layout "$root"
    image_gen_augment_skill "$root" >/dev/null 2>&1
    local md="$root/image-gen/SKILL.md"
    assert_match_count "insert: exactly one BEGIN marker" "$(cat "$md")" "<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->" 1
    assert_match_count "insert: exactly one END marker" "$(cat "$md")" "<!-- END claude-code-config CLIProxyAPI image-gen integration -->" 1
    if grep -q 'Upstream instructions line A.' "$md"; then
        echo "PASS: insert: upstream content preserved"; PASS=$((PASS + 1))
    else
        echo "FAIL: insert: upstream content lost"; FAIL=$((FAIL + 1))
    fi
}
test_augment_insert

test_augment_replace_once() {
    local root="$TMP/aug_replace/skills"
    make_skill_layout "$root"
    image_gen_augment_skill "$root" >/dev/null 2>&1
    image_gen_augment_skill "$root" >/dev/null 2>&1
    local md="$root/image-gen/SKILL.md"
    assert_match_count "replace: still exactly one BEGIN marker" "$(cat "$md")" "<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->" 1
    assert_match_count "replace: still exactly one END marker" "$(cat "$md")" "<!-- END claude-code-config CLIProxyAPI image-gen integration -->" 1
}
test_augment_replace_once

test_augment_preserve_outside() {
    local root="$TMP/aug_pres/skills"
    make_skill_layout "$root"
    image_gen_augment_skill "$root" >/dev/null 2>&1
    local md="$root/image-gen/SKILL.md"
    if grep -qF 'Upstream instructions line A.' "$md" && grep -qF 'python3 image_gen.py generate --prompt "a cat"' "$md"; then
        echo "PASS: preserve: outside bytes intact after augment"; PASS=$((PASS + 1))
    else
        echo "FAIL: preserve: outside bytes changed"; FAIL=$((FAIL + 1))
    fi
}
test_augment_preserve_outside

test_augment_replace_preserves_user_outside_change() {
    local root="$TMP/aug_user/skills"
    make_skill_layout "$root"
    image_gen_augment_skill "$root" >/dev/null 2>&1
    local md="$root/image-gen/SKILL.md"
    python3 - "$md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("Upstream instructions line A.", "Upstream instructions line A.\n\nUser-added note outside markers.")
open(p, "w").write(s)
PY
    image_gen_augment_skill "$root" >/dev/null 2>&1
    if grep -qF "User-added note outside markers." "$md"; then
        echo "PASS: replace preserves user content outside markers"; PASS=$((PASS + 1))
    else
        echo "FAIL: replace clobbered user content outside markers"; FAIL=$((FAIL + 1))
    fi
    assert_match_count "user-change re-augment: one BEGIN" "$(cat "$md")" "<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->" 1
}
test_augment_replace_preserves_user_outside_change

test_augment_reject_missing_layout() {
    local root="$TMP/aug_missing/skills"
    mkdir -p "$root/image-gen"
    local rc
    image_gen_augment_skill "$root" >/dev/null 2>&1; rc=$?
    assert_eq "reject: missing SKILL.md returns 1" "1" "$rc"
    echo "# image-gen" > "$root/image-gen/SKILL.md"
    image_gen_augment_skill "$root" >/dev/null 2>&1; rc=$?
    assert_eq "reject: missing image_gen.py returns 1" "1" "$rc"
}
test_augment_reject_missing_layout

test_augment_reject_duplicate_markers() {
    local root="$TMP/aug_dup/skills"
    make_skill_layout "$root"
    local md="$root/image-gen/SKILL.md"
    printf '\n<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->\n<!-- END claude-code-config CLIProxyAPI image-gen integration -->\n' >> "$md"
    printf '\n<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->\n<!-- END claude-code-config CLIProxyAPI image-gen integration -->\n' >> "$md"
    local rc
    image_gen_augment_skill "$root" >/dev/null 2>&1; rc=$?
    assert_eq "reject: duplicate markers returns 1" "1" "$rc"
}
test_augment_reject_duplicate_markers

test_augment_reject_mismatched_markers() {
    local root="$TMP/aug_mis/skills"
    make_skill_layout "$root"
    local md="$root/image-gen/SKILL.md"
    printf '\n<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->\n' >> "$md"
    local rc
    image_gen_augment_skill "$root" >/dev/null 2>&1; rc=$?
    assert_eq "reject: mismatched markers returns 1" "1" "$rc"
}
test_augment_reject_mismatched_markers

test_augment_spaced_path() {
    local root="$TMP/with space dir/skills"
    make_skill_layout "$root"
    local rc
    image_gen_augment_skill "$root" >/dev/null 2>&1; rc=$?
    assert_eq "spaced path: augment returns 0" "0" "$rc"
    assert_match_count "spaced path: one BEGIN marker" "$(cat "$root/image-gen/SKILL.md")" "<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->" 1
}
test_augment_spaced_path

# ============================================================
# Task 4 - manifest: written mode 600, only after full success
# ============================================================

test_manifest_success() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    local m="$CLAUDE_DIR/.image-gen-sinedied"
    if [[ -f "$m" ]]; then
        echo "PASS: manifest exists after success"; PASS=$((PASS + 1))
    else
        echo "FAIL: manifest missing after success"; FAIL=$((FAIL + 1)); return
    fi
    local mode
    mode=$(stat -f "%Lp" "$m" 2>/dev/null || stat -c "%a" "$m" 2>/dev/null)
    assert_eq "manifest mode is 600" "600" "$mode"
    assert_eq "manifest skill field" "image-gen" "$(grep -E '^skill=' "$m" | sed 's/^skill=//')"
    assert_eq "manifest source field" "sinedied/agent-skills" "$(grep -E '^source=' "$m" | sed 's/^source=//')"
    assert_eq "manifest wrapper field" "image-gen-cliproxyapi.sh" "$(grep -E '^wrapper=' "$m" | sed 's/^wrapper=//')"
}
test_manifest_success

test_manifest_not_written_when_wrapper_missing() {
    reset_claude_dir
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: no manifest when wrapper missing"; PASS=$((PASS + 1))
    else
        echo "FAIL: manifest written despite missing wrapper"; FAIL=$((FAIL + 1))
    fi
}

# ============================================================
# Regression: real upstream layout is scripts/image_gen.py
# The `skills` CLI installs ~/.claude/skills/image-gen/scripts/image_gen.py
# (a scripts/ subdir), NOT a root image_gen.py. A fake npx that creates the
# real upstream structure must yield a successful install + manifest + augmented
# SKILL.md. Failure means the installer/augment still expects root image_gen.py
# and rejects the real layout, cleaning a successful download.
# ============================================================
test_upstream_scripts_layout() {
    reset_claude_dir
    install_wrapper
    # Fake npx creating the REAL upstream layout: scripts/image_gen.py.
    local bindir="$TMP/bin"
    mkdir -p "$bindir"
    cat > "$bindir/npx" <<'NPXEOF'
#!/usr/bin/env bash
mkdir -p "$HOME/.claude/skills/image-gen/scripts"
cat > "$HOME/.claude/skills/image-gen/SKILL.md" <<'MD'
# image-gen

Upstream skill instructions.
MD
cat > "$HOME/.claude/skills/image-gen/scripts/image_gen.py" <<'PY'
#!/usr/bin/env python3
print("upstream image_gen")
PY
exit 0
NPXEOF
    chmod +x "$bindir/npx"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$bindir:$PATH"
    local out rc
    out=$(DRY_RUN=false install_image_gen 2>&1); rc=$?
    assert_eq "upstream-scripts-layout: install_image_gen returns 0" "0" "$rc"
    if [[ -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: upstream-scripts-layout: manifest written"; PASS=$((PASS + 1))
    else
        echo "FAIL: upstream-scripts-layout: manifest missing (install rejected real layout)"; FAIL=$((FAIL + 1))
    fi
    if [[ -f "$CLAUDE_DIR/skills/image-gen/scripts/image_gen.py" ]]; then
        echo "PASS: upstream-scripts-layout: scripts/image_gen.py present after install"; PASS=$((PASS + 1))
    else
        echo "FAIL: upstream-scripts-layout: scripts/image_gen.py cleaned up by failed install"; FAIL=$((FAIL + 1))
    fi
    if grep -q 'BEGIN claude-code-config CLIProxyAPI image-gen integration' \
        "$CLAUDE_DIR/skills/image-gen/SKILL.md" 2>/dev/null; then
        echo "PASS: upstream-scripts-layout: SKILL.md augmented"; PASS=$((PASS + 1))
    else
        echo "FAIL: upstream-scripts-layout: SKILL.md not augmented"; FAIL=$((FAIL + 1))
    fi
}
test_upstream_scripts_layout
test_manifest_not_written_when_wrapper_missing

test_manifest_not_written_when_augment_fails() {
    reset_claude_dir
    install_wrapper
    # Custom fake npx that writes SKILL.md but NOT image_gen.py -> augment fails.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
state="$FAKE_NPX_STATE"
mkdir -p "$state"
c=0; [ -f "$state/calls" ] && c=$(cat "$state/calls"); c=$((c+1)); echo "$c" > "$state/calls"
mkdir -p "$HOME/.claude/skills/image-gen"
echo "# image-gen" > "$HOME/.claude/skills/image-gen/SKILL.md"
exit 0
NPXEOF
    chmod +x "$TMP/bin/npx"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$TMP/bin:$PATH"
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: no manifest when augmentation fails"; PASS=$((PASS + 1))
    else
        echo "FAIL: manifest written despite augmentation failure"; FAIL=$((FAIL + 1))
    fi
}
test_manifest_not_written_when_augment_fails

# ============================================================
# Task 4 - wrapper registered in USER_SCRIPTS
# ============================================================

if printf '%s\n' "${USER_SCRIPTS[@]}" | grep -qF -- 'image-gen-cliproxyapi.sh'; then
    echo "PASS: wrapper is in USER_SCRIPTS"; PASS=$((PASS + 1))
else
    echo "FAIL: wrapper missing from USER_SCRIPTS"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Task 4 - always-installed wiring: no menu flag, one ungated call, no early-exit
# ============================================================

test_main_wiring() {
    local flag_hits
    flag_hits=$(grep -cE 'INSTALL_IMAGE_GEN' "$DIR/install.sh" 2>/dev/null) || flag_hits=0
    assert_eq "no INSTALL_IMAGE_GEN flag declared" "0" "$flag_hits"

    # Count call sites: a line whose first non-space token is install_image_gen
    # but NOT the function definition (which is followed by "()"). The negated
    # char class excludes '(', letters, '_', so only a bare call matches.
    local call_sites
    call_sites=$(grep -cE '^[[:space:]]*install_image_gen([^()a-zA-Z_]|$)' "$DIR/install.sh" 2>/dev/null) || call_sites=0
    assert_eq "exactly one install_image_gen call site (excluding definition)" \
        "1" "$call_sites"

    local gated
    gated=$(grep -E '\$[A-Z_]+ && install_image_gen' "$DIR/install.sh" 2>/dev/null) || gated=""
    assert_eq "install_image_gen is not behind a flag gate" "" "$gated"

    if grep -q 'Nothing selected to install' "$DIR/install.sh" 2>/dev/null; then
        echo "FAIL: 'Nothing selected' early-exit still present (would block always-install)"; FAIL=$((FAIL + 1))
    else
        echo "PASS: 'Nothing selected' early-exit removed"; PASS=$((PASS + 1))
    fi
}
test_main_wiring

# ============================================================
# Task 4 - real subprocess execution of install.sh (review #7)
# ============================================================
# NOTE on "essential" (review #6): the plan's Task 4 mentions an "essential"
# install mode, but the installer exposes no `--essential` CLI flag. That term
# maps to the existing PLUGINS_ESSENTIAL grouping (a plugin-group token used by
# --all/implicit selection), NOT a CLI entry mode. The real supported entry
# paths exercised here are: `--all --force`, `--dry-run --all`, and the
# default noninteractive path (no args + no TTY collapses to INSTALL_ALL, which
# is functionally equivalent to `--all` for image-gen). The two-level curses
# interactive menu requires a real pty (impractical inside this POSIX test
# harness), so interactive all-off is covered by the static assertions above
# (no INSTALL_IMAGE_GEN flag, no "Nothing selected" early-exit, one ungated
# call site) together with the unit-level main() simulation below, which sets
# every selectable flag false and still observes exactly one image-gen call.

# Build a fake-npx/fake-claude/fake-git/fake-curl/fake-wget PATH and run the
# real install.sh as a subprocess. Sets globals IG_NPX_CALLS, IG_NPX_ARGV,
# IG_WRAPPER_AT_NPX, IG_MANIFEST, IG_HOME for assertions.
run_real_install() {
    local invocation="$1"           # e.g. "--all --force"
    local fake_home; fake_home=$(mktemp -d)
    local bindir="$fake_home/bin"
    mkdir -p "$bindir"
    # Fake npx: records each call; for image-gen, records whether the wrapper
    # was already installed at call time and creates the Skill layout.
    cat > "$bindir/npx" <<NPXEOF
#!/usr/bin/env bash
state="$fake_home/npx_state"
mkdir -p "\$state"
printf '%s\n' "\$*" >> "\$state/argv_all"
echo "\${DO_NOT_TRACK:-}" >> "\$state/dnt_all"
# wrapper-before-network: record whether the wrapper exists at npx call time.
if [[ -x "\$HOME/.claude/scripts/image-gen-cliproxyapi.sh" ]]; then
  echo "yes" >> "\$state/wrapper_at_npx"
else
  echo "no"  >> "\$state/wrapper_at_npx"
fi
if printf '%s\n' "\$@" | grep -q 'sinedied/agent-skills'; then
  mkdir -p "\$HOME/.claude/skills/image-gen/scripts"
  printf '# image-gen\n\nUpstream content.\n' > "\$HOME/.claude/skills/image-gen/SKILL.md"
  printf '#!/usr/bin/env python3\n' > "\$HOME/.claude/skills/image-gen/scripts/image_gen.py"
fi
exit 0
NPXEOF
    chmod +x "$bindir/npx"
    # Fake claude: plugin/mcp ops succeed silently without any network.
    cat > "$bindir/claude" <<'CLIEOF'
#!/usr/bin/env bash
exit 0
CLIEOF
    chmod +x "$bindir/claude"
    # Fake git: deepxiv clone creates an empty target dir (no skills/ inside).
    cat > "$bindir/git" <<'GITEOF'
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then
  last="${!#}"
  mkdir -p "$last"
fi
exit 0
GITEOF
    chmod +x "$bindir/git"
    # Fake curl/wget: never reach the network.
    cat > "$bindir/curl" <<'CURL'
#!/usr/bin/env bash
exit 0
CURL
    chmod +x "$bindir/curl"
    cat > "$bindir/wget" <<'WGET'
#!/usr/bin/env bash
exit 0
WGET
    chmod +x "$bindir/wget"

    rm -rf "$fake_home/npx_state"; mkdir -p "$fake_home/npx_state"
    # Run the REAL install.sh as a subprocess. HOME is the fake home; PATH
    # shadows npx/claude/git/curl/wget. stdin=/dev/null, stdout/stderr captured.
    env -u CLAUDE_CODE_ENTRYPOINT HOME="$fake_home" PATH="$bindir:/usr/bin:/bin" \
        bash "$DIR/install.sh" $invocation >/tmp/ig_subproc.out 2>&1
    local rc=$?
    IG_RC=$rc
    IG_HOME="$fake_home"
    IG_NPX_CALLS=$(grep -c 'sinedied/agent-skills' "$fake_home/npx_state/argv_all" 2>/dev/null || echo 0)
    IG_NPX_ARGV=$(grep 'sinedied/agent-skills' "$fake_home/npx_state/argv_all" 2>/dev/null | head -1)
    IG_WRAPPER_AT_NPX=$(head -1 "$fake_home/npx_state/wrapper_at_npx" 2>/dev/null || echo "no")
    IG_DNT=$(head -1 "$fake_home/npx_state/dnt_all" 2>/dev/null || echo "")
    IG_OUT="$(cat /tmp/ig_subproc.out)"
}

cleanup_subprocess_home() {
    [[ -n "${IG_HOME:-}" && -d "${IG_HOME:-}" ]] && rm -rf "$IG_HOME"
    IG_HOME=""
}

# --- real `--all --force`: image-gen installed exactly once, argv exact, ---
# --- wrapper present before network, manifest canonical, summary present ---
run_real_install "--all --force"
assert_eq "subprocess --all: npx image-gen called exactly once" "1" "$IG_NPX_CALLS"
assert_eq "subprocess --all: exact npx argv" \
    "-y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen" \
    "$IG_NPX_ARGV"
assert_eq "subprocess --all: DO_NOT_TRACK=1 in npx env" "1" "$IG_DNT"
assert_eq "subprocess --all: wrapper installed before npx ran (wrapper-before-network)" "yes" "$IG_WRAPPER_AT_NPX"
if [[ -f "$IG_HOME/.claude/.image-gen-sinedied" ]]; then
    echo "PASS: subprocess --all: manifest exists"; PASS=$((PASS + 1))
else
    echo "FAIL: subprocess --all: manifest missing"; FAIL=$((FAIL + 1))
fi
# Manifest must be the exact canonical bytes.
if printf '%s\n' "$_IMAGE_GEN_MANIFEST_CANONICAL" 2>/dev/null | cmp -s - "$IG_HOME/.claude/.image-gen-sinedied" 2>/dev/null \
   || _image_gen_manifest_valid "$IG_HOME/.claude/.image-gen-sinedied" 2>/dev/null; then
    echo "PASS: subprocess --all: manifest canonical"; PASS=$((PASS + 1))
else
    echo "FAIL: subprocess --all: manifest not canonical"; FAIL=$((FAIL + 1))
fi
if grep -q 'BEGIN claude-code-config CLIProxyAPI image-gen integration' "$IG_HOME/.claude/skills/image-gen/SKILL.md" 2>/dev/null; then
    echo "PASS: subprocess --all: SKILL.md augmented"; PASS=$((PASS + 1))
else
    echo "FAIL: subprocess --all: SKILL.md not augmented"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$IG_OUT" | grep -qi 'image-gen'; then
    echo "PASS: subprocess --all: summary mentions image-gen"; PASS=$((PASS + 1))
else
    echo "FAIL: subprocess --all: summary omits image-gen"; FAIL=$((FAIL + 1))
fi
# No real network escape: the fake npx shadowed the real one (PATH resolved to
# the fake bin). Assert the resolved npx path is inside the fake home.
command -v npx >/dev/null 2>&1 || true
cleanup_subprocess_home

# --- unit-level main() simulation: all-selectable-off still calls image-gen ---
# (complementary to the subprocess test; covers the interactive all-off path
# which needs a pty to drive for real.)
test_all_off_unit() {
    (
        tmp=$(mktemp -d); export HOME="$tmp"
        source "$DIR/install.sh" 2>/dev/null
        set +euo pipefail
        for fn in install_claude_md install_settings install_rules install_skills \
                  install_agents install_lessons \
                  install_statusline install_mcp install_plugins install_deepxiv \
                  install_shell_wrapper configure_gpt_backend configure_ccr_profile \
                  choose_default_profile prune_retired_plugins prune_unlisted_plugins \
                  update_installed_plugins run_cleanup stamp_version \
                  shell_wrapper_source_hint backend_setup_hints cl_commands_hint \
                  install_nerd_font install_jq; do
            eval "$fn() { :; }"
        done
        counter="$tmp/ig_calls"
        install_image_gen() { echo x >> "$counter"; }
        SCRIPT_DIR="$tmp"; export SCRIPT_DIR
        INSTALL_CLAUDE_MD=false; INSTALL_SETTINGS=false; INSTALL_RULES=false
        INSTALL_SKILLS=false; INSTALL_AGENTS=false
        INSTALL_LESSONS=false; INSTALL_STATUSLINE=false; INSTALL_SHELL_WRAPPER=false
        INSTALL_PLUGINS=false; INSTALL_MCP=false; INSTALL_LARK=false; INSTALL_DEEPXIV=false
        main >/dev/null 2>&1
        wc -l < "$counter" 2>/dev/null | tr -d ' ' || echo 0
        rm -rf "$tmp"
    )
}
assert_eq "unit: all-selectable-off still calls install_image_gen exactly once" \
    "1" "$(test_all_off_unit)"

# ============================================================
# Task 5 - ownership-safe uninstall: manifest validation (pure)
# ============================================================

if declare -F _image_gen_manifest_valid >/dev/null 2>&1; then
    valid_m="$TMP/valid.manifest"
    printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' > "$valid_m"
    if _image_gen_manifest_valid "$valid_m"; then
        echo "PASS: valid manifest validates"; PASS=$((PASS + 1))
    else
        echo "FAIL: valid manifest rejected"; FAIL=$((FAIL + 1))
    fi
    bad1="$TMP/bad1.manifest"; printf 'skill=other\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' > "$bad1"
    if _image_gen_manifest_valid "$bad1"; then echo "FAIL: wrong skill accepted"; FAIL=$((FAIL + 1)); else echo "PASS: wrong skill rejected"; PASS=$((PASS + 1)); fi
    bad2="$TMP/bad2.manifest"; printf 'skill=image-gen\nsource=other/repo\nwrapper=image-gen-cliproxyapi.sh\n' > "$bad2"
    if _image_gen_manifest_valid "$bad2"; then echo "FAIL: wrong source accepted"; FAIL=$((FAIL + 1)); else echo "PASS: wrong source rejected"; PASS=$((PASS + 1)); fi
    bad3="$TMP/bad3.manifest"; printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=other.sh\n' > "$bad3"
    if _image_gen_manifest_valid "$bad3"; then echo "FAIL: wrong wrapper accepted"; FAIL=$((FAIL + 1)); else echo "PASS: wrong wrapper rejected"; PASS=$((PASS + 1)); fi
    bad4="$TMP/bad4.manifest"; printf 'skill=image-gen\n' > "$bad4"
    if _image_gen_manifest_valid "$bad4"; then echo "FAIL: malformed manifest accepted"; FAIL=$((FAIL + 1)); else echo "PASS: malformed manifest rejected"; PASS=$((PASS + 1)); fi
else
    echo "FAIL: _image_gen_manifest_valid not defined"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Task 5 - uninstall integration: ownership-gated directory removal
# ============================================================

run_uninstall_case() {
    local manifest_content="$1" expect="$2"
    (
        tmp=$(mktemp -d); export HOME="$tmp"
        source "$DIR/install.sh" 2>/dev/null
        set +euo pipefail
        claude() { return 0; }
        # Production main() calls detect_script_dir() before uninstall(); mirror
        # that by setting SCRIPT_DIR and giving it a skills/ dir (the repo always
        # has one). Without SCRIPT_DIR set, the generic skills cleanup falls back
        # to `rm -rf skills/` and nukes image-gen regardless of ownership.
        SCRIPT_DIR="$tmp"; export SCRIPT_DIR
        mkdir -p "$tmp/skills"
        mkdir -p "$CLAUDE_DIR/skills/image-gen"
        # When the caller marks the fixture owned, plant both markers so the
        # full ownership proof (markers + valid manifest) accepts it.
        if [[ "$3" == "owned" ]]; then
            printf '# image-gen\n\n%s\nmanaged block\n%s\n' \
                "$IMAGE_GEN_BEGIN_MARKER" "$IMAGE_GEN_END_MARKER" \
                > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
        else
            echo "# user-authored" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
        fi
        [[ -n "$manifest_content" ]] && printf '%s' "$manifest_content" > "$CLAUDE_DIR/.image-gen-sinedied"
        mkdir -p "$CLAUDE_DIR/scripts"
        echo '#!/usr/bin/env bash' > "$CLAUDE_DIR/scripts/image-gen-cliproxyapi.sh"

        FORCE=true DRY_RUN=false uninstall >/dev/null 2>&1
        if [[ "$expect" == "removed" ]]; then
            { [[ ! -d "$CLAUDE_DIR/skills/image-gen" ]] && [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; } && echo "REMOVED" || echo "KEPT"
        else
            [[ -d "$CLAUDE_DIR/skills/image-gen" ]] && echo "KEPT" || echo "REMOVED"
        fi
        rm -rf "$tmp"
    )
}

assert_eq "uninstall: valid manifest + markers -> removed" \
    "REMOVED" \
    "$(run_uninstall_case 'skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-cliproxyapi.sh
' removed owned)"
# Valid manifest but NO markers -> not fully owned -> dir preserved, manifest pruned.
assert_eq "uninstall: valid manifest without markers -> dir KEPT" \
    "KEPT" \
    "$(run_uninstall_case 'skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-cliproxyapi.sh
' kept)"
assert_eq "uninstall: wrong-source manifest -> KEPT" \
    "KEPT" \
    "$(run_uninstall_case 'skill=image-gen
source=other/repo
wrapper=image-gen-cliproxyapi.sh
' kept)"
assert_eq "uninstall: malformed manifest -> KEPT" \
    "KEPT" \
    "$(run_uninstall_case 'skill=image-gen
' kept)"
assert_eq "uninstall: no manifest (untracked) -> KEPT" \
    "KEPT" \
    "$(run_uninstall_case '' kept)"

# ============================================================
# Task 5 - dry-run uninstall preview does not delete + mentions image-gen
# ============================================================

test_uninstall_dry_run() {
    (
        tmp=$(mktemp -d); export HOME="$tmp"
        source "$DIR/install.sh" 2>/dev/null
        set +euo pipefail
        claude() { return 0; }
        SCRIPT_DIR="$tmp"; export SCRIPT_DIR
        mkdir -p "$tmp/skills"
        mkdir -p "$CLAUDE_DIR/skills/image-gen"
        echo "# upstream" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
        printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' > "$CLAUDE_DIR/.image-gen-sinedied"
        local out
        out=$(FORCE=true DRY_RUN=true uninstall 2>&1)
        local kept="yes"
        { [[ -d "$CLAUDE_DIR/skills/image-gen" ]] && [[ -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; } || kept="no"
        echo "$kept"
        printf '%s' "$out" | grep -qi 'image-gen' && echo "preview-mentions-image-gen" || echo "preview-missing-image-gen"
        rm -rf "$tmp"
    )
}

DR_OUT="$(test_uninstall_dry_run)"
assert_eq "uninstall dry-run: skill + manifest preserved" "yes" "$(printf '%s\n' "$DR_OUT" | head -1)"
if printf '%s' "$DR_OUT" | grep -q 'preview-mentions-image-gen'; then
    echo "PASS: uninstall dry-run preview mentions image-gen"; PASS=$((PASS + 1))
else
    echo "FAIL: uninstall dry-run preview does not mention image-gen"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Review #2 - top-level dry-run subprocess writes NOTHING (hermetic)
# ============================================================
test_dry_run_subprocess() {
    local fake_home; fake_home=$(mktemp -d)
    local bindir="$fake_home/bin"
    mkdir -p "$bindir"
    # Fake externals so NO real network/binary can run.
    for cmd in npx claude git curl wget; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$bindir/$cmd"
        chmod +x "$bindir/$cmd"
    done
    env -u CLAUDE_CODE_ENTRYPOINT HOME="$fake_home" PATH="$bindir:/usr/bin:/bin" \
        bash "$DIR/install.sh" --dry-run --all >/tmp/ig_dr.out 2>&1
    local rc=$?
    # No npx invocation recorded.
    local npx_called="no"
    [[ -f "$fake_home/npx_state" ]] && npx_called="yes"
    # HOME must contain NO files/dirs created by the installer (only the bin
    # stubs we made ourselves, which live under $fake_home/bin).
    local created
    created=$(find "$fake_home" -mindepth 1 ! -path "$fake_home/bin/*" ! -path "$fake_home/bin" -print 2>/dev/null | head -1)
    IG_DR_HOME="$fake_home"
    echo "rc=$rc npx_called=$npx_called created=[${created:-}]"
}
DR_SUB="$(test_dry_run_subprocess)"
rm -rf "${IG_DR_HOME:-}"
if printf '%s' "$DR_SUB" | grep -q 'npx_called=no'; then
    echo "PASS: dry-run --all subprocess invokes no npx"; PASS=$((PASS + 1))
else
    echo "FAIL: dry-run --all subprocess invoked npx"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$DR_SUB" | grep -q 'created=\[\]'; then
    echo "PASS: dry-run --all subprocess creates/writes nothing in HOME"; PASS=$((PASS + 1))
else
    echo "FAIL: dry-run --all subprocess wrote to HOME:"; printf '%s\n' "$DR_SUB"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Review #3 - embedded marker text rejected
# ============================================================
test_augment_reject_embedded() {
    local root="$TMP/aug_embed/skills"
    mkdir -p "$root/image-gen/scripts"
    printf '# image-gen\n\nsome text %s more text\n' "$IMAGE_GEN_BEGIN_MARKER" > "$root/image-gen/SKILL.md"
    echo '#!/usr/bin/env python3' > "$root/image-gen/scripts/image_gen.py"
    local rc
    image_gen_augment_skill "$root" >/dev/null 2>&1; rc=$?
    assert_eq "embedded marker text rejected (returns 1)" "1" "$rc"
}
test_augment_reject_embedded

# ============================================================
# Review #4 - transactional upgrade semantics
# ============================================================

test_transactional_restore_on_npx_failure() {
    reset_claude_dir
    install_wrapper
    # First: a successful install (prior valid ownership).
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    local prior_md="$CLAUDE_DIR/skills/image-gen/SKILL.md"
    echo "PRIOR-MARKER-CONTENT" >> "$prior_md"
    # Now a re-install where npx ALWAYS fails: prior skill+manifest must survive.
    make_fake_npx 999
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if [[ -f "$prior_md" ]] && grep -q 'PRIOR-MARKER-CONTENT' "$prior_md"; then
        echo "PASS: transactional: prior SKILL.md restored on npx failure"; PASS=$((PASS + 1))
    else
        echo "FAIL: transactional: prior SKILL.md lost on npx failure"; FAIL=$((FAIL + 1))
    fi
    if _image_gen_manifest_valid "$CLAUDE_DIR/.image-gen-sinedied"; then
        echo "PASS: transactional: prior manifest restored on npx failure"; PASS=$((PASS + 1))
    else
        echo "FAIL: transactional: prior manifest lost on npx failure"; FAIL=$((FAIL + 1))
    fi
}
test_transactional_restore_on_npx_failure

test_transactional_restore_on_augment_failure() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    local prior_md="$CLAUDE_DIR/skills/image-gen/SKILL.md"
    echo "PRIOR-AUG-CONTENT" >> "$prior_md"
    # Re-install: npx wipes the dir and writes a layout WITHOUT image_gen.py,
    # so augmentation must fail and the prior install must be restored.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
rm -rf "$HOME/.claude/skills/image-gen"
mkdir -p "$HOME/.claude/skills/image-gen"
echo "# image-gen" > "$HOME/.claude/skills/image-gen/SKILL.md"
exit 0
NPXEOF
    chmod +x "$TMP/bin/npx"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$TMP/bin:$PATH"
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if [[ -f "$prior_md" ]] && grep -q 'PRIOR-AUG-CONTENT' "$prior_md"; then
        echo "PASS: transactional: prior SKILL.md restored on augment failure"; PASS=$((PASS + 1))
    else
        echo "FAIL: transactional: prior SKILL.md lost on augment failure"; FAIL=$((FAIL + 1))
    fi
}
test_transactional_restore_on_augment_failure

test_unowned_dir_not_overwritten() {
    reset_claude_dir
    install_wrapper
    # Pre-existing user-authored image-gen dir with NO manifest.
    mkdir -p "$CLAUDE_DIR/skills/image-gen"
    echo "USER-AUTHORED" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if grep -q 'USER-AUTHORED' "$CLAUDE_DIR/skills/image-gen/SKILL.md" 2>/dev/null; then
        echo "PASS: unowned: user dir not overwritten"; PASS=$((PASS + 1))
    else
        echo "FAIL: unowned: user dir overwritten"; FAIL=$((FAIL + 1))
    fi
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: unowned: no manifest written for user dir"; PASS=$((PASS + 1))
    else
        echo "FAIL: unowned: manifest written for user dir"; FAIL=$((FAIL + 1))
    fi
}
test_unowned_dir_not_overwritten

test_fresh_failure_cleans_up() {
    reset_claude_dir
    install_wrapper
    # npx succeeds but augment fails (no image_gen.py) -> fresh target must not
    # leave a half-installed unowned directory or a manifest.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
mkdir -p "$HOME/.claude/skills/image-gen"
echo "# image-gen" > "$HOME/.claude/skills/image-gen/SKILL.md"
exit 0
NPXEOF
    chmod +x "$TMP/bin/npx"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$TMP/bin:$PATH"
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if [[ ! -d "$CLAUDE_DIR/skills/image-gen" ]]; then
        echo "PASS: fresh failure: half-installed dir removed"; PASS=$((PASS + 1))
    else
        echo "FAIL: fresh failure: half-installed dir lingers"; FAIL=$((FAIL + 1))
    fi
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: fresh failure: no manifest left"; PASS=$((PASS + 1))
    else
        echo "FAIL: fresh failure: manifest left"; FAIL=$((FAIL + 1))
    fi
}
test_fresh_failure_cleans_up

# ============================================================
# Review #5 - exact-byte manifest validator (strict)
# ============================================================
test_manifest_strict() {
    local m="$TMP/strict.manifest"
    local canon="skill=image-gen
source=sinedied/agent-skills
wrapper=image-gen-cliproxyapi.sh"
    # Exact canonical (one trailing newline) -> valid.
    printf '%s\n' "$canon" > "$m"
    if _image_gen_manifest_valid "$m"; then echo "PASS: strict: canonical valid"; PASS=$((PASS + 1)); else echo "FAIL: strict: canonical rejected"; FAIL=$((FAIL + 1)); fi
    # CRLF -> reject.
    printf 'skill=image-gen\r\nsource=sinedied/agent-skills\r\nwrapper=image-gen-cliproxyapi.sh\r\n' > "$m"
    if _image_gen_manifest_valid "$m"; then echo "FAIL: strict: CRLF accepted"; FAIL=$((FAIL + 1)); else echo "PASS: strict: CRLF rejected"; PASS=$((PASS + 1)); fi
    # Extra line -> reject.
    printf '%s\nextra=line\n' "$canon" > "$m"
    if _image_gen_manifest_valid "$m"; then echo "FAIL: strict: extra line accepted"; FAIL=$((FAIL + 1)); else echo "PASS: strict: extra line rejected"; PASS=$((PASS + 1)); fi
    # Reordered -> reject.
    printf 'source=sinedied/agent-skills\nskill=image-gen\nwrapper=image-gen-cliproxyapi.sh\n' > "$m"
    if _image_gen_manifest_valid "$m"; then echo "FAIL: strict: reordered accepted"; FAIL=$((FAIL + 1)); else echo "PASS: strict: reordered rejected"; PASS=$((PASS + 1)); fi
    # Duplicate line -> reject.
    printf 'skill=image-gen\nskill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' > "$m"
    if _image_gen_manifest_valid "$m"; then echo "FAIL: strict: duplicate accepted"; FAIL=$((FAIL + 1)); else echo "PASS: strict: duplicate rejected"; PASS=$((PASS + 1)); fi
    # Missing trailing newline -> reject.
    printf '%s' "$canon" > "$m"
    if _image_gen_manifest_valid "$m"; then echo "FAIL: strict: missing-newline accepted"; FAIL=$((FAIL + 1)); else echo "PASS: strict: missing-newline rejected"; PASS=$((PASS + 1)); fi
}
test_manifest_strict

# ============================================================
# Fix round 2 / review #1 - stale manifest reconciled before early returns
# ============================================================

test_stale_manifest_missing_npx_cleaned() {
    # Stale valid manifest + absent skill dir + missing npx. The installer must
    # invalidate the manifest BEFORE the missing-npx early return. Then a user
    # creating the dir themselves is safe: uninstall must preserve it.
    reset_claude_dir
    install_wrapper
    # Plant a valid manifest with NO skill directory.
    printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' \
        > "$CLAUDE_DIR/.image-gen-sinedied"
    # No npx on PATH.
    export PATH="/usr/bin:/bin"
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if [[ ! -f "$CLAUDE_DIR/.image-gen-sinedied" ]]; then
        echo "PASS: stale manifest removed before missing-npx return"; PASS=$((PASS + 1))
    else
        echo "FAIL: stale manifest survived missing-npx return"; FAIL=$((FAIL + 1))
    fi
    # Now the user creates the directory themselves.
    mkdir -p "$CLAUDE_DIR/skills/image-gen"
    echo "USER-CREATED" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    # Uninstall must preserve it (no manifest authorizes deletion).
    SCRIPT_DIR="$TMP"; export SCRIPT_DIR
    mkdir -p "$TMP/skills"
    FORCE=true DRY_RUN=false uninstall >/dev/null 2>&1
    if grep -q 'USER-CREATED' "$CLAUDE_DIR/skills/image-gen/SKILL.md" 2>/dev/null; then
        echo "PASS: stale-manifest scenario: user-created dir preserved by uninstall"; PASS=$((PASS + 1))
    else
        echo "FAIL: stale-manifest scenario: user dir deleted by uninstall"; FAIL=$((FAIL + 1))
    fi
}
test_stale_manifest_missing_npx_cleaned

# Unowned dir + stale valid manifest: the manifest must NOT authorize
# overwriting an unowned directory. (Reconciliation removes a manifest only when
# the dir is ABSENT; when an unowned dir is present alongside a stale valid
# manifest, prior_owned stays false because the manifest is exact-byte and the
# scenario constructs that state explicitly below.)
test_stale_manifest_unowned_dir_not_authorized() {
    reset_claude_dir
    install_wrapper
    mkdir -p "$CLAUDE_DIR/skills/image-gen"
    echo "USER-DATA" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    # Plant a valid manifest (would authorize deletion if not reconciled).
    printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' \
        > "$CLAUDE_DIR/.image-gen-sinedied"
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    # The unowned dir must not be overwritten; manifest must not be rewritten to
    # claim a fresh install over user data.
    if grep -q 'USER-DATA' "$CLAUDE_DIR/skills/image-gen/SKILL.md" 2>/dev/null; then
        echo "PASS: stale-manifest + unowned dir: user data not overwritten"; PASS=$((PASS + 1))
    else
        echo "FAIL: stale-manifest + unowned dir: overwritten"; FAIL=$((FAIL + 1))
    fi
}
test_stale_manifest_unowned_dir_not_authorized

# ============================================================
# Fix round 2 / review #2 - mandatory backup failure aborts upgrade
# ============================================================

test_backup_mktemp_failure_aborts() {
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    # Establish a prior valid owned install.
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    echo "PRIOR-BACKUP-CONTENT" >> "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    local prior_md="$CLAUDE_DIR/skills/image-gen/SKILL.md"
    # Force mktemp to fail by shadowing it with a failing stub.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/mktemp" <<'MK'
#!/usr/bin/env bash
exit 1
MK
    chmod +x "$TMP/bin/mktemp"
    export PATH="$TMP/bin:$PATH"
    # Re-install: backup mktemp must fail -> abort, prior untouched.
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if grep -q 'PRIOR-BACKUP-CONTENT' "$prior_md" 2>/dev/null; then
        echo "PASS: backup mktemp failure: prior install left intact (npx not invoked)"; PASS=$((PASS + 1))
    else
        echo "FAIL: backup mktemp failure: prior install mutated"; FAIL=$((FAIL + 1))
    fi
    # Remove the failing mktemp stub so later tests get the real mktemp back.
    command rm -f "$TMP/bin/mktemp" 2>/dev/null || true
    hash -r
}
test_backup_mktemp_failure_aborts

# ============================================================
# Fix round 2 / review #3 - restore failure retains backup + emits path
# ============================================================

test_restore_failure_retains_backup() {
    # Dedicated TMPDIR for THIS test only (review round 3 #3): install.sh's
    # backup mktemp honours TMPDIR, so backups land here and we never need to
    # glob-delete shared /tmp or the operator's TMPDIR.
    local dedicated_tmp; dedicated_tmp=$(mktemp -d)
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    echo "PRIOR-RESTORE-CONTENT" >> "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    # Re-install: npx wipes dir + writes SKILL.md without image_gen.py -> augment
    # fails -> restore attempted. Shadow `cp` so restore fails.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
rm -rf "$HOME/.claude/skills/image-gen"
mkdir -p "$HOME/.claude/skills/image-gen"
echo "# image-gen" > "$HOME/.claude/skills/image-gen/SKILL.md"
exit 0
NPXEOF
    chmod +x "$TMP/bin/npx"
    cat > "$TMP/bin/cp" <<'CP'
#!/usr/bin/env bash
# Fail only when the SOURCE (the arg after -a) is a backup-dir path, i.e. the
# restore direction. Backup creation copies FROM the skill dir (no
# image-gen-prev in source) and must still succeed.
case "$2" in
    *image-gen-prev*) exit 1 ;;
esac
exec /bin/cp "$@"
CP
    chmod +x "$TMP/bin/cp"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$TMP/bin:$PATH"
    hash -r   # bash caches cp's path; clear the hash so the fake cp is used.
    local out
    out="$(TMPDIR="$dedicated_tmp" DRY_RUN=false install_image_gen 2>&1)"
    # The backup must be RETAINED (restore failed) and its path emitted.
    if printf '%s' "$out" | grep -q 'backup RETAINED'; then
        echo "PASS: restore failure emits backup-retained message"; PASS=$((PASS + 1))
    else
        echo "FAIL: restore failure did not report retained backup"; FAIL=$((FAIL + 1))
    fi
    # A retained backup must exist ONLY inside our dedicated tmp dir. Remove
    # ONLY paths we created here — never glob-delete shared TMPDIR.
    local found="no"
    if find "$dedicated_tmp" -maxdepth 1 -name 'image-gen-prev.*' -type d -print 2>/dev/null | grep -q .; then
        found="yes"
    fi
    if [[ "$found" == "yes" ]]; then
        echo "PASS: restore failure retained backup directory (in dedicated TMPDIR)"; PASS=$((PASS + 1))
    else
        echo "FAIL: restore failure did not retain backup directory"; FAIL=$((FAIL + 1))
    fi
    # Remove only our dedicated dir + its contents.
    rm -rf "$dedicated_tmp" 2>/dev/null || true
    # Remove the failing cp stub so later tests get the real cp back.
    command rm -f "$TMP/bin/cp" 2>/dev/null || true
    hash -r
}
test_restore_failure_retains_backup

# ============================================================
# Fix round 2 / review #4 - dry-run writes NOTHING anywhere (HOME + TMPDIR)
# ============================================================
test_dry_run_subprocess_no_writes_anywhere() {
    local fake_home; fake_home=$(mktemp -d)
    local fake_tmp; fake_tmp=$(mktemp -d)
    local bindir="$fake_home/bin"
    mkdir -p "$bindir"
    for cmd in npx claude git curl wget; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$bindir/$cmd"
        chmod +x "$bindir/$cmd"
    done
    # Snapshot both HOME and a dedicated TMPDIR before the run.
    env -u CLAUDE_CODE_ENTRYPOINT HOME="$fake_home" TMPDIR="$fake_tmp" \
        PATH="$bindir:/usr/bin:/bin" \
        bash "$DIR/install.sh" --dry-run --all >/tmp/ig_dr2.out 2>&1
    local rc=$?
    # HOME must contain nothing but the fake bin stubs we created.
    local home_extra="no"
    local home_out
    home_out=$(find "$fake_home" -mindepth 1 ! -path "$fake_home/bin/*" ! -path "$fake_home/bin" -print 2>/dev/null | head -1)
    [[ -n "$home_out" ]] && home_extra="yes"
    # TMPDIR must be empty (no deepxiv tmp dir created).
    local tmp_extra="no"
    local tmp_out
    tmp_out=$(find "$fake_tmp" -mindepth 1 -print 2>/dev/null | head -1)
    [[ -n "$tmp_out" ]] && tmp_extra="yes"
    IG_DR2_HOME="$fake_home"; IG_DR2_TMP="$fake_tmp"
    echo "rc=$rc home_extra=$home_extra tmp_extra=$tmp_extra"
}
DR2="$(test_dry_run_subprocess_no_writes_anywhere)"
rm -rf "${IG_DR2_HOME:-}" "${IG_DR2_TMP:-}" 2>/dev/null
if printf '%s' "$DR2" | grep -q 'home_extra=no'; then
    echo "PASS: dry-run --all subprocess: HOME unchanged (only fake stubs present)"; PASS=$((PASS + 1))
else
    echo "FAIL: dry-run --all subprocess wrote to HOME:"; printf '%s\n' "$DR2"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$DR2" | grep -q 'tmp_extra=no'; then
    echo "PASS: dry-run --all subprocess: dedicated TMPDIR stays empty"; PASS=$((PASS + 1))
else
    echo "FAIL: dry-run --all subprocess wrote to TMPDIR"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Fix round 3 / review #1 - strict marker prose never authorizes ownership
# A valid manifest alongside a SKILL.md whose markers are embedded/reversed/
# duplicate must NOT be treated as installer-owned: no deletion, no overwrite.
# ============================================================

# Helper: plant a dir + valid manifest + a (malformed) SKILL.md, then check
# ownership and that install_image_gen refuses to mutate it.
_check_prose_not_owned() {
    local label="$1" skill_md_body="$2"
    reset_claude_dir
    install_wrapper
    mkdir -p "$CLAUDE_DIR/skills/image-gen/scripts"
    printf '%s' "$skill_md_body" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    echo '#!/usr/bin/env python3' > "$CLAUDE_DIR/skills/image-gen/scripts/image_gen.py"
    printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' \
        > "$CLAUDE_DIR/.image-gen-sinedied"
    # Pure ownership check must reject.
    if _image_gen_dir_owned "$CLAUDE_DIR/skills/image-gen" "$CLAUDE_DIR/.image-gen-sinedied"; then
        echo "FAIL: $label -> _image_gen_dir_owned accepted (should reject)"; FAIL=$((FAIL + 1))
    else
        echo "PASS: $label -> _image_gen_dir_owned rejects"; PASS=$((PASS + 1))
    fi
    # Strict marker validator must reject.
    if _image_gen_markers_strict "$CLAUDE_DIR/skills/image-gen/SKILL.md"; then
        echo "FAIL: $label -> _image_gen_markers_strict accepted"; FAIL=$((FAIL + 1))
    else
        echo "PASS: $label -> _image_gen_markers_strict rejects"; PASS=$((PASS + 1))
    fi
    # install_image_gen must NOT overwrite (treats as unowned). Use a fake npx
    # that would clobber if invoked; assert the user content survives.
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    if grep -q 'USER-PROSE-DATA' "$CLAUDE_DIR/skills/image-gen/SKILL.md" 2>/dev/null; then
        echo "PASS: $label -> install did not overwrite user prose"; PASS=$((PASS + 1))
    else
        echo "FAIL: $label -> install overwrote user prose"; FAIL=$((FAIL + 1))
    fi
}

B="$IMAGE_GEN_BEGIN_MARKER"; E="$IMAGE_GEN_END_MARKER"

# Embedded marker text (line contains marker substring but is not an exact line).
_check_prose_not_owned "embedded-marker-prose" \
"# image-gen
USER-PROSE-DATA and ${B} mentioned inline.
rest of file"

# Reversed order: END before BEGIN.
_check_prose_not_owned "reversed-markers" \
"# image-gen
USER-PROSE-DATA
${E}
managed block
${B}"

# Duplicate BEGIN markers.
_check_prose_not_owned "duplicate-begin" \
"# image-gen
USER-PROSE-DATA
${B}
block one
${E}
${B}
block two
${E}"

# Duplicate END markers.
_check_prose_not_owned "duplicate-end" \
"${B}
USER-PROSE-DATA
${E}
after
${E}"

# Unterminated (BEGIN with no END).
_check_prose_not_owned "unterminated-begin" \
"# image-gen
USER-PROSE-DATA
${B}
managed block (no end)"

# Uninstall must also preserve a dir whose markers are prose/malformed even
# when a valid manifest is present: ownership proof is incomplete.
test_uninstall_prose_not_deleted() {
    local tmp; tmp=$(mktemp -d); export HOME="$tmp"
    trap 'rm -rf "$tmp"' RETURN
    source "$DIR/install.sh" 2>/dev/null
    set +euo pipefail
    claude() { return 0; }
    SCRIPT_DIR="$tmp"; export SCRIPT_DIR; mkdir -p "$tmp/skills"
    mkdir -p "$CLAUDE_DIR/skills/image-gen"
    printf '# image-gen\nUSER-PROSE-DATA\n%s inline\n' "$B" > "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    printf 'skill=image-gen\nsource=sinedied/agent-skills\nwrapper=image-gen-cliproxyapi.sh\n' \
        > "$CLAUDE_DIR/.image-gen-sinedied"
    FORCE=true DRY_RUN=false uninstall >/dev/null 2>&1
    local result
    [[ -d "$CLAUDE_DIR/skills/image-gen" ]] && result="KEPT" || result="REMOVED"
    rm -rf "$tmp"
    echo "$result"
}
assert_eq "uninstall: embedded-marker prose dir preserved (not installer-owned)" \
    "KEPT" "$(test_uninstall_prose_not_deleted)"

# ============================================================
# Fix round 3 / review #2 - forced rm failure: restore retains backup
# Target removal failure must NOT copy into a surviving target; the backup is
# retained and reported. Uses a dedicated TMPDIR (review #3).
# ============================================================
test_restore_rm_failure_retains_backup() {
    local dedicated_tmp; dedicated_tmp=$(mktemp -d)
    reset_claude_dir
    install_wrapper
    make_fake_npx 0
    DRY_RUN=false install_image_gen >/dev/null 2>&1
    echo "PRIOR-RM-CONTENT" >> "$CLAUDE_DIR/skills/image-gen/SKILL.md"
    # Re-install: npx removes ONLY image_gen.py (rm stub allows it since the
    # path is not the skill dir itself) and overwrites SKILL.md, so augment
    # fails -> restore attempted. The rm stub then refuses the restore's
    # `rm -rf skill_dir`, proving backup retention on target-removal failure.
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
rm -f "$HOME/.claude/skills/image-gen/scripts/image_gen.py"
echo "# image-gen" > "$HOME/.claude/skills/image-gen/SKILL.md"
exit 0
NPXEOF
    chmod +x "$TMP/bin/npx"
    # Fake rm: succeed for everything EXCEPT removing the skill_dir on restore.
    cat > "$TMP/bin/rm" <<'RM'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        */skills/image-gen) exit 1 ;;
    esac
done
exec /bin/rm "$@"
RM
    chmod +x "$TMP/bin/rm"
    rm -rf "$TMP/npx_state"; mkdir -p "$TMP/npx_state"
    export PATH="$TMP/bin:$PATH"
    hash -r
    local out
    out="$(TMPDIR="$dedicated_tmp" DRY_RUN=false install_image_gen 2>&1)"
    # Restore must have failed because target removal failed -> backup retained.
    if printf '%s' "$out" | grep -q 'backup RETAINED'; then
        echo "PASS: rm-failure restore retains backup (message emitted)"; PASS=$((PASS + 1))
    else
        echo "FAIL: rm-failure restore did not report retained backup"; FAIL=$((FAIL + 1))
    fi
    # Backup must survive inside the dedicated tmp only.
    if find "$dedicated_tmp" -maxdepth 1 -name 'image-gen-prev.*' -type d -print 2>/dev/null | grep -q .; then
        echo "PASS: rm-failure backup retained in dedicated TMPDIR"; PASS=$((PASS + 1))
    else
        echo "FAIL: rm-failure backup missing"; FAIL=$((FAIL + 1))
    fi
    # Remove ONLY our dedicated dir.
    rm -rf "$dedicated_tmp" 2>/dev/null || true
    command rm -f "$TMP/bin/rm" 2>/dev/null || true
    hash -r
}
test_restore_rm_failure_retains_backup

# ============================================================
# Task 6 - PowerShell installer parity (install.ps1)
# ============================================================
# pwsh is unavailable in this POSIX environment, so behavioral tests
# (temporary-USERPROFILE subprocess) are SKIPPED. The assertions below
# are STATIC checks of install.ps1 source: they verify the PowerShell
# installer carries the same parity guarantees the Bash installer
# enforces (exact source/flags, retry, DO_NOT_TRACK restore, manifest,
# markers, wrapper, unconditional always-install, ownership-gated
# uninstall, accurate native-Windows limitation). A brace-balance check
# ensures Invoke-Uninstall is structurally closed (no orphaned cleanup
# code running at script scope).

PS1="$DIR/install.ps1"

if command -v pwsh >/dev/null 2>&1; then
    echo "INFO: pwsh available - behavioral (temp-USERPROFILE) tests would run"
else
    echo "SKIP: pwsh not available - PowerShell behavioral tests skipped (static assertions only)"
fi

ps1_contains() {
    local desc="$1" needle="$2"
    if grep -qF -- "$needle" "$PS1" 2>/dev/null; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (missing: $needle)"; FAIL=$((FAIL + 1))
    fi
}

ps1_count_is() {
    local desc="$1" pattern="$2" expected="$3"
    local n
    n=$(grep -cE -- "$pattern" "$PS1" 2>/dev/null) || n=0
    if [[ "$n" -eq "$expected" ]]; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected $expected, got $n)"; FAIL=$((FAIL + 1))
    fi
}

# --- Functions produced (plan Task 6) ---
ps1_contains "ps1: Get-ImageGenNpxArgs defined" "function Get-ImageGenNpxArgs"
ps1_contains "ps1: Get-ImageGenIntegrationBlock defined" "function Get-ImageGenIntegrationBlock"
ps1_contains "ps1: Update-ImageGenSkillInstructions defined" "function Update-ImageGenSkillInstructions"
ps1_contains "ps1: Install-ImageGen defined" "function Install-ImageGen"
ps1_contains "ps1: Test-ImageGenManifestValid defined" "function Test-ImageGenManifestValid"
ps1_contains "ps1: Test-ImageGenMarkersStrict defined" "function Test-ImageGenMarkersStrict"
ps1_contains "ps1: Test-ImageGenDirOwned defined" "function Test-ImageGenDirOwned"

# --- Exact network command source/flags ---
ps1_contains "ps1: exact source sinedied/agent-skills" "sinedied/agent-skills"
ps1_contains "ps1: skills@latest package" "skills@latest"
ps1_contains "ps1: --global flag" '"--global"'
ps1_contains "ps1: --agent flag" '"--agent"'
ps1_contains "ps1: claude-code agent value" '"claude-code"'
ps1_contains "ps1: --copy flag" '"--copy"'
ps1_contains "ps1: --yes flag" '"--yes"'
ps1_contains "ps1: --skill flag" '"--skill"'
ps1_contains "ps1: image-gen skill value" '"image-gen"'

# --- Markers exact text (shared interface) ---
ps1_contains "ps1: BEGIN marker exact" "<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->"
ps1_contains "ps1: END marker exact" "<!-- END claude-code-config CLIProxyAPI image-gen integration -->"

# --- Canonical manifest fields (byte-exact single source) ---
ps1_contains "ps1: manifest skill field" "skill=image-gen"
ps1_contains "ps1: manifest source field" "source=sinedied/agent-skills"
ps1_contains "ps1: manifest wrapper field" "wrapper=image-gen-cliproxyapi.sh"

# --- Integration block canonical content ---
ps1_contains "ps1: block mentions wrapper path" "image-gen-cliproxyapi.sh"
ps1_contains "ps1: block mentions gpt-image-2" "gpt-image-2"
ps1_contains "ps1: block forbids OpenAI Platform key" "OpenAI Platform API key"
ps1_contains "ps1: block mentions loopback endpoint" "127.0.0.1:8317"

# --- 3 retry attempts + 5s delay (parity with Bash retry 3 5) ---
ps1_contains "ps1: 3 retry attempts for image-gen" "MaxAttempts 3"
ps1_contains "ps1: 5s retry delay for image-gen" "DelaySeconds 5"

# --- DO_NOT_TRACK save + restore (try/finally so it always restores) ---
ps1_contains "ps1: DO_NOT_TRACK saved before npx" "prevDnt"
ps1_contains "ps1: DO_NOT_TRACK restored in finally" "finally"
ps1_contains "ps1: DO_NOT_TRACK set to 1 for npx" 'DO_NOT_TRACK = "1"'

# --- Dry-run is sanitized (Install-ImageGen checks DryRun) ---
ps1_contains "ps1: Install-ImageGen references DryRun" "DryRun"

# --- Wrapper registered as installer-managed user script ---
ps1_contains "ps1: wrapper in USER_SCRIPTS" "image-gen-cliproxyapi.sh"

# --- Always-installed wiring: one ungated call site, no flag gate, no early-exit ---
ps1_count_is "ps1: exactly one Install-ImageGen call site (excluding definition)" '^[[:space:]]*Install-ImageGen([^a-zA-Z0-9_-]|$)' 1
ps1_count_is "ps1: Install-ImageGen not behind a flag gate" 'if \(\$do[A-Za-z]+\) \{[[:space:]]*Install-ImageGen' 0
if grep -q 'Nothing selected' "$PS1" 2>/dev/null; then
    echo "FAIL: ps1: 'Nothing selected' early-exit still present (blocks always-install)"; FAIL=$((FAIL + 1))
else
    echo "PASS: ps1: 'Nothing selected' early-exit removed (always-on floor)"; PASS=$((PASS + 1))
fi

# --- Install-ImageGen runs AFTER Install-Scripts in Main (wrapper must exist first) ---
ps1_main_order() {
    local scripts_line imagegen_line
    scripts_line=$(grep -nE '^[[:space:]]*Install-Scripts([^a-zA-Z0-9_-]|$)' "$PS1" | tail -1 | cut -d: -f1)
    imagegen_line=$(grep -nE '^[[:space:]]*Install-ImageGen([^a-zA-Z0-9_-]|$)' "$PS1" | tail -1 | cut -d: -f1)
    if [[ -n "$scripts_line" && -n "$imagegen_line" && "$imagegen_line" -gt "$scripts_line" ]]; then
        echo "after"
    else
        echo "other"
    fi
}
assert_eq "ps1: Install-ImageGen called after Install-Scripts" "after" "$(ps1_main_order)"

# --- Native Windows limitation stated accurately ---
ps1_contains "ps1: states native Windows cl_/CLIProxyAPI unsupported" "native Windows"
ps1_contains "ps1: recommends WSL or Bash for wrapper" "WSL"
# Must NOT overclaim native Windows runtime support (no false end-to-end claim
# without the qualifying "not supported").
if grep -qiE 'native Windows.*(fully |end-to-end )?supported' "$PS1" 2>/dev/null \
   && ! grep -qi 'native Windows.*not supported' "$PS1"; then
    echo "FAIL: ps1: overclaims native Windows runtime support"; FAIL=$((FAIL + 1))
else
    echo "PASS: ps1: no false native-Windows runtime support claim"; PASS=$((PASS + 1))
fi

# --- Uninstall: ownership-gated image-gen removal inside Invoke-Uninstall ---
ps1_contains "ps1: uninstall references image-gen manifest" ".image-gen-sinedied"
ps1_contains "ps1: uninstall validates ownership before delete" "Test-ImageGenDirOwned"

# --- Structural: Invoke-Uninstall must close exactly once (no orphaned code) ---
test_ps1_invoke_uninstall_balance() {
    python3 - "$PS1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
start = None
for i, l in enumerate(lines):
    if l.startswith('function Invoke-Uninstall'):
        start = i; break
if start is None:
    print("NO_FUNC"); sys.exit(0)
bal = 0
for i in range(start, len(lines)):
    s = re.sub(r'"[^"]*"', '""', lines[i])
    s = re.sub(r"'[^']*'", "''", s)
    bal += s.count('{') - s.count('}')
    if bal == 0 and i > start:
        # first return to 0 is the function close; the next non-blank/non-comment
        # line must NOT be indented cleanup (that would indicate orphaned code).
        for j in range(i+1, len(lines)):
            nxt = lines[j].strip()
            if not nxt or nxt.startswith('#'): continue
            if re.match(r'^(if|foreach|\$|Remove-Item|Get-ChildItem)\b', nxt):
                print("ORPHAN_AT_%d" % (j+1)); sys.exit(0)
            break
        print("OK_FIRSTCLOSE_%d" % (i+1)); sys.exit(0)
    if bal < 0:
        print("NEG_BAL_%d" % (i+1)); sys.exit(0)
print("NEVER_CLOSED")
PY
}
bal_result="$(test_ps1_invoke_uninstall_balance)"
case "$bal_result" in
    OK_FIRSTCLOSE_*)
        echo "PASS: ps1: Invoke-Uninstall closes exactly once (no orphaned cleanup)"; PASS=$((PASS + 1))
        ;;
    *)
        echo "FAIL: ps1: Invoke-Uninstall brace structure broken ($bal_result)"; FAIL=$((FAIL + 1))
        ;;
esac

# --- Full-file parse sanity: brace balance is net zero and never negative ---
test_ps1_file_balance() {
    python3 - "$PS1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
bal = 0
min_bal = 0
for i, line in enumerate(lines):
    s = re.sub(r'"[^"]*"', '""', line)
    s = re.sub(r"'[^']*'", "''", s)
    bal += s.count('{') - s.count('}')
    if bal < min_bal: min_bal = bal
print("final=%d min=%d" % (bal, min_bal))
PY
}
fbal="$(test_ps1_file_balance)"
if printf '%s' "$fbal" | grep -qE 'final=0 min=[0-9]+'; then
    echo "PASS: ps1: whole-file brace balance net zero and never negative"; PASS=$((PASS + 1))
else
    echo "FAIL: ps1: whole-file brace balance off ($fbal)"; FAIL=$((FAIL + 1))
fi

# ============================================================
# Round 1 / review findings (PowerShell) — scoped static + fixtures
# ============================================================
# pwsh is NOT available here, so behavioral byte/subprocess checks are
# SKIPPED (see the gated block below). The assertions below are scoped to
# FUNCTION BODIES (not loose file-wide tokens) so they precisely catch
# regressions in the named function, plus fixture byte-property contracts
# that document exactly what the augmentation must preserve.

ps1_func_body() {
    # Print the body (header through matching close brace) of a named function.
    local name="$1"
    python3 - "$PS1" "$name" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
name = sys.argv[2]
start = None
for i, l in enumerate(lines):
    if re.match(r'^function\s+' + re.escape(name) + r'\s*\{', l):
        start = i; break
if start is None: sys.exit(0)
bal = 0
out = []
for i in range(start, len(lines)):
    s = re.sub(r'"[^"]*"', '""', lines[i]); s = re.sub(r"'[^']*'", "''", s)
    bal += s.count('{') - s.count('}')
    out.append(lines[i])
    if bal == 0 and i > start:
        print('\n'.join(out)); break
PY
}

body_contains() {
    local desc="$1" body="$2" needle="$3"
    if printf '%s' "$body" | grep -qF -- "$needle"; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (missing: $needle)"; FAIL=$((FAIL + 1))
    fi
}

body_not_contains() {
    local desc="$1" body="$2" needle="$3"
    if printf '%s' "$body" | grep -qF -- "$needle"; then
        echo "FAIL: $desc (present but should not be: $needle)"; FAIL=$((FAIL + 1))
    else
        echo "PASS: $desc"; PASS=$((PASS + 1))
    fi
}

INVOKENPX_BODY="$(ps1_func_body Install-ImageGen)"
NPXPROC_BODY="$(ps1_func_body Invoke-ImageGenNpx)"
AUGMENT_BODY="$(ps1_func_body Update-ImageGenSkillInstructions)"
MANIFEST_BODY="$(ps1_func_body Write-ImageGenManifest)"
UNINSTALL_BODY="$(ps1_func_body Invoke-Uninstall)"
MAIN_BODY="$(ps1_func_body Main)"

# --- #1: uninstall never blanket-deletes skills when inventory missing ---
body_not_contains "ps1#1: uninstall has no blanket 'Removed skills/' delete" "$UNINSTALL_BODY" 'Removed skills/'
body_contains "ps1#1: uninstall warns when skills inventory missing" "$UNINSTALL_BODY" 'No source skills inventory'

# --- #2: DryRun guards on directory creation in Main + install fns ---
# Within Main, every New-Item to CLAUDE_DIR must be inside a -not $DryRun guard
# (the guard lives on the preceding `if`, so we check the surrounding context).
main_unguarded="$(printf '%s\n' "$MAIN_BODY" | awk '
    /New-Item.*CLAUDE_DIR/ {
        # look back up to 3 lines for a DryRun guard on this block
        guarded=0
        for (i=NR-1; i>=NR-3 && i>=1; i--) { if (lines[i] ~ /\$DryRun/) { guarded=1; break } }
        if (!guarded) { print "UNGUARDED"; exit }
    }
    { lines[NR]=$0 }
')"
if [[ -z "$main_unguarded" ]]; then
    echo "PASS: ps1#2: Main CLAUDE_DIR creation guarded by DryRun"; PASS=$((PASS + 1))
else
    echo "FAIL: ps1#2: Main creates CLAUDE_DIR without DryRun guard"; FAIL=$((FAIL + 1))
fi
# Install-Scripts mkdir guarded.
SCRIPTS_BODY="$(ps1_func_body Install-Scripts)"
if printf '%s' "$SCRIPTS_BODY" | grep -E 'New-Item.*scriptsDir' | grep -qv 'DryRun'; then
    echo "FAIL: ps1#2: Install-Scripts creates scriptsDir without DryRun guard"; FAIL=$((FAIL + 1))
else
    echo "PASS: ps1#2: Install-Scripts scriptsDir creation guarded by DryRun"; PASS=$((PASS + 1))
fi

# --- #3: byte-aware augmentation (raw bytes, BOM/CRLF/LF, no Get-Content) ---
body_contains "ps1#3: augment reads raw bytes" "$AUGMENT_BODY" '[System.IO.File]::ReadAllBytes'
body_contains "ps1#3: augment writes raw bytes" "$AUGMENT_BODY" '[System.IO.File]::WriteAllBytes'
body_contains "ps1#3: augment detects UTF-8 BOM" "$AUGMENT_BODY" '0xEF'
body_contains "ps1#3: augment detects CRLF newline" "$AUGMENT_BODY" '0x0D'
body_contains "ps1#3: augment regex-splits preserving separators" "$AUGMENT_BODY" '[regex]::Split'
body_not_contains "ps1#3: augment never uses Get-Content (PS5.1 encoding hazard)" "$AUGMENT_BODY" 'Get-Content'

# --- #4: npx invoked via Process with detached stdin (not & npx pipeline) ---
NPXCLI_BODY="$(ps1_func_body Get-ImageGenNpxCommandLine)"
body_not_contains "ps1#4: Install-ImageGen never uses '& npx' pipeline" "$INVOKENPX_BODY" '& npx @npxArgs'
body_contains  "ps1#4: Install-ImageGen calls Invoke-ImageGenNpx" "$INVOKENPX_BODY" 'Invoke-ImageGenNpx'
body_contains  "ps1#4: Invoke-ImageGenNpx closes stdin (EOF)" "$NPXPROC_BODY" 'StandardInput.Close'
body_contains  "ps1#4: Invoke-ImageGenNpx redirects stdin" "$NPXPROC_BODY" 'RedirectStandardInput'
body_contains  "ps1#4: Invoke-ImageGenNpx drains stdout async" "$NPXPROC_BODY" 'ReadToEndAsync'
body_contains  "ps1#4: Invoke-ImageGenNpx checks exit code" "$NPXPROC_BODY" 'ExitCode'
body_contains  "ps1#4: npx.cmd handled in command-line helper" "$NPXCLI_BODY" '*.cmd'
body_contains  "ps1#4: npx.cmd uses documented /d /s /c quoting" "$NPXCLI_BODY" '/d /s /c'
body_contains  "ps1#4: command-line helper fails closed on whitespace tokens" "$NPXCLI_BODY" 'return $null'
body_not_contains "ps1#4: Invoke-ImageGenNpx has no inline arg-join (delegated)" "$NPXPROC_BODY" 'NpxArgs -join'

# --- #5: atomic manifest replacement ---
body_contains "ps1#5: manifest uses atomic Replace for existing" "$MANIFEST_BODY" '[System.IO.File]::Replace'
body_contains "ps1#5: manifest first-install uses Move (no delete-first)" "$MANIFEST_BODY" 'Move-Item'
body_not_contains "ps1#5: manifest does NOT Remove-then-Move existing" "$MANIFEST_BODY" 'Remove-Item -LiteralPath $Manifest -Force'

# --- #7: WSL guidance distinguishes WSL ~/.claude vs Windows %USERPROFILE% ---
body_contains "ps1#7: WSL guidance distinguishes %USERPROFILE% from WSL ~/.claude" \
    "$(grep -A30 'function Get-ImageGenIntegrationBlock' "$PS1")" '%USERPROFILE%'
body_contains "ps1#7: recommends running Bash installer inside WSL" \
    "$(grep -A30 'function Get-ImageGenIntegrationBlock' "$PS1")" 'inside WSL'

# --- Fixture byte-property contracts (document what augmentation preserves) ---
FX="$DIR/tests/fixtures/image_gen"
assert_fixture_byte() {
    local desc="$1" file="$2" check="$3"
    if eval "$check"; then echo "PASS: $desc"; PASS=$((PASS + 1)); else echo "FAIL: $desc"; FAIL=$((FAIL + 1)); fi
}
# Verify augmentation byte-preservation for a (original, augmented) pair.
# Checks: exactly one marker pair; BOM preserved; head (before BEGIN) matches
# original prefix; suffix (after END's separator) preserved for replace;
# managed block internal newline style consistent; final-newline state policy.
# Prints "OK" or "FAIL <reason>". Defined at top level (no nested heredoc
# quoting hazards) so the pwsh-gated while-loop can call it safely.
verify_aug_bytes() {
    python3 - "$1" "$2" <<'PY'
import sys, codecs, re
orig = open(sys.argv[1], 'rb').read()
aug = open(sys.argv[2], 'rb').read()
BEGIN = b'<!-- BEGIN claude-code-config CLIProxyAPI image-gen integration -->'
END = b'<!-- END claude-code-config CLIProxyAPI image-gen integration -->'
# Exactly one marker pair in augmented output.
beg = aug.count(BEGIN); end = aug.count(END)
if beg != 1 or end != 1:
    print("FAIL markers beg=%d end=%d" % (beg, end)); sys.exit(0)
# BOM preserved.
ob = orig[:3] == b'\xef\xbb\xbf'
ab = aug[:3] == b'\xef\xbb\xbf'
if ob != ab:
    print("FAIL bom orig=%s aug=%s" % (ob, ab)); sys.exit(0)
ob_off = 3 if ob else 0
ab_off = 3 if ab else 0
# Managed block is valid UTF-8.
b_off = aug.find(BEGIN, ab_off)
e_off = aug.find(END, ab_off) + len(END)
try:
    codecs.decode(aug[b_off:e_off], 'utf-8')
except Exception:
    print("FAIL managed-block utf8"); sys.exit(0)
# Head (before BEGIN) must match a prefix of the original body (append: whole
# body; replace: original up to its old BEGIN).
ahead = aug[ab_off:b_off]
obody = orig[ob_off:]
if not obody.startswith(ahead):
    print("FAIL head-prefix"); sys.exit(0)
# Determine if original had markers (replace) or not (append).
obegin = orig.find(BEGIN, ob_off)
oend = orig.find(END, ob_off)
if obegin >= 0 and oend >= 0 and obegin < oend:
    # REPLACE: suffix after END's separator must match the original suffix.
    # Original suffix begins at the separator after original END content.
    oend_after = oend + len(END)
    # find the separator that follows original END line
    m = re.match(rb'[\r\n]+', orig[oend_after:])
    osep_len = len(m.group(0)) if m else 0
    o_suffix_start = oend_after  # separator + rest
    o_suffix = orig[o_suffix_start:]
    # Augmented suffix begins after END content (we emit END with no trailing
    # separator; the tail must include the original separator + suffix bytes).
    a_after_end = e_off
    a_suffix = aug[a_after_end:]
    if a_suffix != o_suffix:
        print("FAIL replace-suffix"); sys.exit(0)
else:
    # APPEND: final-newline state policy.
    # If original ended WITHOUT a newline, augmented must end at END (no trailing
    # newline). If original ended WITH a newline, augmented must end with the
    # detected newline after END.
    orig_terminated = bool(re.search(rb'[\r\n]$', orig[ob_off:]))
    aug_tail = aug[e_off:]
    if orig_terminated:
        if aug_tail != b'\n' and aug_tail != b'\r\n' and aug_tail != b'\r':
            print("FAIL append-terminated-tail=%r" % aug_tail); sys.exit(0)
    else:
        if aug_tail != b'':
            print("FAIL append-no-final-nl-tail=%r" % aug_tail); sys.exit(0)
print("OK")
PY
}

fixture_has_byte() {
    # fixture_has_byte <file> <hex-byte-like 0d>  -> returns 0 if byte present
    python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
b = int(sys.argv[2], 16)
sys.exit(0 if bytes([b]) in data else 1)
PY
}
fixture_lacks_byte() {
    python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
b = int(sys.argv[2], 16)
sys.exit(0 if bytes([b]) not in data else 1)
PY
}

assert_fixture_byte "fx: plain LF fixture exists" "$FX/skill_plain_lf.md" '[ -f "$FX/skill_plain_lf.md" ]'
assert_fixture_byte "fx: CRLF fixture has CR" "$FX/skill_crlf.md" 'fixture_has_byte "$FX/skill_crlf.md" 0d'
assert_fixture_byte "fx: BOM fixture starts with EF BB BF" "$FX/skill_bom_chinese.md" '[ "$(head -c3 "$FX/skill_bom_chinese.md" | xxd -p)" = "efbbbf" ]'
assert_fixture_byte "fx: BOM fixture has BOM-less UTF-8 Chinese" "$FX/skill_bom_chinese.md" 'fixture_has_byte "$FX/skill_bom_chinese.md" e4'
assert_fixture_byte "fx: no-final-nl fixture ends without newline" "$FX/skill_no_final_nl.md" 'python3 -c "import sys;d=open(sys.argv[1],\"rb\").read();sys.exit(0 if d and d[-1]!=10 else 1)" "$FX/skill_no_final_nl.md"'
assert_fixture_byte "fx: with-block fixture has existing managed markers" "$FX/skill_with_block.md" 'grep -q "BEGIN claude-code-config" "$FX/skill_with_block.md"'

# ============================================================
# pwsh-gated BEHAVIORAL suite (parser + subprocess + bytes + stdin EOF)
# Runs ONLY when pwsh is available; otherwise SKIPs explicitly. The static
# assertions above are the authority in pwsh-absent environments; behavioral
# parity is NOT claimed without pwsh.
# ============================================================
if command -v pwsh >/dev/null 2>&1; then
    PWSH_BIN="$(command -v pwsh)"
    echo "INFO: pwsh present ($PWSH_BIN) - running behavioral suite"

    # Capture the REAL operator home BEFORE any isolation (no hardcoded path).
    REAL_HOME="$HOME"

    # Shared isolated root for helper tests (augment, command-line helper).
    behav_root="$(mktemp -d)"
    behav_home="$behav_root/home"
    behav_tmp="$behav_root/tmp"
    mkdir -p "$behav_home/bin" "$behav_tmp"
    BEHAV_OUT="$behav_root/out.log"

    # Parser: install.ps1 must parse with zero errors (no dot-source, no exec).
    parse_out="$("$PWSH_BIN" -NoProfile -Command '
        $null = [System.Management.Automation.Language.Parser]::ParseFile("'"$PS1"'", [ref]$null, [ref]$e);
        if ($e) { "ERR:$($e.Count)" } else { "OK" }
    ' 2>&1)"
    assert_eq "ps1-behav: install.ps1 parses cleanly" "OK" "$parse_out"

    # --- Augmentation byte contract (Finding 5+7): dot-source with the IMPORT
    # GUARD set AND fully isolated HOME/USERPROFILE/TMPDIR/TMP/TEMP so Main
    # never runs and no real home is touched. Exactly 7 fixtures must process.
    "$PWSH_BIN" -NoProfile -Command '
        $ErrorActionPreference = "Stop"
        $env:CLAUDE_CODE_CONFIG_IMPORT_ONLY = "1"
        $env:USERPROFILE = "'"$behav_home"'"
        $env:TMP = "'"$behav_tmp"'"; $env:TEMP = "'"$behav_tmp"'"
        . "'"$PS1"'"
        Remove-Item Env:\CLAUDE_CODE_CONFIG_IMPORT_ONLY -ErrorAction SilentlyContinue
        $fx = "'"$FX"'"
        $out_root = "'"$behav_root"'"
        $cases = @("skill_plain_lf.md","skill_crlf.md","skill_bom_chinese.md","skill_no_final_nl.md","skill_with_block.md","skill_cr_only.md","skill_malformed_utf8.md")
        foreach ($c in $cases) {
            $sd = Join-Path $out_root "skills"
            $ig = Join-Path $sd "image-gen"
            New-Item -ItemType Directory -Path $ig -Force | Out-Null
            Copy-Item (Join-Path $fx $c) (Join-Path $ig "SKILL.md") -Force
            Set-Content -Path (Join-Path $ig "image_gen.py") -Value "print(1)" -NoNewline
            $ok = Update-ImageGenSkillInstructions -SkillsDir $sd
            Copy-Item (Join-Path $ig "SKILL.md") (Join-Path $out_root ("aug_" + $c)) -Force
            if ($ok) { Write-Output "AUG_OK:$c" } else { Write-Output "AUG_FAIL:$c" }
        }
    ' > "$BEHAV_OUT" 2>&1
    # Finding 7: require EXACTLY 7 records; fail if pwsh exited early / none.
    aug_ok_cnt="$(grep -c '^AUG_OK:' "$BEHAV_OUT" 2>/dev/null || echo 0)"
    assert_eq "ps1-behav: exactly 7 augmentation fixtures processed" "7" "$aug_ok_cnt"
    # Read captured output in the CURRENT shell (no subshell counter loss).
    while IFS= read -r behav_line; do
        case "$behav_line" in
            AUG_OK:*)
                f="${behav_line#AUG_OK:}"
                verify="$(verify_aug_bytes "$FX/$f" "$behav_root/aug_$f")"
                if [[ "$verify" == "OK" ]]; then
                    echo "PASS: ps1-behav: $f augmentation byte-preserving"; PASS=$((PASS + 1))
                else
                    echo "FAIL: ps1-behav: $f augmentation $verify"; FAIL=$((FAIL + 1))
                fi
                ;;
            AUG_FAIL:*)
                echo "FAIL: ps1-behav: augment failed on ${behav_line#AUG_FAIL:}"; FAIL=$((FAIL + 1))
                ;;
        esac
    done < "$BEHAV_OUT"

    # --- npx.cmd command-line helper (Finding 5): import guard + isolated env.
    spaced_out="$("$PWSH_BIN" -NoProfile -Command '
        $env:CLAUDE_CODE_CONFIG_IMPORT_ONLY = "1"
        $env:USERPROFILE = "'"$behav_home"'"
        $env:TMP = "'"$behav_tmp"'"; $env:TEMP = "'"$behav_tmp"'"
        . "'"$PS1"'"
        Remove-Item Env:\CLAUDE_CODE_CONFIG_IMPORT_ONLY -ErrorAction SilentlyContinue
        $cli = Get-ImageGenNpxCommandLine -Exe "C:\Program Files\nodejs\npx.cmd" -NpxArgs @("-y","skills@latest","add")
        if (-not $cli) { "NONE" } else { $cli.FileName + "|" + $cli.Arguments }
    ' 2>&1)"
    spaced_fn="$(printf '%s' "$spaced_out" | cut -d'|' -f1)"
    spaced_args="$(printf '%s' "$spaced_out" | cut -d'|' -f2-)"
    assert_eq "ps1-behav: npx.cmd spaced-path FileName" "cmd.exe" "$spaced_fn"
    if [[ "$spaced_args" == *'/d /s /c'* ]] && [[ "$spaced_args" == *'"C:\Program Files\nodejs\npx.cmd"'* ]]; then
        echo "PASS: ps1-behav: npx.cmd spaced-path uses /d /s /c with quoted exe"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: npx.cmd spaced-path args = [$spaced_args]"; FAIL=$((FAIL + 1))
    fi
    ws_out="$("$PWSH_BIN" -NoProfile -Command '
        $env:CLAUDE_CODE_CONFIG_IMPORT_ONLY = "1"
        $env:USERPROFILE = "'"$behav_home"'"
        . "'"$PS1"'"
        Remove-Item Env:\CLAUDE_CODE_CONFIG_IMPORT_ONLY -ErrorAction SilentlyContinue
        $cli = Get-ImageGenNpxCommandLine -Exe "npx.cmd" -NpxArgs @("bad arg")
        if ($null -eq $cli) { "NULL" } else { "GOT" }
    ' 2>&1)"
    assert_eq "ps1-behav: whitespace token fails closed (returns null)" "NULL" "$ws_out"

    # --- Full subprocess (Finding 6): FRESH dedicated HOME+TMP separate from
    # the helper-test dirs above. Fake npx records stdin EOF + exact argv.
    sub_root="$(mktemp -d)"; sub_home="$sub_root/home"; sub_tmp="$sub_root/tmp"
    mkdir -p "$sub_home/bin" "$sub_tmp"
    cat > "$sub_home/bin/npx" <<'NPXEOF'
#!/usr/bin/env bash
state="$BEHAV_STATE"
mkdir -p "$state"
echo "args:$*" > "$state/npx.txt"
if [ -t 0 ]; then echo "tty" > "$state/stdin.txt"; else echo "eof" > "$state/stdin.txt"; fi
mkdir -p "$BEHAV_HOME/.claude/skills/image-gen"
printf '# image-gen\n\nupstream\n' > "$BEHAV_HOME/.claude/skills/image-gen/SKILL.md"
printf '#!/usr/bin/env python3\n' > "$BEHAV_HOME/.claude/skills/image-gen/image_gen.py"
exit 0
NPXEOF
    chmod +x "$sub_home/bin/npx"
    BEHAV_STATE="$sub_root/state"; mkdir -p "$BEHAV_STATE"
    env -u CLAUDE_CODE_ENTRYPOINT \
        HOME="$sub_home" USERPROFILE="$sub_home" \
        TMPDIR="$sub_tmp" TMP="$sub_tmp" TEMP="$sub_tmp" \
        BEHAV_HOME="$sub_home" BEHAV_STATE="$BEHAV_STATE" \
        PATH="$sub_home/bin:/usr/bin:/bin" \
        "$PWSH_BIN" -NoProfile -File "$PS1" -All -Force > "$sub_root/sub.log" 2>&1
    if grep -q 'eof' "$BEHAV_STATE/stdin.txt" 2>/dev/null; then
        echo "PASS: ps1-behav: npx stdin detached (EOF)"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: npx stdin not detached"; FAIL=$((FAIL + 1))
    fi
    assert_eq "ps1-behav: npx exact argv" \
        "args:-y skills@latest add sinedied/agent-skills --global --agent claude-code --copy --yes --skill image-gen" \
        "$(cat "$BEHAV_STATE/npx.txt" 2>/dev/null)"
    if [ -f "$sub_home/.claude/.image-gen-sinedied" ]; then
        echo "PASS: ps1-behav: manifest written"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: manifest missing"; FAIL=$((FAIL + 1))
    fi
    if grep -q 'BEGIN claude-code-config' "$sub_home/.claude/skills/image-gen/SKILL.md" 2>/dev/null; then
        echo "PASS: ps1-behav: SKILL.md augmented"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: SKILL.md not augmented"; FAIL=$((FAIL + 1))
    fi
    # No leak into the REAL operator home (generic, no hardcoded path).
    if [ ! -e "$REAL_HOME/.claude/.image-gen-sinedied" ] && [ ! -d "$REAL_HOME/.claude/skills/image-gen" ]; then
        echo "PASS: ps1-behav: no leak into real HOME"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: leak into real HOME ($REAL_HOME)"; FAIL=$((FAIL + 1))
    fi
    rm -rf "$sub_root"

    # --- Dry-run hermeticity (Finding 6): FRESH dedicated HOME+TMP, before/
    # after exact-state snapshot comparison. Distinct from the subprocess dirs.
    dr_root="$(mktemp -d)"; dr_home="$dr_root/home"; dr_tmp="$dr_root/tmp"
    dr_bin="$dr_home/bin"
    mkdir -p "$dr_bin" "$dr_tmp"
    for c in npx claude git curl wget; do printf '#!/usr/bin/env bash\nexit 0\n' > "$dr_bin/$c"; chmod +x "$dr_bin/$c"; done
    # Snapshot BEFORE: full recursive listing of HOME and TMP (only fake stubs).
    dr_home_before="$(find "$dr_home" -mindepth 1 | sort)"
    dr_tmp_before="$(find "$dr_tmp" -mindepth 1 | sort)"
    env -u CLAUDE_CODE_ENTRYPOINT \
        HOME="$dr_home" USERPROFILE="$dr_home" \
        TMPDIR="$dr_tmp" TMP="$dr_tmp" TEMP="$dr_tmp" \
        PATH="$dr_bin:/usr/bin:/bin" \
        "$PWSH_BIN" -NoProfile -File "$PS1" -DryRun -All > "$dr_root/dr.log" 2>&1
    dr_home_after="$(find "$dr_home" -mindepth 1 | sort)"
    dr_tmp_after="$(find "$dr_tmp" -mindepth 1 | sort)"
    if [[ "$dr_home_before" == "$dr_home_after" ]]; then
        echo "PASS: ps1-behav: dry-run HOME state unchanged (before==after)"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: dry-run changed HOME state"; FAIL=$((FAIL + 1))
    fi
    if [[ "$dr_tmp_before" == "$dr_tmp_after" ]]; then
        echo "PASS: ps1-behav: dry-run TMP state unchanged (before==after)"; PASS=$((PASS + 1))
    else
        echo "FAIL: ps1-behav: dry-run changed TMP state"; FAIL=$((FAIL + 1))
    fi
    rm -rf "$dr_root" "$behav_root"
else
    echo "SKIP: pwsh not available - PowerShell behavioral suite (parser, augmentation byte comparison for 7 fixtures, stdin EOF, dry-run before/after state, npx.cmd spaced-path, subprocess, import guard) NOT executed; behavioral parity NOT claimed. Static function-body-scoped assertions + fixture byte contracts above are the authority in this environment."
fi

# ============================================================
# Round 2 / review findings (PowerShell) — deeper static + fixtures
# ============================================================

# --- #1: Install-Agents mkdir guarded; Initialize-ScriptDir remote DryRun ---
AGENTS_BODY="$(ps1_func_body Install-Agents)"
INITSD_BODY="$(ps1_func_body Initialize-ScriptDir)"
if printf '%s' "$AGENTS_BODY" | grep -E 'New-Item.*agentDir' | grep -qv 'DryRun'; then
    echo "FAIL: ps1#2r2: Install-Agents creates agentDir without DryRun guard"; FAIL=$((FAIL + 1))
else
    echo "PASS: ps1#2r2: Install-Agents agentDir creation guarded by DryRun"; PASS=$((PASS + 1))
fi
body_contains "ps1#1r2: Initialize-ScriptDir short-circuits remote in DryRun" "$INITSD_BODY" 'REMOTE_DRY_RUN'
body_contains "ps1#1r2: Initialize-ScriptDir DryRun prints planned source (no download)" "$INITSD_BODY" 'would download'
# Audit: no unguarded New-Item to a CLAUDE_DIR subdir remains in install fns.
unguarded_cnt=0
for fn in Install-Rules Install-Skills Install-Agents Install-Scripts Install-DeepXiv Install-Hooks; do
    fb="$(ps1_func_body "$fn")"
    if printf '%s' "$fb" | grep -E 'New-Item -ItemType Directory' | grep -qv 'DryRun'; then
        unguarded_cnt=$((unguarded_cnt + 1))
    fi
done
assert_eq "ps1#1r2: no install fn has an unguarded New-Item Directory" "0" "$unguarded_cnt"

# --- #3: manifest never falls back to Move-Item over existing ---
# Move-Item must appear EXACTLY once (first-install rename only); the existing
# destination path uses [System.IO.File]::Replace with NO Move fallback.
manifest_move_cnt="$(printf '%s' "$MANIFEST_BODY" | grep -cF 'Move-Item -LiteralPath $tmp -Destination $Manifest -Force')"
assert_eq "ps1#3r2: manifest Move-Item appears exactly once (first-install only)" "1" "$manifest_move_cnt"
body_contains "ps1#3r2: manifest Replace failure returns false (preserves old)" "$MANIFEST_BODY" 'return $false'

# --- #4: byte-offset splice (Latin1 decode, MemoryStream, original bytes) ---
body_contains "ps1#4r2: augment uses Latin1 (byte-preserving) decode" "$AUGMENT_BODY" 'ISO-8859-1'
body_contains "ps1#4r2: augment uses MemoryStream for byte splice" "$AUGMENT_BODY" 'System.IO.MemoryStream'
body_contains "ps1#4r2: augment emits beginBytes from ASCII" "$AUGMENT_BODY" 'GetBytes($begin)'
body_contains "ps1#4r2: augment computes head/tail byte offsets" "$AUGMENT_BODY" 'headEnd'
body_not_contains "ps1#4r2: augment never UTF8-decodes the whole body" "$AUGMENT_BODY" '[System.Text.Encoding]::UTF8.GetString'

# --- #4 fixtures: CR-only + malformed UTF-8 byte contracts ---
assert_fixture_byte "fx: CR-only fixture has CR (0x0d)" "$FX/skill_cr_only.md" 'fixture_has_byte "$FX/skill_cr_only.md" 0d'
assert_fixture_byte "fx: CR-only fixture lacks LF (0x0a)" "$FX/skill_cr_only.md" 'fixture_lacks_byte "$FX/skill_cr_only.md" 0a'
assert_fixture_byte "fx: malformed-UTF8 fixture has invalid byte 0xfe" "$FX/skill_malformed_utf8.md" 'fixture_has_byte "$FX/skill_malformed_utf8.md" fe'
assert_fixture_byte "fx: malformed-UTF8 fixture has invalid byte 0xff" "$FX/skill_malformed_utf8.md" 'fixture_has_byte "$FX/skill_malformed_utf8.md" ff'

# ============================================================
# Round 3 / review findings (PowerShell) — scoped static assertions
# ============================================================

# --- #1: replacement preserves END separator + suffix (tail at separator) ---
body_contains "ps1#1r3: augment tailStart loops through endContentIdx (not +1)" "$AUGMENT_BODY" '$i -le $endContentIdx'

# --- #2: managed block internal newlines normalized to detected style ---
body_contains "ps1#2r3: augment normalizes block newlines to target style" "$AUGMENT_BODY" '-replace "`n", $nlStr'

# --- #3: append final-newline policy (terminated vs not) ---
body_contains "ps1#3r3: append detects terminated body" "$AUGMENT_BODY" '$terminated ='
body_contains "ps1#3r3: append no-final-NL omits trailing separator" "$AUGMENT_BODY" 'if ($terminated)'

# --- #4: remote DryRun never calls Get-SourceVersion with empty SCRIPT_DIR ---
# Find the remote DryRun block specifically and assert it has no ACTUAL call (a
# non-comment line invoking Get-SourceVersion). Comment lines that mention the
# function name while explaining why it is NOT called must not trigger a fail.
remote_dr_block="$(printf '%s\n' "$MAIN_BODY" | awk '/REMOTE_DRY_RUN/{f=1} f{print} /return$/{if(f)exit}')"
if printf '%s' "$remote_dr_block" | grep -vE '^\s*#' | grep -q 'Get-SourceVersion'; then
    echo "FAIL: ps1#4r3: remote DryRun block calls Get-SourceVersion"; FAIL=$((FAIL + 1))
else
    echo "PASS: ps1#4r3: remote DryRun block avoids Get-SourceVersion"; PASS=$((PASS + 1))
fi
body_contains "ps1#4r3: remote DryRun prints safe planned label" "$remote_dr_block" 'would fetch'

# --- #5: import guard around Main invocation ---
if grep -qE 'CLAUDE_CODE_CONFIG_IMPORT_ONLY' "$PS1" 2>/dev/null; then
    echo "PASS: ps1#5r3: import guard env var present in install.ps1"; PASS=$((PASS + 1))
else
    echo "FAIL: ps1#5r3: import guard env var missing"; FAIL=$((FAIL + 1))
fi
main_call_guarded="$(grep -c 'CLAUDE_CODE_CONFIG_IMPORT_ONLY' "$PS1" 2>/dev/null || echo 0)"
# At least 2 occurrences: the comment + the guard conditional.
if [[ "$main_call_guarded" -ge 2 ]]; then
    echo "PASS: ps1#5r3: Main call wrapped in import guard"; PASS=$((PASS + 1))
else
    echo "FAIL: ps1#5r3: Main call not guarded (occurrences=$main_call_guarded)"; FAIL=$((FAIL + 1))
fi

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

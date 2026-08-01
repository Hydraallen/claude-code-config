#!/usr/bin/env bash
# ============================================================
# Unit tests for the PURE GPT CLIProxyAPI key-resolution and
# YAML-rendering helpers in install.sh.
#
# We source install.sh (guarded so main() does not run) and exercise
# the side-effect-free helpers:
#   - gpt_generate_key
#   - gpt_extract_config_key
#   - gpt_extract_profile_token
#   - gpt_resolve_key   (also asserts the GPT_KEY_SOURCE side effect)
#   - gpt_render_config
#
# Fixtures live only under a mktemp -d directory removed by an EXIT
# trap. The tests NEVER print real or recovered key material: generated
# keys are only matched by regex/length, and config/profile fixtures use
# obviously-synthetic literals (e.g. "block-first").
# ============================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$DIR/install.sh"
# install.sh enables `set -euo pipefail`; relax it so assertion failures
# don't abort the whole script and empty/array fixtures are safe.
set +euo pipefail

PASS=0
FAIL=0
TMP=""

cleanup() {
    [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
}
trap cleanup EXIT
TMP="$(mktemp -d)"

# --- assertion helpers ------------------------------------------------------

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

# Regex assertion. Pattern uses Bash =~ semantics (unquoted).
assert_match() {
    local desc="$1" actual="$2" pattern="$3"
    if [[ "$actual" =~ $pattern ]]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        echo "  value did not match /$pattern/"
        FAIL=$((FAIL + 1))
    fi
}

assert_ne() {
    local desc="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        echo "  both values were equal (expected them to differ)"
        FAIL=$((FAIL + 1))
    fi
}

assert_return() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        echo "  expected exit code: $expected"
        echo "  actual exit code:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# Write a fixture file silently. Contents come from stdin.
fixture() {
    local path="$1"
    cat > "$path"
}

# --- Step 1/4: gpt_generate_key --------------------------------------------

gen=$(gpt_generate_key); rc=$?
assert_return "gpt_generate_key exits 0" 0 "$rc"
assert_match "generated key is 32-byte lowercase hex" "$gen" '^[0-9a-f]{64}$'
gen2=$(gpt_generate_key)
assert_ne  "successive generated keys differ" "$gen" "$gen2"
# Length-only sanity check (never print the value itself).
assert_eq  "generated key length is 64" "${#gen}" 64

# --- Step 5/7: gpt_extract_config_key --------------------------------------

# Block sequence, quoted.
cfg="$TMP/block.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - "block-first"
  - "block-second"
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "block sequence: extractor exits 0" 0 "$rc"
assert_eq     "block sequence: first quoted key returned" "block-first" "$out"

# Inline flow sequence.
cfg="$TMP/inline.yaml"
fixture "$cfg" <<'YAML'
api-keys: ["inline-first", "inline-second"]
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "inline sequence: extractor exits 0" 0 "$rc"
assert_eq     "inline sequence: first key returned" "inline-first" "$out"

# Unquoted bare scalar.
cfg="$TMP/bare.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - bare-scalar
  - bare-second
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "bare scalar: extractor exits 0" 0 "$rc"
assert_eq     "bare scalar: first unquoted key returned" "bare-scalar" "$out"

# Empty list -> no key.
cfg="$TMP/empty.yaml"
fixture "$cfg" <<'YAML'
api-keys: []
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "empty list: extractor exits 1" 1 "$rc"
assert_eq     "empty list: nothing printed" "" "$out"

# Trailing comments must not leak into the value.
cfg="$TMP/comment.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - "real-key"   # this is a comment
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "comment: extractor exits 0" 0 "$rc"
assert_eq     "comment: value has no trailing comment" "real-key" "$out"

# Nested api-keys under another mapping MUST be rejected.
cfg="$TMP/nested.yaml"
fixture "$cfg" <<'YAML'
profiles:
  api-keys:
    - nested-key
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "nested api-keys: extractor exits 1" 1 "$rc"
assert_eq     "nested api-keys: nothing printed" "" "$out"

# Placeholder literal YOUR_CLIPROXYAPI_KEY must be rejected.
cfg="$TMP/placeholder.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - YOUR_CLIPROXYAPI_KEY
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "placeholder: extractor exits 1" 1 "$rc"
assert_eq     "placeholder: nothing printed" "" "$out"

# Aliases / anchors must be rejected (ambiguous YAML).
cfg="$TMP/anchor.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - &anchor real-key
  - *anchor
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "anchor/alias: extractor exits 1" 1 "$rc"

# Mapping values inside the sequence must be rejected.
cfg="$TMP/mapping.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - inner: value
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "mapping item: extractor exits 1" 1 "$rc"

# Flow mapping {} must be rejected.
cfg="$TMP/flowmap.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - {}
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "flow mapping: extractor exits 1" 1 "$rc"

# Missing file -> exit 1, nothing printed.
out=$(gpt_extract_config_key "$TMP/does-not-exist.yaml"); rc=$?
assert_return "missing file: extractor exits 1" 1 "$rc"
assert_eq     "missing file: nothing printed" "" "$out"

# --- Step 5/7: gpt_extract_profile_token -----------------------------------

# Concrete token present.
prof="$TMP/profile.json"
fixture "$prof" <<'JSON'
{ "env": { "ANTHROPIC_AUTH_TOKEN": "profile-token-12345" } }
JSON
out=$(gpt_extract_profile_token "$prof"); rc=$?
assert_return "profile token: extractor exits 0" 0 "$rc"
assert_eq     "profile token: value returned" "profile-token-12345" "$out"

# Missing field -> exit 1.
prof="$TMP/profile-missing.json"
fixture "$prof" <<'JSON'
{ "env": { "OTHER": "x" } }
JSON
out=$(gpt_extract_profile_token "$prof"); rc=$?
assert_return "profile token missing: exits 1" 1 "$rc"

# Empty token -> exit 1.
prof="$TMP/profile-empty.json"
fixture "$prof" <<'JSON'
{ "env": { "ANTHROPIC_AUTH_TOKEN": "" } }
JSON
out=$(gpt_extract_profile_token "$prof"); rc=$?
assert_return "profile token empty: exits 1" 1 "$rc"

# Placeholder YOUR_* token -> exit 1.
prof="$TMP/profile-placeholder.json"
fixture "$prof" <<'JSON'
{ "env": { "ANTHROPIC_AUTH_TOKEN": "YOUR_TOKEN_HERE" } }
JSON
out=$(gpt_extract_profile_token "$prof"); rc=$?
assert_return "profile token placeholder: exits 1" 1 "$rc"

# Missing file -> exit 1.
out=$(gpt_extract_profile_token "$TMP/nope.json"); rc=$?
assert_return "profile token missing file: exits 1" 1 "$rc"

# --- Step 8/9: gpt_resolve_key precedence + GPT_KEY_SOURCE -----------------

# Build fixtures for the precedence cases.
cfg_ok="$TMP/cfg-ok.yaml"
fixture "$cfg_ok" <<'YAML'
api-keys:
  - "config-key"
YAML
prof_ok="$TMP/prof-ok.json"
fixture "$prof_ok" <<'JSON'
{ "env": { "ANTHROPIC_AUTH_TOKEN": "profile-key" } }
JSON
cfg_empty="$TMP/cfg-empty.yaml"
fixture "$cfg_empty" <<'YAML'
api-keys: []
YAML

# Case A: config wins over profile. Call WITHOUT command substitution so
# GPT_KEY_SOURCE is set in this shell.
GPT_KEY_SOURCE=""
gpt_resolve_key "$cfg_ok" "$prof_ok" > "$TMP/outA"
keyA=$(cat "$TMP/outA")
assert_eq "precedence: config key wins over profile" "config-key" "$keyA"
assert_eq "precedence: source is config" "config" "$GPT_KEY_SOURCE"

# Case B: no valid config -> falls back to profile.
GPT_KEY_SOURCE=""
gpt_resolve_key "$cfg_empty" "$prof_ok" > "$TMP/outB"
keyB=$(cat "$TMP/outB")
assert_eq "precedence: profile fallback" "profile-key" "$keyB"
assert_eq "precedence: source is profile" "profile" "$GPT_KEY_SOURCE"

# Case C: neither resolves -> generated key (64 hex), source = generated.
GPT_KEY_SOURCE=""
gpt_resolve_key "$cfg_empty" "$TMP/nope.json" > "$TMP/outC"
keyC=$(cat "$TMP/outC")
assert_match "precedence: generated key is 64 lowercase hex" "$keyC" '^[0-9a-f]{64}$'
assert_eq     "precedence: source is generated" "generated" "$GPT_KEY_SOURCE"

# --- Step 8/9: gpt_render_config -------------------------------------------

expected_render='host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "synthetic-key"'

out=$(gpt_render_config "synthetic-key"); rc=$?
assert_return "render: exits 0 for non-empty key" 0 "$rc"
assert_eq     "render: byte-for-byte normalized YAML" "$expected_render" "$out"

# Empty key must be rejected.
out=$(gpt_render_config ""); rc=$?
assert_return "render: rejects empty key" 1 "$rc"
assert_eq     "render: empty key prints nothing" "" "$out"

# Deferred reviewer fix: `api-keys: # comment` followed by a block list must
# yield the first block key, not the comment text.
cfg="$TMP/apikeys-comment.yaml"
fixture "$cfg" <<'YAML'
api-keys: # leading comment
  - "after-comment"
  - "second"
YAML
out=$(gpt_extract_config_key "$cfg"); rc=$?
assert_return "api-keys comment header: extractor exits 0" 0 "$rc"
assert_eq     "api-keys comment header: first block key returned" "after-comment" "$out"

# ===========================================================================
# Task 2: atomic backup / write / profile-sync / coordinator
# ===========================================================================

# Portable file-mode helper (brief Step 1).
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# --- Task 2 Step 1: gpt_backup_file ----------------------------------------

bkdir="$TMP/bk"
mkdir -p "$bkdir"
bkfile="$bkdir/config.yaml"
printf 'original-bytes\n' > "$bkfile"
chmod 644 "$bkfile"
bakout=$(gpt_backup_file "$bkfile"); rc=$?
assert_return "backup: exits 0 on success" 0 "$rc"
assert_match "backup: name is <base>.YYYYMMDDHHMMSS.bak" "$(basename "$bakout")" '^config\.yaml\.[0-9]{14}\.bak$'
assert_eq     "backup: mode is 600" "600" "$(file_mode "$bakout")"
assert_eq     "backup: original file unchanged" "original-bytes" "$(cat "$bkfile")"
assert_eq     "backup: backup content matches original" "original-bytes" "$(cat "$bakout")"

# Forced backup failure via unwritable target directory.
rodir="$TMP/robk"; mkdir -p "$rodir"
printf 'keep-me\n' > "$rodir/config.yaml"
chmod 500 "$rodir"
rbak=$(gpt_backup_file "$rodir/config.yaml" 2>/dev/null); rcbk=$?
chmod 700 "$rodir"   # restore so the EXIT trap can clean up
assert_return "backup failure: exits 1" 1 "$rcbk"
assert_eq     "backup failure: original bytes unchanged" "keep-me" "$(cat "$rodir/config.yaml")"

# --- Task 2 Step 1: gpt_atomic_write ---------------------------------------

atfile="$TMP/atomic.yaml"
printf 'before\n' > "$atfile"
# Command substitution below strips a trailing newline, so compare against the
# newline-stripped form; the byte-exact write is verified separately via wc.
gpt_atomic_write "$atfile" "after-content
"; rcw=$?
assert_return "atomic write: exits 0 on success" 0 "$rcw"
assert_eq     "atomic write: content written" "after-content" "$(cat "$atfile")"
assert_eq     "atomic write: byte count includes trailing newline" "14" "$(wc -c < "$atfile" | tr -d ' ')"
assert_eq     "atomic write: mode is 600" "600" "$(file_mode "$atfile")"

# Forced atomic-write failure via unwritable directory: original bytes intact
# and no temp file left behind.
rodir2="$TMP/roat"; mkdir -p "$rodir2"
printf 'preserved\n' > "$rodir2/config.yaml"
chmod 500 "$rodir2"
gpt_atomic_write "$rodir2/config.yaml" "new-content" 2>/dev/null; rcwf=$?
chmod 700 "$rodir2"
assert_return "atomic write failure: exits 1" 1 "$rcwf"
assert_eq     "atomic write failure: original bytes unchanged" "preserved" "$(cat "$rodir2/config.yaml")"
tmpcount=$(find "$rodir2" -name 'config.yaml.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq     "atomic write failure: no temp file left" "0" "$tmpcount"

# --- Task 2 Step 4: gpt_sync_profile_token ---------------------------------

GPT_FIXTURE="$TMP/gpt_full.json"
fixture "$GPT_FIXTURE" <<'JSON'
{
  "service": "claude-code",
  "credentialKeys": ["ANTHROPIC_AUTH_TOKEN"],
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
    "ANTHROPIC_AUTH_TOKEN": "YOUR_GPT_TOKEN"
  },
  "unset": ["OPENAI_API_KEY"],
  "note": "GPT CLIProxyAPI profile",
  "models": { "default": "gpt-4o", "large": "gpt-4o-large" }
}
JSON

sync_prof="$TMP/sync_prof.json"
cp "$GPT_FIXTURE" "$sync_prof"
pre_service=$(jq -r '.service'            "$sync_prof")
pre_keys=$(jq -c '.credentialKeys'        "$sync_prof")
pre_url=$(jq -r '.env.ANTHROPIC_BASE_URL' "$sync_prof")
pre_unset=$(jq -c '.unset'                "$sync_prof")
pre_note=$(jq -r '.note'                  "$sync_prof")
pre_models=$(jq -c '.models'              "$sync_prof")
gpt_sync_profile_token "$sync_prof" "new-sync-token"; rcs=$?
assert_return "sync: exits 0" 0 "$rcs"
assert_eq     "sync: token updated"            "new-sync-token" "$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$sync_prof")"
assert_eq     "sync: service unchanged"        "$pre_service"   "$(jq -r '.service' "$sync_prof")"
assert_eq     "sync: credentialKeys unchanged" "$pre_keys"      "$(jq -c '.credentialKeys' "$sync_prof")"
assert_eq     "sync: BASE_URL unchanged"       "$pre_url"       "$(jq -r '.env.ANTHROPIC_BASE_URL' "$sync_prof")"
assert_eq     "sync: unset unchanged"          "$pre_unset"     "$(jq -c '.unset' "$sync_prof")"
assert_eq     "sync: note unchanged"           "$pre_note"      "$(jq -r '.note' "$sync_prof")"
assert_eq     "sync: models unchanged"         "$pre_models"    "$(jq -c '.models' "$sync_prof")"
assert_eq     "sync: profile mode 600"         "600"            "$(file_mode "$sync_prof")"

# Idempotent: re-sync same token, no change, still 0.
gpt_sync_profile_token "$sync_prof" "new-sync-token"; rcs2=$?
assert_return "sync: idempotent re-sync exits 0" 0 "$rcs2"
assert_eq     "sync: idempotent token value" "new-sync-token" "$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$sync_prof")"

# Invalid JSON must be rejected and original bytes preserved.
bad_prof="$TMP/bad.json"
printf 'this is not json' > "$bad_prof"
bad_before=$(wc -c < "$bad_prof" | tr -d ' ')
gpt_sync_profile_token "$bad_prof" "x" 2>/dev/null; rcbad=$?
assert_return     "sync invalid JSON: exits 1" 1 "$rcbad"
assert_eq         "sync invalid JSON: bytes preserved" "$bad_before" "$(wc -c < "$bad_prof" | tr -d ' ')"

# Forced atomic failure must preserve original profile bytes.
rodir3="$TMP/rosync"; mkdir -p "$rodir3"
cp "$GPT_FIXTURE" "$rodir3/gpt.json"
ro_before=$(cat "$rodir3/gpt.json")
chmod 500 "$rodir3"
gpt_sync_profile_token "$rodir3/gpt.json" "should-not-write" 2>/dev/null; rcrs=$?
chmod 700 "$rodir3"
assert_return "sync forced failure: exits 1" 1 "$rcrs"
assert_eq     "sync forced failure: bytes preserved" "$ro_before" "$(cat "$rodir3/gpt.json")"

# --- Task 2 Step 6: configure_gpt_backend integration ----------------------

# Isolation helper: lay down a fresh HOME with an installed gpt profile.
setup_gpt_home() {
    local home="$1"
    rm -rf "$home"
    mkdir -p "$home/.claude/profiles" "$home/.cli-proxy-api"
    cp "$GPT_FIXTURE" "$home/.claude/profiles/gpt.json"
}

# Runner: each case script is written with a QUOTED heredoc (<<'SH') so the
# outer test shell does NOT expand inner variables; CASE_HOME and DIR are
# delivered through the environment instead.
run_case() {
    local name="$1" file="$2" home="$3"
    if CASE_HOME="$home" DIR="$DIR" bash "$file" >/dev/null 2>&1; then
        echo "PASS: $name"
        PASS=$((PASS+1))
    else
        echo "FAIL: $name"
        CASE_HOME="$home" DIR="$DIR" bash "$file"
        FAIL=$((FAIL+1))
    fi
}

# mk_case <file> <home>: write a case prologue that hard-wires the isolated
# roots for a single `bash <file>` invocation. The case body is appended by
# each Case block below via a QUOTED heredoc (<<'SH') so no outer expansion
# leaks in.
mk_case() {
    local file="$1" home="$2"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo "source \"$DIR/install.sh\"; set +euo pipefail"
        echo "HOME=\"$home\"; CLAUDE_DIR=\"$home/.claude\""
        echo "GPT_CONFIG_DIR=\"$home/.cli-proxy-api\"; GPT_PROFILE=\"$home/.claude/profiles/gpt.json\""
        echo 'export HOME CLAUDE_DIR GPT_CONFIG_DIR GPT_PROFILE'
        echo 'SELECTED_PROFILES=("gpt")'
        echo 'file_mode() { stat -f "%Lp" "$1" 2>/dev/null || stat -c "%a" "$1" 2>/dev/null; }'
    } > "$file"
}
rm -f "$TMP/preamble.sh" "$TMP/c1.sh"

# Case 1: fresh install -> dir 700, config/profile share generated key, 600.
CASE_HOME="$TMP/c1"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c1.sh" "$CASE_HOME"
cat >> "$TMP/c1.sh" <<'SH'
DRY_RUN=false configure_gpt_backend
cfg="$GPT_CONFIG_DIR/config.yaml"
[[ "$(file_mode "$GPT_CONFIG_DIR")" == "700" ]]
[[ "$(file_mode "$cfg")" == "600" ]]
[[ "$(file_mode "$GPT_PROFILE")" == "600" ]]
ck=$(gpt_extract_config_key "$cfg")
pt=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$GPT_PROFILE")
[[ "$ck" == "$pt" ]]
[[ "$ck" =~ ^[0-9a-f]{64}$ ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c1.sh" >/dev/null 2>&1 && { echo "PASS: c1 fresh install"; PASS=$((PASS+1)); } || { echo "FAIL: c1 fresh install"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c1.sh"; FAIL=$((FAIL+1)); }

# Case 2: second run preserves key, no backup created.
CASE_HOME="$TMP/c2"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c2.sh" "$CASE_HOME"
cat >> "$TMP/c2.sh" <<'SH'
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
first=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
DRY_RUN=false configure_gpt_backend
second=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
[[ "$first" == "$second" ]]
nb=$(find "$GPT_CONFIG_DIR" -name 'config.yaml.*.bak' | wc -l | tr -d ' ')
[[ "$nb" == "0" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c2.sh" >/dev/null 2>&1 && { echo "PASS: c2 idempotent second run"; PASS=$((PASS+1)); } || { echo "FAIL: c2 idempotent second run"; FAIL=$((FAIL+1)); }

# Case 3: existing block key is reused.
CASE_HOME="$TMP/c3"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c3.sh" "$CASE_HOME"
cat >> "$TMP/c3.sh" <<'SH'
printf 'api-keys:\n  - "reuse-block-key"\n' > "$GPT_CONFIG_DIR/config.yaml"
DRY_RUN=false configure_gpt_backend
ck=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
pt=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$GPT_PROFILE")
[[ "$ck" == "reuse-block-key" ]]
[[ "$pt" == "reuse-block-key" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c3.sh" >/dev/null 2>&1 && { echo "PASS: c3 block key reused"; PASS=$((PASS+1)); } || { echo "FAIL: c3 block key reused"; FAIL=$((FAIL+1)); }

# Case 4: multiple keys -> backup created, normalized to first.
CASE_HOME="$TMP/c4"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c4.sh" "$CASE_HOME"
cat >> "$TMP/c4.sh" <<'SH'
printf 'api-keys:\n  - "first-of-many"\n  - "second-of-many"\n' > "$GPT_CONFIG_DIR/config.yaml"
DRY_RUN=false configure_gpt_backend
ck=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
[[ "$ck" == "first-of-many" ]]
nb=$(find "$GPT_CONFIG_DIR" -name 'config.yaml.*.bak' | wc -l | tr -d ' ')
[[ "$nb" -ge 1 ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c4.sh" >/dev/null 2>&1 && { echo "PASS: c4 multi-key normalized + backed up"; PASS=$((PASS+1)); } || { echo "FAIL: c4 multi-key normalized + backed up"; FAIL=$((FAIL+1)); }

# Case 5: config/profile conflict -> config key wins.
CASE_HOME="$TMP/c5"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c5.sh" "$CASE_HOME"
cat >> "$TMP/c5.sh" <<'SH'
printf 'api-keys:\n  - "config-wins"\n' > "$GPT_CONFIG_DIR/config.yaml"
jq '.env.ANTHROPIC_AUTH_TOKEN = "profile-loses"' "$GPT_PROFILE" > "$GPT_PROFILE.tmp" && mv "$GPT_PROFILE.tmp" "$GPT_PROFILE"
DRY_RUN=false configure_gpt_backend
pt=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$GPT_PROFILE")
[[ "$pt" == "config-wins" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c5.sh" >/dev/null 2>&1 && { echo "PASS: c5 config key wins"; PASS=$((PASS+1)); } || { echo "FAIL: c5 config key wins"; FAIL=$((FAIL+1)); }

# Case 6: config lacks key, profile has token -> profile token used.
CASE_HOME="$TMP/c6"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c6.sh" "$CASE_HOME"
cat >> "$TMP/c6.sh" <<'SH'
printf 'api-keys: []\n' > "$GPT_CONFIG_DIR/config.yaml"
jq '.env.ANTHROPIC_AUTH_TOKEN = "from-profile-token"' "$GPT_PROFILE" > "$GPT_PROFILE.tmp" && mv "$GPT_PROFILE.tmp" "$GPT_PROFILE"
DRY_RUN=false configure_gpt_backend
ck=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
[[ "$ck" == "from-profile-token" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c6.sh" >/dev/null 2>&1 && { echo "PASS: c6 profile token used"; PASS=$((PASS+1)); } || { echo "FAIL: c6 profile token used"; FAIL=$((FAIL+1)); }

# Case 7: malformed/custom config backed up and normalized.
CASE_HOME="$TMP/c7"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c7.sh" "$CASE_HOME"
cat >> "$TMP/c7.sh" <<'SH'
printf 'custom: value\napi-keys:\n  - "norm-first"\n  - "norm-second"\nextra: true\n' > "$GPT_CONFIG_DIR/config.yaml"
DRY_RUN=false configure_gpt_backend
ck=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
[[ "$ck" == "norm-first" ]]
nb=$(find "$GPT_CONFIG_DIR" -name 'config.yaml.*.bak' | wc -l | tr -d ' ')
[[ "$nb" -ge 1 ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c7.sh" >/dev/null 2>&1 && { echo "PASS: c7 custom config backed up + normalized"; PASS=$((PASS+1)); } || { echo "FAIL: c7 custom config backed up + normalized"; FAIL=$((FAIL+1)); }

# Case 8: DRY_RUN creates nothing, generates nothing, emits no secret.
CASE_HOME="$TMP/c8"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c8.sh" "$CASE_HOME"
cat >> "$TMP/c8.sh" <<'SH'
pre_prof=$(cat "$GPT_PROFILE")
out=$(DRY_RUN=true configure_gpt_backend 2>&1)
[[ ! -e "$GPT_CONFIG_DIR/config.yaml" ]]
post_prof=$(cat "$GPT_PROFILE")
[[ "$pre_prof" == "$post_prof" ]]
[[ "$out" != *[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]* ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c8.sh" >/dev/null 2>&1 && { echo "PASS: c8 dry run"; PASS=$((PASS+1)); } || { echo "FAIL: c8 dry run"; FAIL=$((FAIL+1)); }

# Case 9: backup failure -> critical recorded, config/profile preserved.
# Inject failure via a test-only gpt_backup_file stub (brief Step 1 sanctions
# stubs over touching real paths), so the coordinator's dir chmod can't mask
# the fault.
CASE_HOME="$TMP/c9"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c9.sh" "$CASE_HOME"
cat >> "$TMP/c9.sh" <<'SH'
printf 'api-keys:\n  - "preserve-me"\n  - "second"\n' > "$GPT_CONFIG_DIR/config.yaml"
prof_before=$(cat "$GPT_PROFILE")
cfg_before=$(cat "$GPT_CONFIG_DIR/config.yaml")
gpt_backup_file() { return 1; }   # forced backup failure
DRY_RUN=false configure_gpt_backend 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]
[[ $INSTALL_CRITICAL -ge 1 ]]
[[ "$(cat "$GPT_CONFIG_DIR/config.yaml")" == "$cfg_before" ]]
[[ "$(cat "$GPT_PROFILE")" == "$prof_before" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c9.sh" >/dev/null 2>&1 && { echo "PASS: c9 backup failure preserved"; PASS=$((PASS+1)); } || { echo "FAIL: c9 backup failure preserved"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c9.sh"; FAIL=$((FAIL+1)); }

# Case 10: captured stdout/stderr does not contain the resolved key.
CASE_HOME="$TMP/c10"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c10.sh" "$CASE_HOME"
cat >> "$TMP/c10.sh" <<'SH'
out=$(DRY_RUN=false configure_gpt_backend 2>&1)
ck=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
[[ -n "$ck" ]]
[[ "$out" != *"$ck"* ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c10.sh" >/dev/null 2>&1 && { echo "PASS: c10 no secret in output"; PASS=$((PASS+1)); } || { echo "FAIL: c10 no secret in output"; FAIL=$((FAIL+1)); }

# --- Final fix wave: verified security and selection findings ---------------

# Unsafe tokens from either reuse source are rejected. A malicious profile
# value must never become YAML; precedence falls through to generation.
for bad in 'quote"break' 'slash\break' 'hash#comment' 'colon: value'; do
    prof="$TMP/profile-unsafe.json"
    jq -n --arg token "$bad" '{env:{ANTHROPIC_AUTH_TOKEN:$token}}' > "$prof"
    out=$(gpt_extract_profile_token "$prof"); rc=$?
    assert_return "unsafe profile token rejected: $bad" 1 "$rc"
done
prof="$TMP/profile-control.json"
printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"line\\nbreak"}}\n' > "$prof"
out=$(gpt_extract_profile_token "$prof"); rc=$?
assert_return "profile token containing newline rejected" 1 "$rc"

CASE_HOME="$TMP/final-malicious"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/final-malicious.sh" "$CASE_HOME"
cat >> "$TMP/final-malicious.sh" <<'SH'
printf 'api-keys: []\n' > "$GPT_CONFIG_DIR/config.yaml"
jq --arg k 'bad"\ninjected: true' '.env.ANTHROPIC_AUTH_TOKEN = $k' "$GPT_PROFILE" > "$GPT_PROFILE.tmp" && mv "$GPT_PROFILE.tmp" "$GPT_PROFILE"
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
! grep -q 'injected:' "$GPT_CONFIG_DIR/config.yaml"
key=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
[[ "$key" =~ ^[0-9a-f]{64}$ ]]
SH
run_case "malicious profile token cannot inject YAML" "$TMP/final-malicious.sh" "$CASE_HOME"

# Idempotent reconciliation repairs modes even when bytes need no rewrite.
CASE_HOME="$TMP/final-modes"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/final-modes.sh" "$CASE_HOME"
cat >> "$TMP/final-modes.sh" <<'SH'
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
chmod 644 "$GPT_CONFIG_DIR/config.yaml" "$GPT_PROFILE"
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
[[ "$(file_mode "$GPT_CONFIG_DIR/config.yaml")" == 600 ]]
[[ "$(file_mode "$GPT_PROFILE")" == 600 ]]
SH
run_case "idempotent config/profile modes repaired to 600" "$TMP/final-modes.sh" "$CASE_HOME"

# Any credential-artifact chmod failure is critical and suppresses success.
CASE_HOME="$TMP/final-chmod"; setup_gpt_home "$CASE_HOME"
mkdir -p "$CASE_HOME/.claude/profiles/.baseline"
cp "$GPT_FIXTURE" "$CASE_HOME/.claude/profiles/.baseline/gpt.json"
mk_case "$TMP/final-chmod.sh" "$CASE_HOME"
cat >> "$TMP/final-chmod.sh" <<'SH'
real_chmod=$(command -v chmod)
chmod() {
    case "$*" in *'.baseline/gpt.json'*) return 1 ;; esac
    "$real_chmod" "$@"
}
out=$(DRY_RUN=false configure_gpt_backend 2>&1); rc=$?
[[ $rc -ne 0 ]]
[[ $INSTALL_CRITICAL -ge 1 ]]
[[ "$out" != *'backend configured'* ]]
SH
run_case "artifact chmod failure is critical without success" "$TMP/final-chmod.sh" "$CASE_HOME"

# With xtrace enabled, neither the key nor the token-bearing normalized JSON may
# appear on stderr. The caller's xtrace state must be restored afterward.
CASE_HOME="$TMP/final-xtrace"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/final-xtrace.sh" "$CASE_HOME"
cat >> "$TMP/final-xtrace.sh" <<'SH'
secret='synthetic-xtrace-key-1234567890'
printf 'api-keys:\n  - "%s"\n' "$secret" > "$GPT_CONFIG_DIR/config.yaml"
set -x
DRY_RUN=false configure_gpt_backend 2>"$CASE_HOME/trace.err"
case $- in *x*) : ;; *) exit 1 ;; esac
set +x
! grep -Fq "$secret" "$CASE_HOME/trace.err"
! grep -Fq '"ANTHROPIC_AUTH_TOKEN":' "$CASE_HOME/trace.err"
SH
run_case "xtrace does not leak GPT secrets and is restored" "$TMP/final-xtrace.sh" "$CASE_HOME"

# A stale installed gpt profile is irrelevant when this invocation did not
# select gpt. The guard must return before probing config/profile contents.
CASE_HOME="$TMP/final-guard"; setup_gpt_home "$CASE_HOME"
printf 'sentinel-config\n' > "$CASE_HOME/.cli-proxy-api/config.yaml"
printf 'sentinel-profile\n' > "$CASE_HOME/.claude/profiles/gpt.json"
mk_case "$TMP/final-guard.sh" "$CASE_HOME"
cat >> "$TMP/final-guard.sh" <<'SH'
SELECTED_PROFILES=("glm" "ccr")
config_before=$(cat "$GPT_CONFIG_DIR/config.yaml")
profile_before=$(cat "$GPT_PROFILE")
jq() { echo 'jq must not be called' >&2; return 99; }
out=$(DRY_RUN=false configure_gpt_backend 2>&1); rc=$?
[[ $rc -eq 0 ]]
[[ -z "$out" ]]
[[ "$(cat "$GPT_CONFIG_DIR/config.yaml")" == "$config_before" ]]
[[ "$(cat "$GPT_PROFILE")" == "$profile_before" ]]
SH
run_case "unselected stale gpt profile is a no-op" "$TMP/final-guard.sh" "$CASE_HOME"

# --- Fix round: auth-dir honors GPT_CONFIG_DIR -----------------------------

# Renderer accepts an optional auth_dir; default is still ~/.cli-proxy-api.
out=$(gpt_render_config "synthetic-key" "/custom/path"); rc=$?
assert_return "render: custom auth_dir exits 0" 0 "$rc"
assert_eq     "render: custom auth_dir rendered" 'auth-dir: "/custom/path"' "$(printf '%s\n' "$out" | sed -n '/^auth-dir:/p')"

out=$(gpt_render_config "synthetic-key")
assert_eq     "render: default auth_dir unchanged" 'auth-dir: "~/.cli-proxy-api"' "$(printf '%s\n' "$out" | sed -n '/^auth-dir:/p')"

# Unsafe auth_dir (embedded double-quote) is rejected and never emitted.
out=$(gpt_render_config "synthetic-key" 'bad"dir'); rc=$?
assert_return "render: unsafe auth_dir rejected" 1 "$rc"
assert_eq     "render: unsafe auth_dir prints nothing" "" "$out"

# Coordinator end-to-end: custom GPT_CONFIG_DIR is reflected in config.yaml.
CASE_HOME="$TMP/c11"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c11.sh" "$CASE_HOME"
cat >> "$TMP/c11.sh" <<'SH'
GPT_CONFIG_DIR="$CASE_HOME/custom-proxy"
export GPT_CONFIG_DIR
DRY_RUN=false configure_gpt_backend
cfg="$GPT_CONFIG_DIR/config.yaml"
[[ -f "$cfg" ]]
grep -q '^auth-dir: "'"$CASE_HOME/custom-proxy"'"$' "$cfg"
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c11.sh" >/dev/null 2>&1 && { echo "PASS: c11 custom GPT_CONFIG_DIR reflected in auth-dir"; PASS=$((PASS+1)); } || { echo "FAIL: c11 custom GPT_CONFIG_DIR reflected in auth-dir"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c11.sh"; FAIL=$((FAIL+1)); }

# --- Fix round: need_config_write=false + profile sync failure -------------

# Config is already normalized (so need_config_write=false), the profile token
# is drifted, and the atomic write is stubbed to fail. The config must be left
# byte-for-byte intact (no rollback rewrite either) and the profile untouched.
CASE_HOME="$TMP/c12"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/c12.sh" "$CASE_HOME"
cat >> "$TMP/c12.sh" <<'SH'
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
key=$(gpt_extract_config_key "$GPT_CONFIG_DIR/config.yaml")
cfg_before=$(cat "$GPT_CONFIG_DIR/config.yaml")
# Drift the profile token so the next run must sync it.
jq --arg k "${key}-x" '.env.ANTHROPIC_AUTH_TOKEN = $k' "$GPT_PROFILE" > "$GPT_PROFILE.tmp" && mv "$GPT_PROFILE.tmp" "$GPT_PROFILE"
prof_before=$(cat "$GPT_PROFILE")
gpt_atomic_write() { return 1; }   # force profile sync failure
DRY_RUN=false configure_gpt_backend 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]
[[ $INSTALL_CRITICAL -ge 1 ]]
[[ "$(cat "$GPT_CONFIG_DIR/config.yaml")" == "$cfg_before" ]]
[[ "$(cat "$GPT_PROFILE")" == "$prof_before" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c12.sh" >/dev/null 2>&1 && { echo "PASS: c12 need_config_write=false + sync failure preserves bytes"; PASS=$((PASS+1)); } || { echo "FAIL: c12 need_config_write=false + sync failure preserves bytes"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/c12.sh"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------

# ===========================================================================
# Task 4: installer hints + cross-platform boundary
# ===========================================================================
#
# backend_setup_hints must special-case the GPT/CLIProxyAPI profile: its key
# is reconciled by configure_gpt_backend, so the user never invents or pastes
# one. Binary install + OAuth (`cliproxyapi --codex-login`) are still required
# even when the key is already in place. These assertions exercise both the
# configured and the not-yet-reconciled fixtures through the same mk_case
# harness the coordinator cases use, so HOME/CLAUDE_DIR/GPT_CONFIG_DIR are
# wired identically.

# A deliberately-synthetic 64-hex key shared between config and profile. NEVER
# printed by the assertions; only matched by negation (`!= *"$KEY"*`).
H4_KEY="deadbeefcafebabe1111222233334444555566667777888899990000aaaabbbb"
export H4_KEY

# --- h4a: configured gpt (config.yaml + profile share a concrete key) -------
CASE_HOME="$TMP/h4a"
rm -rf "$CASE_HOME"
mkdir -p "$CASE_HOME/.claude/profiles" "$CASE_HOME/.cli-proxy-api"
printf 'api-keys:\n  - "%s"\n' "$H4_KEY" > "$CASE_HOME/.cli-proxy-api/config.yaml"
fixture "$CASE_HOME/.claude/profiles/gpt.json" <<JSON
{
  "label": "ChatGPT subscription (Codex OAuth via CLIProxyAPI)",
  "credentialKeys": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"],
  "service": {
    "label": "CLIProxyAPI",
    "bins": ["cli-proxy-api", "cliproxyapi", "CLIProxyAPI"],
    "installHint": "brew install cliproxyapi",
    "loginHint": "{bin} --codex-login    # one-time browser authorization of your ChatGPT account"
  },
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "$H4_KEY",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317"
  }
}
JSON
mk_case "$TMP/h4a.sh" "$CASE_HOME"
cat >> "$TMP/h4a.sh" <<'SH'
out=$(backend_setup_hints 1 2>&1)
# 1. OAuth login step is still advertised.
[[ "$out" == *"--codex-login"* ]]            || { echo "FAIL: h4a codex-login missing"; exit 1; }
# 2. No paste/edit-key instruction (coordinator owns the key).
[[ "$out" != *"env.ANTHROPIC_AUTH_TOKEN"* ]] || { echo "FAIL: h4a key-paste field leaked"; exit 1; }
[[ "$out" != *"/ 密钥:"* ]]                   || { echo "FAIL: h4a 密钥 step present"; exit 1; }
# 3. No placeholder literal.
[[ "$out" != *"YOUR_"* ]]                    || { echo "FAIL: h4a YOUR_ leaked"; exit 1; }
# 4. The resolved key never appears in the hint output.
[[ "$out" != *"$H4_KEY"* ]]                  || { echo "FAIL: h4a secret in output"; exit 1; }
# 5. Configuration completion is reported.
[[ "$out" == *"auto-config complete"* ]]     || { echo "FAIL: h4a no completion notice"; exit 1; }
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/h4a.sh" >/dev/null 2>&1 && { echo "PASS: h4a configured gpt hint"; PASS=$((PASS+1)); } || { echo "FAIL: h4a configured gpt hint"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/h4a.sh"; FAIL=$((FAIL+1)); }

# --- h4b: pending gpt (placeholder token, no config.yaml) ------------------
CASE_HOME="$TMP/h4b"
rm -rf "$CASE_HOME"
mkdir -p "$CASE_HOME/.claude/profiles"
fixture "$CASE_HOME/.claude/profiles/gpt.json" <<JSON
{
  "label": "ChatGPT subscription (Codex OAuth via CLIProxyAPI)",
  "credentialKeys": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"],
  "service": {
    "label": "CLIProxyAPI",
    "bins": ["cli-proxy-api", "cliproxyapi", "CLIProxyAPI"],
    "installHint": "brew install cliproxyapi",
    "loginHint": "{bin} --codex-login    # one-time browser authorization of your ChatGPT account"
  },
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "YOUR_CLIPROXYAPI_KEY",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317"
  }
}
JSON
mk_case "$TMP/h4b.sh" "$CASE_HOME"
cat >> "$TMP/h4b.sh" <<'SH'
out=$(backend_setup_hints 1 2>&1)
[[ "$out" == *"--codex-login"* ]]            || { echo "FAIL: h4b codex-login missing"; exit 1; }
[[ "$out" != *"env.ANTHROPIC_AUTH_TOKEN"* ]] || { echo "FAIL: h4b key-paste field leaked"; exit 1; }
[[ "$out" != *"/ 密钥:"* ]]                   || { echo "FAIL: h4b 密钥 step present"; exit 1; }
[[ "$out" != *"YOUR_CLIPROXYAPI_KEY"* ]]     || { echo "FAIL: h4b placeholder value leaked"; exit 1; }
# Reconciliation-failure path: exact config + profile paths printed, with rerun.
[[ "$out" == *"config.yaml"* ]]               || { echo "FAIL: h4b no config path"; exit 1; }
[[ "$out" == *"gpt.json"* ]]                 || { echo "FAIL: h4b no profile path"; exit 1; }
[[ "$out" == *"re-run"* ]]                   || { echo "FAIL: h4b no rerun instruction"; exit 1; }
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/h4b.sh" >/dev/null 2>&1 && { echo "PASS: h4b pending gpt hint"; PASS=$((PASS+1)); } || { echo "FAIL: h4b pending gpt hint"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/h4b.sh"; FAIL=$((FAIL+1)); }

# --- h4c: install.ps1 static cross-platform boundary ----------------------
PS1_FILE="$DIR/install.ps1"
if grep -q 'macOS/Linux only' "$PS1_FILE" && grep -q 'cl_gpt' "$PS1_FILE" && grep -q 'BACKENDS.md' "$PS1_FILE"; then
    echo "PASS: h4c ps1 states macOS/Linux-only boundary"; PASS=$((PASS+1))
else
    echo "FAIL: h4c ps1 states macOS/Linux-only boundary"; FAIL=$((FAIL+1))
fi
# install.ps1 must NOT create or write the cli-proxy-api config (Windows has
# no cl_gpt runtime; the config is produced only by the Bash coordinator).
if grep -Eq 'cli-proxy-api/config\.ya?ml' "$PS1_FILE"; then
    echo "FAIL: h4c ps1 references cli-proxy-api config path"; FAIL=$((FAIL+1))
else
    echo "PASS: h4c ps1 free of cli-proxy-api config writes"; PASS=$((PASS+1))
fi

# Drive the Zsh runtime-diagnostic suite (Task 3). The launcher is zsh-only,
# so its behavioural tests live in a separate .zsh file; surface their result
# here so the single Bash entry point reports the whole picture. A missing
# zsh binary is reported but not counted as a Bash-suite failure, since the
# Bash helpers themselves do not depend on zsh.
if [[ -x "$DIR/tests/test_gpt_runtime.zsh" ]] && command -v zsh >/dev/null 2>&1; then
    echo "=== Invoking Zsh runtime suite (test_gpt_runtime.zsh) ==="
    if zsh "$DIR/tests/test_gpt_runtime.zsh"; then
        :
    else
        FAIL=$((FAIL + 1))
    fi
    echo ""
elif ! command -v zsh >/dev/null 2>&1; then
    echo "=== Skipping Zsh runtime suite: zsh not on PATH ==="
else
    echo "=== Skipping Zsh runtime suite: $DIR/tests/test_gpt_runtime.zsh not found ==="
fi

# ===========================================================================
# Task 5 fix: config.yaml extension contract (static + integration)
# ===========================================================================
#
# claude.zsh launches CLIProxyAPI with the path baked into profiles/gpt.json
# `.service.configFile` / `.service.start` — which is config.yaml. The
# install.sh coordinator MUST write to exactly that path; a config.yml default
# would produce a file the launcher never reads (hard exit on a fresh install).
# Lock the contract statically and through the integration cases above (their
# config paths were updated to config.yaml to mirror the launcher).

# Profile declares config.yaml basename (not config.yml).
GPT_PROF_FILE="$DIR/profiles/gpt.json"
_prof_cfgfile=$(jq -r '.service.configFile // empty' "$GPT_PROF_FILE" 2>/dev/null)
_prof_start=$(jq -r '.service.start // empty' "$GPT_PROF_FILE" 2>/dev/null)
assert_eq "profile .service.configFile basename is config.yaml" "config.yaml" "${_prof_cfgfile##*/}"
if [[ "$_prof_start" == *"config.yaml"* ]]; then
    echo "PASS: profile .service.start references config.yaml"; PASS=$((PASS+1))
else
    echo "FAIL: profile .service.start does not reference config.yaml"; FAIL=$((FAIL+1))
fi
# configFile and start must agree on the SAME path (configFile appears in start).
if [[ "$_prof_start" == *"$_prof_cfgfile"* ]]; then
    echo "PASS: profile configFile and start share one config.yaml path"; PASS=$((PASS+1))
else
    echo "FAIL: profile configFile/start path mismatch"; FAIL=$((FAIL+1))
fi

# install.sh coordinator MUST NOT reference config.yml anywhere (a stray
# config.yml default would diverge from the launcher's config.yaml).
if grep -nE 'config\.yml' "$DIR/install.sh" >/dev/null 2>&1; then
    echo "FAIL: install.sh references config.yml (must be config.yaml)"; FAIL=$((FAIL+1))
    grep -nE 'config\.yml' "$DIR/install.sh" | sed 's/^/     /'
else
    echo "PASS: install.sh free of config.yml references"; PASS=$((PASS+1))
fi
# install.sh MUST reference config.yaml (positive contract: coordinator writes
# the same filename the launcher reads).
if grep -qE 'config\.yaml' "$DIR/install.sh"; then
    echo "PASS: install.sh references config.yaml"; PASS=$((PASS+1))
else
    echo "FAIL: install.sh does not reference config.yaml"; FAIL=$((FAIL+1))
fi

# ===========================================================================
# Task 5: documentation + version assertions (static)
# ===========================================================================
#
# These do not execute install.sh code. They lock the GPT setup guides
# (docs/BACKENDS.md, docs/BACKENDS.zh-CN.md) and the release metadata
# (VERSION, CHANGELOG.md) to the behaviour implemented by Tasks 1-4. A failure
# here means the docs drifted from what the coordinator/hints actually do.

DOC_EN="$DIR/docs/BACKENDS.md"
DOC_ZH="$DIR/docs/BACKENDS.zh-CN.md"

# Assert a regex appears in BOTH guides (shared literal tokens like 8317,
# 127.0.0.1, api-keys work language-agnostically).
assert_doc_both() {
    local desc="$1" pattern="$2"
    if grep -Eq "$pattern" "$DOC_EN" && grep -Eq "$pattern" "$DOC_ZH"; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc (not present in both guides)"
        FAIL=$((FAIL+1))
    fi
}

# Assert an English pattern in BACKENDS.md and a (possibly different) Chinese
# pattern in BACKENDS.zh-CN.md, so translated concepts can be checked too.
assert_doc_pair() {
    local desc="$1" enp="$2" zhp="$3"
    if grep -Eq "$enp" "$DOC_EN" && grep -Eq "$zhp" "$DOC_ZH"; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc (en or zh missing)"
        FAIL=$((FAIL+1))
    fi
}

# --- Release metadata -------------------------------------------------------

assert_eq "VERSION is 2.15.0" "2.15.0" "$(cat "$DIR/VERSION")"

if grep -Eq '^## \[2\.15\.0\] - 2026-08-02' "$DIR/CHANGELOG.md"; then
    echo "PASS: changelog has [2.15.0] - 2026-08-02 entry"; PASS=$((PASS+1))
else
    echo "FAIL: changelog missing [2.15.0] - 2026-08-02 entry"; FAIL=$((FAIL+1))
fi

# --- Concept assertions (translated concepts use separate en/zh patterns) ---

# Config-first precedence + automatic reconciliation.
assert_doc_pair "docs: config key is authoritative / precedence" \
    'precedence|config-first|authoritative' \
    '优先级|配置.*优先'

# Automatic reuse / generation of the key (no manual inventing).
assert_doc_pair "docs: automatic reuse + generation" \
    'reconcile|automatically|generated|reuse' \
    '自动|生成|复用'

# Timestamped backup then normalize.
assert_doc_pair "docs: timestamped backup + normalize" \
    'timestamped|backup.*normaliz|normaliz' \
    '时间戳|备份.*归一化|归一化'

# OAuth remains a manual step.
assert_doc_pair "docs: manual codex-login still required" \
    'manual.*codex-login|codex-login.*manual|--codex-login' \
    '手动.*codex-login|codex-login.*手动|--codex-login'

# Windows / Bash-Zsh-only boundary.
assert_doc_pair "docs: Windows limitation stated" \
    'Windows' \
    'Windows'

# Auto-sync of config + profile (key written to both).
assert_doc_pair "docs: config + profile auto-sync" \
    'sync|in sync|both.*config' \
    '同步|一致'

# --- Shared literal tokens present in both guides ---------------------------

assert_doc_both "docs: loopback 127.0.0.1" '127\.0\.0\.1'
assert_doc_both "docs: port 8317"           '8317'
assert_doc_both "docs: non-empty api-keys"  'api-keys'
assert_doc_both "docs: directory mode 700"  '700'
assert_doc_both "docs: secret file mode 600" '600'

# --- Negative assertions: things the docs must NOT contain ------------------

# Brief: do not mention yq (the installer renders YAML itself).
if grep -Eiq 'yq\b' "$DOC_EN" || grep -Eiq 'yq\b' "$DOC_ZH"; then
    echo "FAIL: docs mention yq (must not)"; FAIL=$((FAIL+1))
else
    echo "PASS: docs do not mention yq"; PASS=$((PASS+1))
fi

# No leftover manual key-invention instruction.
if grep -Eq 'pick-any-long-random-string' "$DOC_EN" || grep -Eq 'pick-any-long-random-string' "$DOC_ZH"; then
    echo "FAIL: docs still ask user to invent key (pick-any-long-random-string)"; FAIL=$((FAIL+1))
else
    echo "PASS: docs free of pick-any-long-random-string placeholder"; PASS=$((PASS+1))
fi

if grep -Eq 'YOUR_CLIPROXYAPI_KEY' "$DOC_EN" || grep -Eq 'YOUR_CLIPROXYAPI_KEY' "$DOC_ZH"; then
    echo "FAIL: docs still contain YOUR_CLIPROXYAPI_KEY placeholder instruction"; FAIL=$((FAIL+1))
else
    echo "PASS: docs free of YOUR_CLIPROXYAPI_KEY instruction"; PASS=$((PASS+1))
fi

echo "----"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

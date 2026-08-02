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

# ---------------------------------------------------------------------------

# ===========================================================================
# Task 18: proxy-url support for CLIProxyAPI (RED tests — helpers absent)
# ===========================================================================
#
# These assertions lock the proxy-url contract BEFORE any production code is
# written. The install.sh helpers they exercise DO NOT EXIST YET:
#   - gpt_extract_proxy_url <path>            (top-level proxy-url parser)
#   - gpt_resolve_proxy_url <config>          (precedence + GPT_PROXY_SOURCE)
#   - gpt_render_config <key> [auth_dir] [proxy_url]   (extended renderer)
# plus coordinator behaviour for preserving/consuming proxy-url.
#
# Expected RED: every block below fails because the helper is unset (rc=127,
# empty output) or the coordinator strips/ignores the proxy-url field.
#
# Bash 3.2 compatible: no associative arrays, no `${arr[@]}` without the
# `${arr[@]+"${arr[@]}"}` guard, no lowercase-conversion parameter expansion.
# ===========================================================================

# --- Pure helper: gpt_extract_proxy_url -------------------------------------
#
# Contract: parse a top-level `proxy-url:` scalar from a CLIProxyAPI
# config.yaml. Accept http://, https://, socks5:// (and socks5h://), quoted or
# unquoted. Reject nested keys, empty values, unsupported schemes, malformed
# URLs, control characters, and YAML-injection characters. Print the value and
# return 0 on a valid hit; return 1 (printing nothing) otherwise.

# Quoted http://
cfg="$TMP/px-http-q.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://127.0.0.1:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: quoted http:// exits 0" 0 "$rc"
assert_eq     "proxy extract: quoted http:// value" "http://127.0.0.1:10808" "$out"

# Unquoted http://
cfg="$TMP/px-http-u.yaml"
fixture "$cfg" <<'YAML'
proxy-url: http://127.0.0.1:10808
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: unquoted http:// exits 0" 0 "$rc"
assert_eq     "proxy extract: unquoted http:// value" "http://127.0.0.1:10808" "$out"

# Quoted https://
cfg="$TMP/px-https.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "https://proxy.example.internal:8443"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: quoted https:// exits 0" 0 "$rc"
assert_eq     "proxy extract: quoted https:// value" "https://proxy.example.internal:8443" "$out"

# Quoted socks5://
cfg="$TMP/px-socks5.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "socks5://127.0.0.1:1080"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: quoted socks5:// exits 0" 0 "$rc"
assert_eq     "proxy extract: quoted socks5:// value" "socks5://127.0.0.1:1080" "$out"

# socks5h:// (hostname resolution at the proxy) is also accepted.
cfg="$TMP/px-socks5h.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "socks5h://127.0.0.1:1080"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: socks5h:// exits 0" 0 "$rc"
assert_eq     "proxy extract: socks5h:// value" "socks5h://127.0.0.1:1080" "$out"

# proxy-url with userinfo (synthetic credential) is parsed and validated; the
# value itself is never printed by the assertions below except via this
# explicit equality check.
cfg="$TMP/px-userinfo.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://user:secret@127.0.0.1:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: userinfo URL exits 0" 0 "$rc"
assert_eq     "proxy extract: userinfo URL value" "http://user:secret@127.0.0.1:10808" "$out"

# Trailing comment must not leak into the value.
cfg="$TMP/px-comment.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://127.0.0.1:10808"   # upstream proxy
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: trailing comment exits 0" 0 "$rc"
assert_eq     "proxy extract: trailing comment stripped" "http://127.0.0.1:10808" "$out"

# --- Rejection cases --------------------------------------------------------

# Nested proxy-url under another mapping MUST be rejected.
cfg="$TMP/px-nested.yaml"
fixture "$cfg" <<'YAML'
profiles:
  proxy-url: "http://127.0.0.1:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: nested proxy-url exits 1" 1 "$rc"
assert_eq     "proxy extract: nested proxy-url prints nothing" "" "$out"

# Empty value MUST be rejected.
cfg="$TMP/px-empty.yaml"
fixture "$cfg" <<'YAML'
proxy-url: ""
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: empty value exits 1" 1 "$rc"
assert_eq     "proxy extract: empty value prints nothing" "" "$out"

# Bare `proxy-url:` with no value MUST be rejected.
cfg="$TMP/px-bare.yaml"
fixture "$cfg" <<'YAML'
proxy-url:
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: bare key exits 1" 1 "$rc"
assert_eq     "proxy extract: bare key prints nothing" "" "$out"

# Unsupported scheme (ftp://) MUST be rejected.
cfg="$TMP/px-ftp.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "ftp://127.0.0.1:21"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: unsupported scheme exits 1" 1 "$rc"
assert_eq     "proxy extract: unsupported scheme prints nothing" "" "$out"

# Malformed URL (no host) MUST be rejected.
cfg="$TMP/px-malformed.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: malformed URL exits 1" 1 "$rc"
assert_eq     "proxy extract: malformed URL prints nothing" "" "$out"

# Control character in value MUST be rejected.
cfg="$TMP/px-control.yaml"
printf 'proxy-url: "http://127.0.0.1:10808\\n"\n' > "$cfg"
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: control char exits 1" 1 "$rc"
assert_eq     "proxy extract: control char prints nothing" "" "$out"

# YAML-injection attempt MUST be rejected (unquoted mapping/quote break).
cfg="$TMP/px-inject.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://x" injected: true
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: YAML injection exits 1" 1 "$rc"
assert_eq     "proxy extract: YAML injection prints nothing" "" "$out"

# Missing file -> exit 1, nothing printed.
out=$(gpt_extract_proxy_url "$TMP/px-no-such.yaml" 2>/dev/null); rc=$?
assert_return "proxy extract: missing file exits 1" 1 "$rc"
assert_eq     "proxy extract: missing file prints nothing" "" "$out"

# File without proxy-url -> exit 1 (field simply absent).
cfg="$TMP/px-absent.yaml"
fixture "$cfg" <<'YAML'
api-keys:
  - "some-key"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: absent field exits 1" 1 "$rc"
assert_eq     "proxy extract: absent field prints nothing" "" "$out"

# --- Pure helper: gpt_resolve_proxy_url precedence --------------------------
#
# Contract: resolve the effective proxy URL with fixed precedence
#   existing config proxy-url  >  GPT_PROXY_URL env  >  none (empty)
# and set GPT_PROXY_SOURCE to "config" | "env" | "none". Never log the URL.

cfg_proxy="$TMP/cfg-proxy.yaml"
fixture "$cfg_proxy" <<'YAML'
proxy-url: "http://from-config:10808"
api-keys:
  - "cfg-key"
YAML
cfg_noproxy="$TMP/cfg-noproxy.yaml"
fixture "$cfg_noproxy" <<'YAML'
api-keys:
  - "cfg-key"
YAML

# Case A: config wins over env. Call WITHOUT command substitution so the
# GPT_PROXY_SOURCE side effect lands in this shell.
GPT_PROXY_SOURCE=""
GPT_PROXY_URL="http://from-env:10808"
gpt_resolve_proxy_url "$cfg_proxy" > "$TMP/proxyA" 2>/dev/null
proxyA=$(cat "$TMP/proxyA")
assert_eq "proxy resolve: config wins over env" "http://from-config:10808" "$proxyA"
assert_eq "proxy resolve: source is config" "config" "$GPT_PROXY_SOURCE"

# Case B: no config proxy -> falls back to GPT_PROXY_URL.
GPT_PROXY_SOURCE=""
GPT_PROXY_URL="http://from-env:10808"
gpt_resolve_proxy_url "$cfg_noproxy" > "$TMP/proxyB" 2>/dev/null
proxyB=$(cat "$TMP/proxyB")
assert_eq "proxy resolve: env fallback value" "http://from-env:10808" "$proxyB"
assert_eq "proxy resolve: source is env" "env" "$GPT_PROXY_SOURCE"

# Case C: neither config nor env -> empty, source = none.
GPT_PROXY_SOURCE=""
unset GPT_PROXY_URL
gpt_resolve_proxy_url "$cfg_noproxy" > "$TMP/proxyC" 2>/dev/null
proxyC=$(cat "$TMP/proxyC")
assert_eq     "proxy resolve: none produces empty value" "" "$proxyC"
assert_eq     "proxy resolve: source is none" "none" "$GPT_PROXY_SOURCE"

# Standard proxy env vars (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY) MUST NOT be
# auto-read by the resolver; only the explicit GPT_PROXY_URL is honoured.
GPT_PROXY_SOURCE=""
unset GPT_PROXY_URL
HTTPS_PROXY="http://leak-via-https:8080" HTTP_PROXY="http://leak-via-http:8080" ALL_PROXY="http://leak-via-all:8080"
gpt_resolve_proxy_url "$cfg_noproxy" > "$TMP/proxyD" 2>/dev/null
proxyD=$(cat "$TMP/proxyD")
assert_eq     "proxy resolve: standard env vars ignored (empty result)" "" "$proxyD"
assert_eq     "proxy resolve: standard env vars ignored (source none)" "none" "$GPT_PROXY_SOURCE"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY

# --- Pure helper: gpt_render_config extended with proxy ---------------------

# Without proxy: the existing 5-line output is byte-for-byte unchanged.
expected_render_noproxy='host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "synthetic-key"'
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "" 2>/dev/null); rc=$?
assert_return "render: no-proxy 3-arg exits 0" 0 "$rc"
assert_eq     "render: no-proxy 3-arg unchanged 5 lines" "$expected_render_noproxy" "$out"

# With proxy: a deterministic 6-line output adds proxy-url at a fixed position
# (after auth-dir, before api-keys). Same input -> byte-stable.
expected_render_proxy='host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
proxy-url: "http://127.0.0.1:10808"
api-keys:
  - "synthetic-key"'
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://127.0.0.1:10808" 2>/dev/null); rc=$?
assert_return "render: with-proxy exits 0" 0 "$rc"
assert_eq     "render: with-proxy byte-stable 6 lines" "$expected_render_proxy" "$out"
# Byte stability: a second call produces identical bytes.
out2=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://127.0.0.1:10808" 2>/dev/null)
assert_eq     "render: with-proxy deterministic across calls" "$out" "$out2"

# Proxy URL is always emitted as a quoted YAML scalar (defensive quoting).
line=$(printf '%s\n' "$out" | sed -n '/^proxy-url:/p')
assert_match "render: proxy-url line is double-quoted scalar" "$line" '^proxy-url: ".*"$'

# An unsupported-scheme proxy MUST be rejected by the renderer.
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "ftp://bad:21" 2>/dev/null); rc=$?
assert_return "render: unsupported proxy scheme exits 1" 1 "$rc"
assert_eq     "render: unsupported proxy scheme prints nothing" "" "$out"

# --- Coordinator integration: proxy-url reconciliation ----------------------

# p1: an existing valid proxy-url is PRESERVED across reconciliation.
CASE_HOME="$TMP/p1"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p1.sh" "$CASE_HOME"
cat >> "$TMP/p1.sh" <<'SH'
printf 'host: "127.0.0.1"\nport: 8317\nauth-dir: "~/.cli-proxy-api"\nproxy-url: "http://127.0.0.1:10808"\napi-keys:\n  - "keep-this-key"\n' > "$GPT_CONFIG_DIR/config.yaml"
DRY_RUN=false configure_gpt_backend
grep -q '^proxy-url: "http://127.0.0.1:10808"$' "$GPT_CONFIG_DIR/config.yaml"
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p1.sh" >/dev/null 2>&1 && { echo "PASS: p1 existing proxy-url preserved"; PASS=$((PASS+1)); } || { echo "FAIL: p1 existing proxy-url preserved"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p1.sh"; FAIL=$((FAIL+1)); }

# p2: explicit GPT_PROXY_URL is consumed when the config lacks proxy-url.
CASE_HOME="$TMP/p2"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p2.sh" "$CASE_HOME"
cat >> "$TMP/p2.sh" <<'SH'
printf 'api-keys:\n  - "some-key"\n' > "$GPT_CONFIG_DIR/config.yaml"
GPT_PROXY_URL="http://127.0.0.1:10808"
export GPT_PROXY_URL
DRY_RUN=false configure_gpt_backend
grep -q '^proxy-url: "http://127.0.0.1:10808"$' "$GPT_CONFIG_DIR/config.yaml"
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p2.sh" >/dev/null 2>&1 && { echo "PASS: p2 GPT_PROXY_URL consumed"; PASS=$((PASS+1)); } || { echo "FAIL: p2 GPT_PROXY_URL consumed"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p2.sh"; FAIL=$((FAIL+1)); }

# p3: when both config proxy-url and GPT_PROXY_URL are set, config wins.
CASE_HOME="$TMP/p3"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p3.sh" "$CASE_HOME"
cat >> "$TMP/p3.sh" <<'SH'
printf 'proxy-url: "http://from-config:10808"\napi-keys:\n  - "k"\n' > "$GPT_CONFIG_DIR/config.yaml"
GPT_PROXY_URL="http://from-env:10808"
export GPT_PROXY_URL
DRY_RUN=false configure_gpt_backend
# Positive assertion MUST be fatal: under set +e an unguarded failing grep would
# let the case exit 0 via the later negation. Use explicit exit-1 on miss.
grep -q '^proxy-url: "http://from-config:10808"$' "$GPT_CONFIG_DIR/config.yaml" || { echo 'config proxy-url missing'; exit 1; }
if grep -q 'http://from-env:10808' "$GPT_CONFIG_DIR/config.yaml"; then echo 'env proxy leaked into config'; exit 1; fi
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p3.sh" >/dev/null 2>&1 && { echo "PASS: p3 config proxy wins over env"; PASS=$((PASS+1)); } || { echo "FAIL: p3 config proxy wins over env"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p3.sh"; FAIL=$((FAIL+1)); }

# p4: a config already normalized WITH proxy-url is a no-op: second run writes
# nothing and creates no backup, and the proxy-url survives both runs.
CASE_HOME="$TMP/p4"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p4.sh" "$CASE_HOME"
cat >> "$TMP/p4.sh" <<'SH'
printf 'host: "127.0.0.1"\nport: 8317\nauth-dir: "~/.cli-proxy-api"\nproxy-url: "http://127.0.0.1:10808"\napi-keys:\n  - "stable-key"\n' > "$GPT_CONFIG_DIR/config.yaml"
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
DRY_RUN=false configure_gpt_backend >/dev/null 2>&1
grep -q '^proxy-url: "http://127.0.0.1:10808"$' "$GPT_CONFIG_DIR/config.yaml"
nb=$(find "$GPT_CONFIG_DIR" -name 'config.yaml.*.bak' | wc -l | tr -d ' ')
[[ "$nb" == "0" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p4.sh" >/dev/null 2>&1 && { echo "PASS: p4 idempotent with proxy, no backup"; PASS=$((PASS+1)); } || { echo "FAIL: p4 idempotent with proxy, no backup"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p4.sh"; FAIL=$((FAIL+1)); }

# p5: DRY_RUN writes nothing and emits no proxy value.
CASE_HOME="$TMP/p5"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p5.sh" "$CASE_HOME"
cat >> "$TMP/p5.sh" <<'SH'
pre_prof=$(cat "$GPT_PROFILE")
GPT_PROXY_URL="http://127.0.0.1:10808"
export GPT_PROXY_URL
out=$(DRY_RUN=true configure_gpt_backend 2>&1)
[[ ! -e "$GPT_CONFIG_DIR/config.yaml" ]]
[[ "$(cat "$GPT_PROFILE")" == "$pre_prof" ]]
[[ "$out" != *"10808"* ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p5.sh" >/dev/null 2>&1 && { echo "PASS: p5 dry-run writes nothing, no proxy leak"; PASS=$((PASS+1)); } || { echo "FAIL: p5 dry-run writes nothing, no proxy leak"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p5.sh"; FAIL=$((FAIL+1)); }

# p6: custom GPT_CONFIG_DIR is reflected in auth-dir AND preserves proxy-url.
CASE_HOME="$TMP/p6"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p6.sh" "$CASE_HOME"
cat >> "$TMP/p6.sh" <<'SH'
GPT_CONFIG_DIR="$CASE_HOME/custom-proxy-dir"
export GPT_CONFIG_DIR
GPT_PROXY_URL="http://127.0.0.1:10808"
export GPT_PROXY_URL
DRY_RUN=false configure_gpt_backend
cfg="$GPT_CONFIG_DIR/config.yaml"
grep -q '^auth-dir: "'"$CASE_HOME/custom-proxy-dir"'"$' "$cfg"
grep -q '^proxy-url: "http://127.0.0.1:10808"$' "$cfg"
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p6.sh" >/dev/null 2>&1 && { echo "PASS: p6 custom GPT_CONFIG_DIR + proxy"; PASS=$((PASS+1)); } || { echo "FAIL: p6 custom GPT_CONFIG_DIR + proxy"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p6.sh"; FAIL=$((FAIL+1)); }

# p7: a malformed EXISTING proxy-url must fail safe: critical recorded, and both
# config.yaml and profile are left byte-for-byte unchanged (no silent rewrite
# that strips the user's value).
CASE_HOME="$TMP/p7"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p7.sh" "$CASE_HOME"
cat >> "$TMP/p7.sh" <<'SH'
printf 'host: "127.0.0.1"\nport: 8317\nauth-dir: "~/.cli-proxy-api"\nproxy-url: "ftp://bad-scheme:21"\napi-keys:\n  - "preserve-me"\n' > "$GPT_CONFIG_DIR/config.yaml"
prof_before=$(cat "$GPT_PROFILE")
cfg_before=$(cat "$GPT_CONFIG_DIR/config.yaml")
DRY_RUN=false configure_gpt_backend 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]
[[ $INSTALL_CRITICAL -ge 1 ]]
[[ "$(cat "$GPT_CONFIG_DIR/config.yaml")" == "$cfg_before" ]]
[[ "$(cat "$GPT_PROFILE")" == "$prof_before" ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p7.sh" >/dev/null 2>&1 && { echo "PASS: p7 malformed proxy fails safe"; PASS=$((PASS+1)); } || { echo "FAIL: p7 malformed proxy fails safe"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p7.sh"; FAIL=$((FAIL+1)); }

# p8: with xtrace enabled, a synthetic credential-bearing proxy URL MUST NOT
# leak to stderr, and the xtrace state is restored afterward.
CASE_HOME="$TMP/p8"; setup_gpt_home "$CASE_HOME"
mk_case "$TMP/p8.sh" "$CASE_HOME"
cat >> "$TMP/p8.sh" <<'SH'
secret_proxy='http://synuser:synpass@127.0.0.1:10808'
GPT_PROXY_URL="$secret_proxy"
export GPT_PROXY_URL
set -x
DRY_RUN=false configure_gpt_backend 2>"$CASE_HOME/p8.err"
case $- in *x*) : ;; *) exit 1 ;; esac
set +x
! grep -Fq "$secret_proxy" "$CASE_HOME/p8.err"
! grep -Fq 'synpass' "$CASE_HOME/p8.err"
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p8.sh" >/dev/null 2>&1 && { echo "PASS: p8 xtrace does not leak proxy credentials"; PASS=$((PASS+1)); } || { echo "FAIL: p8 xtrace does not leak proxy credentials"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p8.sh"; FAIL=$((FAIL+1)); }

# p9: when GPT is not selected, an explicit GPT_PROXY_URL is a complete no-op:
# nothing is read, written, or echoed even with a credential-bearing URL.
CASE_HOME="$TMP/p9"; setup_gpt_home "$CASE_HOME"
printf 'sentinel-config\n' > "$CASE_HOME/.cli-proxy-api/config.yaml"
printf 'sentinel-profile\n' > "$CASE_HOME/.claude/profiles/gpt.json"
mk_case "$TMP/p9.sh" "$CASE_HOME"
cat >> "$TMP/p9.sh" <<'SH'
SELECTED_PROFILES=("glm" "ccr")
GPT_PROXY_URL='http://synuser:synpass@127.0.0.1:10808'
export GPT_PROXY_URL
config_before=$(cat "$GPT_CONFIG_DIR/config.yaml")
profile_before=$(cat "$GPT_PROFILE")
out=$(DRY_RUN=false configure_gpt_backend 2>&1); rc=$?
[[ $rc -eq 0 ]]
[[ -z "$out" ]]
[[ "$(cat "$GPT_CONFIG_DIR/config.yaml")" == "$config_before" ]]
[[ "$(cat "$GPT_PROFILE")" == "$profile_before" ]]
[[ "$out" != *"synpass"* ]]
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p9.sh" >/dev/null 2>&1 && { echo "PASS: p9 unselected GPT no-op with proxy env"; PASS=$((PASS+1)); } || { echo "FAIL: p9 unselected GPT no-op with proxy env"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p9.sh"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Task 18 review findings: three verified gaps (RED tests — behavior absent)
# ===========================================================================
#
# Locking three findings from review before any production code lands:
#   (1) custom GPT_CONFIG_DIR must also rewrite the gpt profile's
#       .service.configFile / .service.start so the launcher reads the SAME
#       config the installer wrote; the default path stays unchanged.
#   (2) gpt_extract_proxy_url must accept IPv6-literal hosts and query strings.
#   (3) gpt_backup_file must never overwrite a same-timestamp backup: two calls
#       forced into the same second produce distinct paths and both snapshots
#       survive.
# All three fail RED against the current implementation.
# ===========================================================================

# --- Finding (2): IPv6 literal + query-delimiter proxy URLs -----------------

cfg="$TMP/px-ipv6.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://[::1]:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: IPv6 literal exits 0" 0 "$rc"
assert_eq     "proxy extract: IPv6 literal value" "http://[::1]:10808" "$out"

cfg="$TMP/px-query.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://127.0.0.1:10808?x=y&z=1"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: query delimiter exits 0" 0 "$rc"
assert_eq     "proxy extract: query delimiter value" "http://127.0.0.1:10808?x=y&z=1" "$out"

# IPv6 + userinfo + query all together must also parse.
cfg="$TMP/px-ipv6-full.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://user:s3cr3t@[::1]:10808?x=y&z=1"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: IPv6+userinfo+query exits 0" 0 "$rc"
assert_eq     "proxy extract: IPv6+userinfo+query value" "http://user:s3cr3t@[::1]:10808?x=y&z=1" "$out"

# The renderer must also emit these byte-for-byte as quoted scalars.
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://[::1]:10808" 2>/dev/null); rc=$?
assert_return "render: IPv6 proxy exits 0" 0 "$rc"
assert_match "render: IPv6 proxy-url line emitted" "$(printf '%s\n' "$out" | sed -n '/^proxy-url:/p')" '^proxy-url: "http://\[::1\]:10808"$'

# --- Finding (3): gpt_backup_file same-timestamp collision ------------------
#
# Force an identical timestamp by shadowing `date` with a stub. Two backups of
# the same path in the same second MUST yield distinct paths and preserve BOTH
# snapshots (never overwrite). Under the current implementation the second cp
# clobbers the first and the paths collide, so both assertions RED.

bkc_dir="$TMP/bkc"; mkdir -p "$bkc_dir"
bkc_cfg="$bkc_dir/config.yaml"

# Shadow date for this block only; restore immediately after.
date() { printf '20260101000000\n'; }

printf 'snapshot-one\n' > "$bkc_cfg"
bak1=$(gpt_backup_file "$bkc_cfg" 2>/dev/null); rc1=$?
printf 'snapshot-two\n' > "$bkc_cfg"
bak2=$(gpt_backup_file "$bkc_cfg" 2>/dev/null); rc2=$?

unset -f date

assert_return "backup collision: first call exits 0" 0 "$rc1"
assert_return "backup collision: second call exits 0" 0 "$rc2"
assert_ne     "backup collision: second path distinct from first" "$bak1" "$bak2"
assert_eq     "backup collision: first snapshot preserved"  "snapshot-one" "$(cat "$bak1" 2>/dev/null)"
assert_eq     "backup collision: second snapshot preserved" "snapshot-two" "$(cat "$bak2" 2>/dev/null)"

# --- Finding (1): custom GPT_CONFIG_DIR rewrites profile service config -----
#
# Build a service-bearing profile fixture (the real profiles/gpt.json shape).
# The default setup_gpt_home uses GPT_FIXTURE whose `service` is a string, so
# lay down a dedicated fixture with the .service.configFile / .service.start
# object fields the launcher reads.

SVC_FIXTURE="$TMP/gpt_svc.json"
fixture "$SVC_FIXTURE" <<'JSON'
{
  "label": "ChatGPT subscription (Codex OAuth via CLIProxyAPI)",
  "credentialKeys": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"],
  "service": {
    "label": "CLIProxyAPI",
    "health": "http://127.0.0.1:8317/healthz",
    "bins": ["cli-proxy-api"],
    "start": "{bin} --config \"$HOME/.cli-proxy-api/config.yaml\"",
    "configFile": "$HOME/.cli-proxy-api/config.yaml",
    "timeoutSec": 25,
    "logName": "cli-proxy-api.log"
  },
  "unset": [],
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "YOUR_CLIPROXYAPI_KEY",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317"
  }
}
JSON

# p10: custom GPT_CONFIG_DIR must propagate to profile service.configFile AND
# service.start so claude.zsh launches CLIProxyAPI against the same config the
# installer wrote. Current coordinator never rewrites these fields -> RED.
CASE_HOME="$TMP/p10"
rm -rf "$CASE_HOME"
mkdir -p "$CASE_HOME/.claude/profiles" "$CASE_HOME/.cli-proxy-api"
cp "$SVC_FIXTURE" "$CASE_HOME/.claude/profiles/gpt.json"
mk_case "$TMP/p10.sh" "$CASE_HOME"
cat >> "$TMP/p10.sh" <<'SH'
GPT_CONFIG_DIR="$CASE_HOME/custom-proxy-dir"
export GPT_CONFIG_DIR
DRY_RUN=false configure_gpt_backend
cf=$(jq -r '.service.configFile // empty' "$GPT_PROFILE")
st=$(jq -r '.service.start // empty' "$GPT_PROFILE")
# Both must reference the custom config path the installer just wrote.
[[ "$cf" == *"$CASE_HOME/custom-proxy-dir/config.yaml"* ]] || { echo "configFile not updated"; exit 1; }
[[ "$st" == *"$CASE_HOME/custom-proxy-dir/config.yaml"* ]] || { echo "start not updated"; exit 1; }
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p10.sh" >/dev/null 2>&1 && { echo "PASS: p10 custom dir rewrites profile service config"; PASS=$((PASS+1)); } || { echo "FAIL: p10 custom dir rewrites profile service config"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p10.sh"; FAIL=$((FAIL+1)); }

# p10b: default GPT_CONFIG_DIR leaves the profile service config pointing at
# the standard ~/.cli-proxy-api path (and never leaks a custom dir). This is a
# guard: it must stay green now and after the fix.
CASE_HOME="$TMP/p10b"
rm -rf "$CASE_HOME"
mkdir -p "$CASE_HOME/.claude/profiles" "$CASE_HOME/.cli-proxy-api"
cp "$SVC_FIXTURE" "$CASE_HOME/.claude/profiles/gpt.json"
mk_case "$TMP/p10b.sh" "$CASE_HOME"
cat >> "$TMP/p10b.sh" <<'SH'
DRY_RUN=false configure_gpt_backend
cf=$(jq -r '.service.configFile // empty' "$GPT_PROFILE")
st=$(jq -r '.service.start // empty' "$GPT_PROFILE")
[[ "$cf" == *"/.cli-proxy-api/config.yaml"* ]] || { echo "default configFile changed"; exit 1; }
[[ "$st" == *"/.cli-proxy-api/config.yaml"* ]] || { echo "default start changed"; exit 1; }
[[ "$cf" != *"custom"* ]] || { echo "custom leak in configFile"; exit 1; }
SH
CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p10b.sh" >/dev/null 2>&1 && { echo "PASS: p10b default profile service config unchanged"; PASS=$((PASS+1)); } || { echo "FAIL: p10b default profile service config unchanged"; CASE_HOME="$CASE_HOME" DIR="$DIR" bash "$TMP/p10b.sh"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Task 18 MEDIUM findings: concurrent backup race + authority-less proxy URLs
# ===========================================================================
#
# Two more verified review gaps locked here as RED tests:
#   (1) gpt_backup_file under a forced same-timestamp RACE: two CONCURRENT
#       calls against the same source must each yield a distinct path and both
#       snapshot files must survive (no clobber). The current implementation
#       computes `<base>.<stamp>.bak` from `date` alone, so a same-second race
#       collides on one path and the second cp overwrites the first.
#   (2) Authority-less / bracket-malformed proxy URLs MUST be rejected at the
#       extractor and at render validation. The current validator regex
#       (`[A-Za-z0-9._~%:@/+-]+`) accepts `http:///path` (no authority) and,
#       once broadened for IPv6/query, risks accepting `http://?x=y` and
#       unmatched-bracket forms unless authority is required explicitly.
# Bash 3.2 compatible.
# ===========================================================================

# --- Finding (1): concurrent gpt_backup_file, forced identical timestamp ----
#
# Shadow `date` so both concurrent calls compute the same stamp. Launch both
# backups in the background against the same source, wait, then assert:
# both exit 0, the returned paths are DISTINCT, exactly two backup files exist,
# and each preserves the source snapshot bytes.

date() { printf '20260101000000\n'; }

conc_dir="$TMP/conc"; mkdir -p "$conc_dir"
conc_cfg="$conc_dir/config.yaml"
printf 'concurrent-snapshot\n' > "$conc_cfg"

# Background both calls; capture each stdout (the backup path) to its own file.
gpt_backup_file "$conc_cfg" > "$TMP/conc_a.out" 2>/dev/null &
pid_a=$!
gpt_backup_file "$conc_cfg" > "$TMP/conc_b.out" 2>/dev/null &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?

unset -f date

bak_a=$(cat "$TMP/conc_a.out" 2>/dev/null)
bak_b=$(cat "$TMP/conc_b.out" 2>/dev/null)

assert_return "backup race: call A exits 0" 0 "$rc_a"
assert_return "backup race: call B exits 0" 0 "$rc_b"
assert_ne     "backup race: path A non-empty" "" "$bak_a"
assert_ne     "backup race: path B non-empty" "" "$bak_b"
assert_ne     "backup race: A and B paths distinct" "$bak_a" "$bak_b"
nb=$(find "$conc_dir" -name 'config.yaml.*.bak' 2>/dev/null | wc -l | tr -d ' ')
assert_eq     "backup race: exactly two backup files exist" "2" "$nb"
assert_eq     "backup race: snapshot A bytes preserved" "concurrent-snapshot" "$(cat "$bak_a" 2>/dev/null)"
assert_eq     "backup race: snapshot B bytes preserved" "concurrent-snapshot" "$(cat "$bak_b" 2>/dev/null)"

# --- Finding (2): reject authority-less / bracket-malformed proxy URLs ------
#
# Each malformed value MUST be rejected (rc=1, nothing printed) at the
# extractor AND at render validation. `http:///path` (authority-less) is the
# case currently ACCEPTED by the validator regex and is the primary RED signal;
# the remaining forms are forward-looking guards against over-broadening when
# the regex is opened up for IPv6 brackets and query strings.

# http:///path — no authority. Currently ACCEPTED by the char-class regex.
cfg="$TMP/px-noauth-slash.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http:///path"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: authority-less http:///path exits 1" 1 "$rc"
assert_eq     "proxy extract: authority-less http:///path prints nothing" "" "$out"

# http://?x=y — no authority, only a query. Authority MUST be required.
cfg="$TMP/px-noauth-query.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://?x=y"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: authority-less http://?x=y exits 1" 1 "$rc"
assert_eq     "proxy extract: authority-less http://?x=y prints nothing" "" "$out"

# Unmatched opening IPv6 bracket: http://[::1:10808 (no closing ]).
cfg="$TMP/px-bracket-open.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://[::1:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: unmatched opening bracket exits 1" 1 "$rc"
assert_eq     "proxy extract: unmatched opening bracket prints nothing" "" "$out"

# Unmatched closing IPv6 bracket: http://::1]:10808 (no opening [).
cfg="$TMP/px-bracket-close.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://::1]:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: unmatched closing bracket exits 1" 1 "$rc"
assert_eq     "proxy extract: unmatched closing bracket prints nothing" "" "$out"

# The renderer shares the validator and MUST reject the authority-less value
# (the primary over-broadening trap).
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http:///path" 2>/dev/null); rc=$?
assert_return "render: authority-less http:///path exits 1" 1 "$rc"
assert_eq     "render: authority-less http:///path prints nothing" "" "$out"

# Resolver fail-safe: when the EXISTING config holds an authority-less proxy-url,
# the resolver MUST treat it as malformed (not fall through to env). It must
# surface the failure rather than silently dropping or rewriting the value.
cfg_noauth="$TMP/cfg-noauth.yaml"
fixture "$cfg_noauth" <<'YAML'
proxy-url: "http:///path"
api-keys:
  - "cfg-key"
YAML
GPT_PROXY_SOURCE=""
GPT_PROXY_URL="http://from-env:10808"
gpt_resolve_proxy_url "$cfg_noauth" > "$TMP/noauth_resolve.out" 2>/dev/null; rcr=$?
# Resolver must signal malformed-existing-proxy (non-zero), NOT silently fall
# through to the env value. This guards config-first precedence against
# silently masking a broken existing value.
assert_return "proxy resolve: authority-less existing proxy is malformed" 1 "$rcr"
assert_eq     "proxy resolve: authority-less existing proxy prints nothing" "" "$(cat "$TMP/noauth_resolve.out" 2>/dev/null)"

# ===========================================================================
# Task 18 final MEDIUM validator gap: authority/userinfo/port/IPv6 structure
# ===========================================================================
#
# The validator regex was broadened to accept []?&= for IPv6/query, but still
# lacks structural checks. These RED tests pin the missing structure:
#   - userinfo with NO host:        http://user@/path
#   - port with NO host:            http://:1080
#   - unbracketed IPv6 in authority: http://::1:1080
#   - multiple @ in authority:      http://a@@host:1080
#   - nonnumeric / empty / out-of-range port (validator claims numeric port)
# Each malformed value MUST be rejected at extractor, renderer and resolver as
# appropriate. Positive guards confirm well-formed userinfo+IPv6 still pass.
# Bash 3.2 compatible.
# ===========================================================================

# --- Negative: userinfo with no host ----------------------------------------
cfg="$TMP/px-userinfo-nohost.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://user@/path"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: userinfo-no-host exits 1" 1 "$rc"
assert_eq     "proxy extract: userinfo-no-host prints nothing" "" "$out"

# --- Negative: port with no host --------------------------------------------
cfg="$TMP/px-port-nohost.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://:1080"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: port-no-host exits 1" 1 "$rc"
assert_eq     "proxy extract: port-no-host prints nothing" "" "$out"

# --- Negative: unbracketed IPv6 in authority --------------------------------
cfg="$TMP/px-ipv6-unbracketed.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://::1:1080"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: unbracketed IPv6 exits 1" 1 "$rc"
assert_eq     "proxy extract: unbracketed IPv6 prints nothing" "" "$out"

# --- Negative: multiple @ in authority --------------------------------------
cfg="$TMP/px-multi-at.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://a@@host:1080"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: multiple @ exits 1" 1 "$rc"
assert_eq     "proxy extract: multiple @ prints nothing" "" "$out"

# --- Negative: port structure (nonnumeric / empty / out-of-range) -----------
# The validator claims an optional numeric port, so the port, when present,
# must be all digits in [1,65535]. A trailing ':' with no digits is an empty
# port (rejected); nonnumeric and >65535 are rejected.

# Nonnumeric port.
cfg="$TMP/px-port-alpha.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://host:abc"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: nonnumeric port exits 1" 1 "$rc"
assert_eq     "proxy extract: nonnumeric port prints nothing" "" "$out"

# Empty port (trailing colon, no digits).
cfg="$TMP/px-port-empty.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://host:"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: empty port exits 1" 1 "$rc"
assert_eq     "proxy extract: empty port prints nothing" "" "$out"

# Out-of-range port (>65535).
cfg="$TMP/px-port-range.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://host:99999"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: out-of-range port exits 1" 1 "$rc"
assert_eq     "proxy extract: out-of-range port prints nothing" "" "$out"

# --- Renderer shares the validator: reject authority-structure values -------
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://user@/path" 2>/dev/null); rc=$?
assert_return "render: userinfo-no-host exits 1" 1 "$rc"
assert_eq     "render: userinfo-no-host prints nothing" "" "$out"

out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://:1080" 2>/dev/null); rc=$?
assert_return "render: port-no-host exits 1" 1 "$rc"
assert_eq     "render: port-no-host prints nothing" "" "$out"

out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://::1:1080" 2>/dev/null); rc=$?
assert_return "render: unbracketed IPv6 exits 1" 1 "$rc"
assert_eq     "render: unbracketed IPv6 prints nothing" "" "$out"

# --- Resolver fail-safe: malformed existing proxy is NOT silently dropped ---
# A config holding userinfo-no-host MUST surface failure rather than fall
# through to env or mask a broken value.
cfg_userinfo_nohost="$TMP/cfg-userinfo-nohost.yaml"
fixture "$cfg_userinfo_nohost" <<'YAML'
proxy-url: "http://user@/path"
api-keys:
  - "cfg-key"
YAML
GPT_PROXY_SOURCE=""
GPT_PROXY_URL="http://from-env:10808"
gpt_resolve_proxy_url "$cfg_userinfo_nohost" > "$TMP/uin_resolve.out" 2>/dev/null; rcu=$?
assert_return "proxy resolve: userinfo-no-host existing proxy is malformed" 1 "$rcu"
assert_eq     "proxy resolve: userinfo-no-host existing proxy prints nothing" "" "$(cat "$TMP/uin_resolve.out" 2>/dev/null)"

# --- Positive guards: well-formed userinfo + IPv6 still accepted -------------
cfg="$TMP/px-pos-userinfo.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://user:pass@host:1080/path?x=y"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract (guard): userinfo+path+query exits 0" 0 "$rc"
assert_eq     "proxy extract (guard): userinfo+path+query value" "http://user:pass@host:1080/path?x=y" "$out"

cfg="$TMP/px-pos-ipv6.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://[::1]:10808"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract (guard): IPv6 literal exits 0" 0 "$rc"
assert_eq     "proxy extract (guard): IPv6 literal value" "http://[::1]:10808" "$out"

# Renderer must also emit the positive guards as quoted scalars.
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://user:pass@host:1080/path?x=y" 2>/dev/null); rc=$?
assert_return "render (guard): userinfo+path+query exits 0" 0 "$rc"
assert_match "render (guard): userinfo+path+query line" "$(printf '%s\n' "$out" | sed -n '/^proxy-url:/p')" '^proxy-url: "http://user:pass@host:1080/path\?x=y"$'

out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://[::1]:10808" 2>/dev/null); rc=$?
assert_return "render (guard): IPv6 literal exits 0" 0 "$rc"
assert_match "render (guard): IPv6 literal line" "$(printf '%s\n' "$out" | sed -n '/^proxy-url:/p')" '^proxy-url: "http://\[::1\]:10808"$'

# ===========================================================================
# Task 18 oversized-port guard: http://host:18446744073709551696
# ===========================================================================
#
# A numeric port that overflows uint64 (2^64+32) MUST be rejected. The current
# validator regex only checks a flat character class, so the value is accepted;
# an implementation that naively parses the port with strtoul/uint64 would wrap
# or silently error and must still reject. RED until structural port validation
# (all digits AND in [1,65535], with overflow protection) lands.
# Bash 3.2 compatible.
# ===========================================================================

# --- Extractor: oversized numeric port rejected -----------------------------
cfg="$TMP/px-port-oversize.yaml"
fixture "$cfg" <<'YAML'
proxy-url: "http://host:18446744073709551696"
YAML
out=$(gpt_extract_proxy_url "$cfg" 2>/dev/null); rc=$?
assert_return "proxy extract: oversized uint64 port exits 1" 1 "$rc"
assert_eq     "proxy extract: oversized uint64 port prints nothing" "" "$out"

# --- Renderer shares the validator: oversized port rejected -----------------
out=$(gpt_render_config "synthetic-key" "~/.cli-proxy-api" "http://host:18446744073709551696" 2>/dev/null); rc=$?
assert_return "render: oversized uint64 port exits 1" 1 "$rc"
assert_eq     "render: oversized uint64 port prints nothing" "" "$out"

# --- Resolver fail-safe: malformed existing proxy not silently dropped ------
cfg_oversize="$TMP/cfg-oversize.yaml"
fixture "$cfg_oversize" <<'YAML'
proxy-url: "http://host:18446744073709551696"
api-keys:
  - "cfg-key"
YAML
GPT_PROXY_SOURCE=""
GPT_PROXY_URL="http://from-env:10808"
gpt_resolve_proxy_url "$cfg_oversize" > "$TMP/oversize_resolve.out" 2>/dev/null; rco=$?
assert_return "proxy resolve: oversized port existing proxy is malformed" 1 "$rco"
assert_eq     "proxy resolve: oversized port existing proxy prints nothing" "" "$(cat "$TMP/oversize_resolve.out" 2>/dev/null)"

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

assert_eq "VERSION is 2.17.0" "2.17.0" "$(cat "$DIR/VERSION")"

if grep -Eq '^## \[2\.17\.0\] - 2026-08-02' "$DIR/CHANGELOG.md"; then
    echo "PASS: changelog has [2.17.0] - 2026-08-02 entry"; PASS=$((PASS+1))
else
    echo "FAIL: changelog missing [2.17.0] - 2026-08-02 entry"; FAIL=$((FAIL+1))
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

# --- Task 20: proxy-url documentation contract (v2.16.0) --------------------
#
# Lock the CLIProxyAPI outbound proxy-url contract documented in BACKENDS.md /
# BACKENDS.zh-CN.md so the guides cannot drift from the implemented
# gpt_resolve_proxy_url / gpt_render_config behaviour.

# Optional proxy-url line exists as a concept in both guides.
assert_doc_both "docs: proxy-url mentioned" 'proxy-url'
# Explicit GPT_PROXY_URL env var is the documented opt-in.
assert_doc_both "docs: GPT_PROXY_URL env var mentioned" 'GPT_PROXY_URL'

# Config-first precedence applies to proxy-url too.
assert_doc_pair "docs: proxy-url config-first precedence" \
    'proxy-url.*authoritative|authoritative.*proxy-url|config.*proxy-url' \
    'proxy-url.*权威|权威.*proxy-url|配置.*proxy-url'

# Standard proxy env vars are explicitly NOT auto-persisted.
assert_doc_pair "docs: standard proxy env vars not auto-persisted" \
    'HTTP_PROXY.*HTTPS_PROXY.*ALL_PROXY|not.*auto-persist|deliberately.*not' \
    'HTTP_PROXY.*HTTPS_PROXY.*ALL_PROXY|不自动持久化|故意不'

# Credentials may be present in the URL and the URL is never printed.
assert_doc_pair "docs: proxy URL may carry credentials, never printed" \
    'credentials|never.*printed|never.*log' \
    '凭证|绝不被打印|从不打印|不会泄露'

# Malformed existing proxy-url fails safe (no silent rewrite).
assert_doc_pair "docs: malformed proxy-url fails safe" \
    'malformed.*fails safe|fails safe|without touching' \
    '格式错误.*安全失败|安全失败|原样保留|不会.*重写'

# Accepted schemes (http/https/socks5) documented.
assert_doc_pair "docs: proxy schemes listed" \
    'socks5://|http://.*https://' \
    'socks5://|http://.*https://'

# CCR independence: cl_ccr never traverses CLIProxyAPI on 8317.
assert_doc_pair "docs: cl_ccr never traverses CLIProxyAPI 8317" \
    'never traverses CLIProxyAPI|separate plane|cl_ccr.*never' \
    '永远不会经过 CLIProxyAPI|独立.*线|cl_ccr.*不会'

# CCR port 3456 + gateway-proxy-preload.cjs + CCR_UPSTREAM_PROXY_URL.
assert_doc_pair "docs: CCR uses preload + CCR_UPSTREAM_PROXY_URL on 3456" \
    'gateway-proxy-preload\.cjs|CCR_UPSTREAM_PROXY_URL|ProxyAgent' \
    'gateway-proxy-preload\.cjs|CCR_UPSTREAM_PROXY_URL|ProxyAgent'
assert_doc_both "docs: CCR port 3456" '3456'

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

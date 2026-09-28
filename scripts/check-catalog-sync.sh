#!/usr/bin/env bash
# Check that the script installers and catalog.md describe the same Claude items.
#
#   1. Every install.sh menu ID maps to catalog ID(s) (catalog_id_for_menu_id in
#      install.sh) or is listed below as script-only.
#   2. Every mapped catalog ID has a Claude row in catalog.md, unless listed
#      below as a fork-only item (the fork installs it; a catalog row is optional).
#   3. Every catalog.md ID with a Claude channel is reachable from some menu ID,
#      unless listed below as agent-only.
#   4. install.ps1 offers the same menu IDs (minus the documented macOS/Linux-only
#      ones) and carries the same menu -> catalog mapping.
#
# Usage: scripts/check-catalog-sync.sh   (exit 0 = in sync)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/catalog.md"

# Menu IDs with no catalog counterpart at all (script-only features).
SCRIPT_ONLY_MENU_IDS=(
    agents          # Jeff read-only search agent
    shell-wrapper   # cl/cl_auto launcher + system prompt
    co-author       # includeCoAuthoredBy
    backend-glm backend-or backend-gpt backend-ccr   # model backend profiles / proxies
)

# Catalog IDs the script installs that catalog.md may not list (fork additions
# and fork overrides). Once a row exists it is simply matched.
FORK_ONLY_CATALOG_IDS=(
    feature-dev ralph-loop commit-commands   # plugins kept default-on in the fork
    ecc                                      # Everything Claude Code plugin
    update-config                            # fork update skill (script path)
    cheatsheet-creator                       # fork skill
    playwright-mcp                           # standalone Playwright MCP (menu id: mcp)
    lark                                     # Lark/Feishu MCP (menu id: mcp-lark)
)

# Catalog IDs with a Claude channel that the script installer does not offer.
AGENT_ONLY_CATALOG_IDS=(
    edit-config        # shared agent skill; installed by the agent-guided path
    matt-code-review   # member of matt-workflow, not a separate install
    frontend-design    # fork override: removed from the script (examples provides it)
    claude-health      # fork override: removed from the script
)

# install.sh menu IDs that install.ps1 does not offer (macOS/Linux-only features).
PS1_MISSING_MENU_IDS=(
    shell-wrapper co-author backend-glm backend-or backend-gpt backend-ccr
    skill-mattpocock
)

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
in_list() { local n="$1" x; shift; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

[[ -f "$CATALOG" ]] || { echo "catalog.md not found at $CATALOG" >&2; exit 2; }

# Catalog rows: | id | description | Claude | Codex | ... ; a Claude cell of "—"
# means the item is not offered for Claude.
catalog_claude_ids=()
while IFS= read -r id; do
    [[ -n "$id" ]] && catalog_claude_ids+=("$id")
done < <(awk -F'|' '
    /^\| [a-z0-9][a-z0-9-]* \|/ {
        id = $2; gsub(/^ +| +$/, "", id)
        claude = $4; gsub(/^ +| +$/, "", claude)
        if (claude != "" && claude != "—" && claude != "-") print id
    }' "$CATALOG")

# Menu IDs and the mapping, straight from install.sh.
# shellcheck disable=SC1091
ACCC_LIB_ONLY=1 source "$ROOT/install.sh"
menu_ids=()
while IFS='|' read -r id _rest; do
    [[ -n "$id" ]] && menu_ids+=("$id")
done < <(menu_item_ids)

mapped_catalog_ids=()
for id in "${menu_ids[@]}"; do
    cids="$(catalog_id_for_menu_id "$id")"
    if [[ -z "$cids" ]]; then
        in_list "$id" "${SCRIPT_ONLY_MENU_IDS[@]}" || err "menu ID '$id' has no catalog mapping (add it to catalog_id_for_menu_id in install.sh or to SCRIPT_ONLY_MENU_IDS)"
        continue
    fi
    in_list "$id" "${SCRIPT_ONLY_MENU_IDS[@]}" && err "menu ID '$id' is mapped but also listed as script-only"
    for cid in $cids; do
        mapped_catalog_ids+=("$cid")
        if ! in_list "$cid" "${catalog_claude_ids[@]}" && ! in_list "$cid" "${FORK_ONLY_CATALOG_IDS[@]}"; then
            err "menu ID '$id' maps to '$cid', which has no Claude row in catalog.md"
        fi
    done
done

for cid in "${catalog_claude_ids[@]}"; do
    in_list "$cid" "${mapped_catalog_ids[@]}" && continue
    in_list "$cid" "${AGENT_ONLY_CATALOG_IDS[@]}" && continue
    err "catalog ID '$cid' offers Claude but no install.sh menu item installs it (add a menu item + mapping, or list it in AGENT_ONLY_CATALOG_IDS)"
done
for cid in "${AGENT_ONLY_CATALOG_IDS[@]}"; do
    in_list "$cid" "${catalog_claude_ids[@]}" || err "stale AGENT_ONLY_CATALOG_IDS entry '$cid' (no Claude row in catalog.md)"
    in_list "$cid" "${mapped_catalog_ids[@]}" && err "'$cid' is listed as agent-only but a menu item installs it"
done
for id in "${SCRIPT_ONLY_MENU_IDS[@]}" "${PS1_MISSING_MENU_IDS[@]}"; do
    in_list "$id" "${menu_ids[@]}" || err "stale exception: menu ID '$id' no longer exists in install.sh"
done

# install.ps1 parity: menu IDs and mapping table.
PS1="$ROOT/install.ps1"
ps1_ids=()
while IFS= read -r id; do
    [[ -n "$id" ]] && ps1_ids+=("$id")
done < <(sed -n '/^function Get-MenuGroups/,/^}/p' "$PS1" | grep -oE 'Id = "[^"]+"' | sed -E 's/Id = "(.*)"/\1/')
[[ ${#ps1_ids[@]} -gt 0 ]] || err "could not read the menu from install.ps1 (Get-MenuGroups)"
for id in "${menu_ids[@]}"; do
    in_list "$id" "${PS1_MISSING_MENU_IDS[@]}" && continue
    in_list "$id" "${ps1_ids[@]}" || err "install.ps1 is missing menu ID '$id'"
done
for id in "${ps1_ids[@]}"; do
    in_list "$id" "${menu_ids[@]}" || err "install.ps1 menu ID '$id' does not exist in install.sh"
done

ps1_map="$(sed -n '/^\$CATALOG_ID_FOR_MENU_ID = @{/,/^}/p' "$PS1")"
[[ -n "$ps1_map" ]] || err "could not read \$CATALOG_ID_FOR_MENU_ID from install.ps1"
for id in "${menu_ids[@]}"; do
    in_list "$id" "${PS1_MISSING_MENU_IDS[@]}" && continue
    want="$(catalog_id_for_menu_id "$id")"
    got="$(grep -oE "\"$id\" = @\([^)]*\)" <<< "$ps1_map" | sed -E 's/.*@\((.*)\)/\1/; s/"//g; s/, */ /g' || true)"
    if [[ "$want" != "$got" ]]; then
        err "install.ps1 maps '$id' to '${got:-<none>}', install.sh to '${want:-<none>}'"
    fi
done

if (( fail )); then
    echo "catalog.md and the script installers are out of sync." >&2
    exit 1
fi
echo "catalog-sync OK: ${#menu_ids[@]} install.sh menu IDs (${#ps1_ids[@]} in install.ps1), ${#catalog_claude_ids[@]} catalog IDs with a Claude channel."

#!/usr/bin/env bash
# ============================================================
# Plain-bash test runner (no bats dependency).
# Executes every tests/test_*.sh, aggregates pass/fail, and
# exits non-zero if any test script fails.
# ============================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
for t in "$DIR"/test_*.sh; do
    [[ -e "$t" ]] || continue
    echo "=== Running $(basename "$t") ==="
    if bash "$t"; then
        :
    else
        fail=1
    fi
    echo ""
done

if [[ $fail -ne 0 ]]; then
    echo "SUITE: FAIL"
    exit 1
fi
echo "SUITE: PASS"
exit 0

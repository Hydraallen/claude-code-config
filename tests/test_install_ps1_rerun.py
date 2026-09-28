"""Run tests/install_ps1_rerun.ps1 (install.ps1 re-run semantics) under pwsh.

Skipped when pwsh is not on PATH. The script also checks that install.ps1's
tree digest matches install.sh's tree_digest, so both installers agree on
agent-config/script-owned.tsv records.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("pwsh") is None, reason="pwsh not installed"),
]


def bash_digest(rel: str) -> str:
    return subprocess.run(
        ["bash", "-c", f'source ./install.sh; tree_digest "{rel}"'],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.strip()


def test_install_ps1_rerun_units(tmp_path: Path) -> None:
    env = {
        **os.environ,
        "ACCC_SRC": str(ROOT),
        "ACCC_WORK": str(tmp_path),
        "BASH_DIGEST_DIR": bash_digest("platforms/claude/templates/rules/python"),
        "BASH_DIGEST_FILE": bash_digest("platforms/claude/templates/rules/writing-style.md"),
    }
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(ROOT / "tests" / "install_ps1_rerun.ps1")],
        env=env, capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0 and "FAIL" not in result.stdout, result.stdout + result.stderr

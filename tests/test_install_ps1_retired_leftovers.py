"""Run tests/install_ps1_retired_leftovers.ps1 (install.ps1 retired-item
leftover sweep) under pwsh. Skipped when pwsh is not on PATH.
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


def test_install_ps1_retired_leftovers(tmp_path: Path) -> None:
    env = {**os.environ, "ACCC_SRC": str(ROOT), "ACCC_WORK": str(tmp_path)}
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(ROOT / "tests" / "install_ps1_retired_leftovers.ps1")],
        env=env, capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0 and "FAIL" not in result.stdout, result.stdout + result.stderr

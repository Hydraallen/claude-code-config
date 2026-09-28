from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def test_catalog_and_script_installers_are_in_sync() -> None:
    result = subprocess.run(
        ["bash", str(ROOT / "scripts" / "check-catalog-sync.sh")],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr

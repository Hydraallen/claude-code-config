"""install.sh retired-item leftover sweep (prune_retired_leftovers).

Covers the data `claude plugin uninstall` / `marketplace remove` leave behind
for retired plugins: plugin caches and data dirs of retired marketplaces,
stale plugins/cache/temp_git_* clones, ~/.claude-mem, and usage records in
~/.claude.json, including every safety gate that must keep data in place.

Each test sources install.sh inside a throwaway HOME with stubbed `claude`
and `pgrep`, so nothing touches the real ~/.claude or ~/.claude-mem. The last
tests run the whole installer (via the re-run harness) to prove the sweep is
wired into every run and into --uninstall.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import pytest

from test_install_rerun_semantics import Env

ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = ROOT / "install.sh"
BASH = os.environ.get("INSTALL_TEST_BASH", "bash")
BASH = shutil.which(BASH) or BASH  # absolute: some tests run with a minimal PATH

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("jq") is None, reason="install.sh needs jq"),
]

PGREP_STUB = '#!/bin/sh\nexit "${FAKE_PGREP_RC:-1}"\n'
CLAUDE_STUB = "#!/bin/sh\nexit 0\n"

UNRELATED_CFG = {
    "oauthAccount": {"emailAddress": "someone@example.com"},
    "projects": {"/work/claude-mem": {"history": [{"display": "claude-mem:smart-explore"}]}},
    "mcpServers": {"claude-mem": {"command": "x"}},
    "tipsHistory": {"frontend-design-plugin": 3},
    "skillUsage": {
        "claude-mem:smart-explore": {"usageCount": 4},
        "everything-claude-code:configure-ecc": {"usageCount": 1},
        "pua:pua": {"usageCount": 2},
        "ecc:plan": {"usageCount": 9},
        "my-claude-mem-notes": {"usageCount": 1},
        "superpowers:brainstorming": {"usageCount": 5},
    },
    "pluginUsage": {
        "claude-mem@thedotmack": {"usageCount": 7},
        "other@thedotmack": {"usageCount": 1},
        "ecc@ecc": {"usageCount": 3},
        "claude-mem-lite@someone": {"usageCount": 1},
    },
}


class Home:
    def __init__(self, tmp: Path) -> None:
        self.home = tmp / "home"
        self.claude = self.home / ".claude"
        self.plugins = self.claude / "plugins"
        self.bin = tmp / "bin"
        self.bin.mkdir()
        self.plugins.mkdir(parents=True)
        for name, body in (("pgrep", PGREP_STUB), ("claude", CLAUDE_STUB)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)

    def run(self, dry: bool = False, pgrep_rc: int = 1, extra: dict[str, str] | None = None) -> str:
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "LANG": "C",
            "FAKE_PGREP_RC": str(pgrep_rc),
            **(extra or {}),
        }
        script = f'source "{INSTALL_SH}"; DRY_RUN={"true" if dry else "false"}; prune_retired_leftovers'
        res = subprocess.run([BASH, "-c", script], env=env, capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, res.stdout + res.stderr
        return res.stdout + res.stderr

    def installed(self, *keys: str) -> None:
        data = {"version": 2, "plugins": {k: [{"scope": "user"}] for k in keys}}
        (self.plugins / "installed_plugins.json").write_text(json.dumps(data))

    def known(self, *mkts: str) -> None:
        (self.plugins / "known_marketplaces.json").write_text(json.dumps({m: {"source": {}} for m in mkts}))

    def make(self, rel: str, size: int = 10) -> Path:
        p = self.home / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x" * size)
        return p

    def age(self, path: Path, seconds: int) -> None:
        t = time.time() - seconds
        for p in [path, *path.rglob("*")]:
            os.utime(p, (t, t))

    def snapshot(self) -> dict[str, bytes]:
        return {str(p.relative_to(self.home)): p.read_bytes() for p in sorted(self.home.rglob("*")) if p.is_file()}


@pytest.fixture
def h(tmp_path: Path) -> Home:
    return Home(tmp_path)


def seed_retired(h: Home) -> None:
    h.make(".claude/plugins/cache/thedotmack/claude-mem/10.0.0/big.bin", 200_000)
    h.make(".claude/plugins/cache/pua-skills/pua/1.0/SKILL.md")
    h.make(".claude/plugins/cache/claude-health/health/1.0/SKILL.md")
    h.make(".claude/plugins/cache/ecc/ecc/2.0/SKILL.md")  # current marketplace
    h.make(".claude/plugins/marketplaces/thedotmack/README.md")  # stale, unregistered clone
    (h.plugins / "data" / "claude-mem-thedotmack").mkdir(parents=True)
    h.make(".claude/plugins/data/ecc-ecc/state.json")  # current plugin data


@pytest.mark.unit
def test_retired_marketplace_caches_and_data_removed(h: Home) -> None:
    seed_retired(h)
    h.installed("ecc@ecc")
    h.known("ecc")
    out = h.run()
    c = h.plugins
    assert not (c / "cache" / "thedotmack").exists()
    assert not (c / "cache" / "pua-skills").exists()
    assert not (c / "cache" / "claude-health").exists()
    assert not (c / "marketplaces" / "thedotmack").exists()
    assert not (c / "data" / "claude-mem-thedotmack").exists()
    # Non-retired marketplace cache and plugin data are kept.
    assert (c / "cache" / "ecc" / "ecc" / "2.0" / "SKILL.md").is_file()
    assert (c / "data" / "ecc-ecc" / "state.json").is_file()
    assert "Retired leftovers: removed 5 path(s)" in out


@pytest.mark.unit
def test_retired_marketplace_kept_while_a_plugin_still_uses_it(h: Home) -> None:
    seed_retired(h)
    h.installed("claude-mem@thedotmack", "ecc@ecc")
    h.run()
    assert (h.plugins / "cache" / "thedotmack" / "claude-mem" / "10.0.0" / "big.bin").is_file()
    assert (h.plugins / "marketplaces" / "thedotmack").is_dir()
    assert (h.plugins / "data" / "claude-mem-thedotmack").is_dir()
    assert not (h.plugins / "cache" / "pua-skills").exists()


@pytest.mark.unit
def test_registered_retired_marketplace_clone_left_to_cli(h: Home) -> None:
    h.make(".claude/plugins/marketplaces/pua-skills/README.md")
    h.known("pua-skills")
    h.run()
    assert (h.plugins / "marketplaces" / "pua-skills" / "README.md").is_file()


@pytest.mark.unit
def test_unreadable_plugin_state_deletes_nothing(h: Home) -> None:
    seed_retired(h)
    h.make(".claude-mem/claude-mem.db")
    (h.plugins / "installed_plugins.json").write_text("{not json")
    before = h.snapshot()
    out = h.run()
    assert h.snapshot() == before
    assert "skipping retired-item leftover cleanup" in out


@pytest.mark.unit
@pytest.mark.parametrize("state", ['{"version": 2, "plugins": ["claude-mem@thedotmack"]}', '{"version": 3}', "[]"])
def test_unknown_plugin_state_shape_deletes_nothing(h: Home, state: str) -> None:
    seed_retired(h)
    h.make(".claude-mem/claude-mem.db")
    (h.plugins / "installed_plugins.json").write_text(state)
    before = h.snapshot()
    h.run()
    assert h.snapshot() == before


@pytest.mark.unit
def test_symlinked_claude_json_not_replaced(h: Home) -> None:
    real = h.home / "dotfiles" / "claude.json"
    real.parent.mkdir()
    real.write_text(json.dumps(UNRELATED_CFG))
    (h.home / ".claude.json").symlink_to(real)
    h.run()
    assert (h.home / ".claude.json").is_symlink()
    assert json.loads(real.read_text()) == UNRELATED_CFG


@pytest.mark.unit
def test_temp_git_only_old_ones_removed(h: Home) -> None:
    old = h.make(".claude/plugins/cache/temp_git_111/repo/file").parents[1]
    young = h.make(".claude/plugins/cache/temp_git_222/repo/file").parents[1]
    mixed = h.make(".claude/plugins/cache/temp_git_333/repo/old").parents[1]
    h.age(old, 3 * 3600)
    h.age(young, 10 * 60)
    h.age(mixed, 3 * 3600)
    h.make(".claude/plugins/cache/temp_git_333/repo/fresh")  # still being written
    not_temp = h.make(".claude/plugins/cache/ecc/old").parent
    h.age(not_temp, 3 * 3600)
    out = h.run()
    assert not old.exists()
    assert young.is_dir()
    assert mixed.is_dir()
    assert not_temp.is_dir()
    assert "Keeping recent plugin temp clone" in out


@pytest.mark.unit
def test_claude_mem_data_removed_when_retired_and_idle(h: Home) -> None:
    h.make(".claude-mem/claude-mem.db", 5000)
    h.installed("ecc@ecc")
    h.run(pgrep_rc=1)
    assert not (h.home / ".claude-mem").exists()


@pytest.mark.unit
def test_claude_mem_data_kept_while_process_running(h: Home) -> None:
    h.make(".claude-mem/claude-mem.db")
    out = h.run(pgrep_rc=0)
    assert (h.home / ".claude-mem" / "claude-mem.db").is_file()
    assert "claude-mem processes are still running" in out
    assert "re-run" in out


@pytest.mark.unit
def test_claude_mem_data_kept_while_plugin_installed_or_opted_out(h: Home) -> None:
    h.make(".claude-mem/claude-mem.db")
    h.installed("claude-mem@some-fork")
    h.run()
    assert (h.home / ".claude-mem" / "claude-mem.db").is_file()
    h.installed()
    h.run(extra={"ACCC_KEEP_CLAUDE_MEM_DATA": "1"})
    assert (h.home / ".claude-mem" / "claude-mem.db").is_file()


@pytest.mark.unit
def test_claude_json_usage_records_removed_rest_untouched(h: Home) -> None:
    cfg = h.home / ".claude.json"
    cfg.write_text(json.dumps(UNRELATED_CFG, indent=2))
    h.installed("ecc@ecc")
    out = h.run()
    data = json.loads(cfg.read_text())
    assert set(data["skillUsage"]) == {"ecc:plan", "my-claude-mem-notes", "superpowers:brainstorming"}
    assert set(data["pluginUsage"]) == {"ecc@ecc", "claude-mem-lite@someone"}
    for key in ("oauthAccount", "projects", "mcpServers", "tipsHistory"):
        assert data[key] == UNRELATED_CFG[key]
    baks = list(h.home.glob(".claude.json.*.bak"))
    assert len(baks) == 1 and json.loads(baks[0].read_text()) == UNRELATED_CFG
    assert "Removed 5 retired usage record(s)" in out
    # Second run: nothing left to change, so no new backup.
    time.sleep(1.1)
    h.run()
    assert len(list(h.home.glob(".claude.json.*.bak"))) == 1


@pytest.mark.unit
def test_claude_json_keeps_records_of_still_installed_plugin(h: Home) -> None:
    cfg = h.home / ".claude.json"
    cfg.write_text(json.dumps(UNRELATED_CFG))
    h.installed("claude-mem@thedotmack")
    h.run()
    data = json.loads(cfg.read_text())
    assert "claude-mem:smart-explore" in data["skillUsage"]
    assert "claude-mem@thedotmack" in data["pluginUsage"]
    assert "other@thedotmack" in data["pluginUsage"]
    assert "pua:pua" not in data["skillUsage"]


@pytest.mark.unit
def test_claude_json_invalid_left_alone(h: Home) -> None:
    cfg = h.home / ".claude.json"
    cfg.write_text('{"skillUsage": {"claude-mem:x": 1}')
    out = h.run()
    assert cfg.read_text() == '{"skillUsage": {"claude-mem:x": 1}'
    assert not list(h.home.glob(".claude.json.*.bak"))
    assert "not valid JSON" in out


@pytest.mark.unit
def test_claude_json_python_fallback(h: Home, tmp_path: Path) -> None:
    # PATH without jq: only the stubs plus symlinks to the tools the sweep uses.
    tools = tmp_path / "tools"
    tools.mkdir()
    for tool in ("python3", "du", "awk", "find", "head", "rm", "mv", "cp", "mktemp", "chmod", "cksum",
                 "date", "sed", "grep", "basename", "dirname", "cat", "ps", "uname", "tr"):
        src = shutil.which(tool)
        if src:
            (tools / tool).symlink_to(src)
    cfg = h.home / ".claude.json"
    cfg.write_text(json.dumps(UNRELATED_CFG))
    h.installed("ecc@ecc")
    h.run(extra={"PATH": f"{h.bin}:{tools}"})
    data = json.loads(cfg.read_text())
    assert set(data["pluginUsage"]) == {"ecc@ecc", "claude-mem-lite@someone"}
    assert data["projects"] == UNRELATED_CFG["projects"]


@pytest.mark.unit
def test_dry_run_previews_with_sizes_and_changes_nothing(h: Home) -> None:
    seed_retired(h)
    h.make(".claude-mem/claude-mem.db", 3000)
    old = h.make(".claude/plugins/cache/temp_git_9/f").parent
    h.age(old, 7200)
    (h.home / ".claude.json").write_text(json.dumps(UNRELATED_CFG))
    # claude-mem still installed: the retired sweep (stub claude on PATH) would
    # uninstall it first, so the preview must already count its leftovers.
    h.installed("claude-mem@thedotmack", "ecc@ecc")
    before = h.snapshot()
    out = h.run(dry=True)
    assert h.snapshot() == before
    for needle in (
        "Would remove retired marketplace plugin cache: " + str(h.plugins / "cache" / "thedotmack"),
        "Would remove stale retired marketplace clone: ",
        "Would remove retired plugin data dir: ",
        "Would remove stale plugin temp clone: ",
        "Would remove retired claude-mem data: " + str(h.home / ".claude-mem"),
        "Would remove retired usage record from ~/.claude.json: skillUsage[claude-mem:smart-explore]",
        "Would remove retired usage record from ~/.claude.json: pluginUsage[claude-mem@thedotmack]",
        "Retired leftovers: would remove 7 path(s)",
    ):
        assert needle in out, needle
    assert " KB)" in out or " MB)" in out


def seed_full(e: Env) -> None:
    (e.claude / "plugins" / "cache" / "thedotmack" / "claude-mem" / "1.0").mkdir(parents=True)
    (e.claude / "plugins" / "cache" / "thedotmack" / "claude-mem" / "1.0" / "x").write_text("x")
    (e.home / ".claude-mem").mkdir()
    (e.home / ".claude-mem" / "db").write_text("x")
    (e.home / ".claude.json").write_text(json.dumps({"skillUsage": {"claude-mem:smart-explore": {}}, "numStartups": 3}))


@pytest.fixture
def full_env(tmp_path: Path) -> Env:
    e = Env(tmp_path)
    # Neutralise any real claude-mem process on the test machine.
    pgrep = e.bin / "pgrep"
    pgrep.write_text(PGREP_STUB)
    pgrep.chmod(0o755)
    return e


def test_sweep_runs_on_non_interactive_only_run(full_env: Env) -> None:
    e = full_env
    e.seed_plugin("claude-mem@thedotmack")
    seed_full(e)
    e.run("--only", "claude-md")
    assert "claude-mem@thedotmack" not in e.plugins()
    assert not (e.claude / "plugins" / "cache" / "thedotmack").exists()
    assert not (e.home / ".claude-mem").exists()
    data = json.loads((e.home / ".claude.json").read_text())
    assert data["skillUsage"] == {} and data["numStartups"] == 3


def test_sweep_runs_on_uninstall(full_env: Env) -> None:
    e = full_env
    seed_full(e)
    e.run("--uninstall", "--force")
    assert not (e.claude / "plugins" / "cache" / "thedotmack").exists()
    assert not (e.home / ".claude-mem").exists()

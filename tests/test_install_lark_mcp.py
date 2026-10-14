"""install.sh Lark MCP modes: one shared localhost service (launchd on macOS,
a systemd user unit on Linux / WSL with systemd) with a per-session stdio
launcher as fallback, migration from the old npx registration, ownership
detection and removal.

Builds on the throwaway-HOME harness of test_install_rerun_semantics.py, whose
stubs cover npm / node / launchctl / systemctl / security / the localhost curl
health check, and `uname -s` (FAKE_UNAME). Credentials come from a seeded old
npx registration, exactly as an existing user's ~/.claude.json carries them.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess

import pytest

from test_install_rerun_semantics import BASH, INSTALL_SH, Env, pytestmark  # noqa: F401

APP_ID = "cli_test123"
SECRET = "s3cretValue"
OLD_ARGS = ["-y", "@larksuiteoapi/lark-mcp", "mcp", "-a", APP_ID, "-s", SECRET, "-t", "preset.light"]
URL = "http://127.0.0.1:3100/mcp"


class LarkEnv(Env):
    def __init__(self, tmp: Path) -> None:
        super().__init__(tmp)
        self.conf = self.home / ".config" / "lark-mcp"
        self.plist = self.home / "Library" / "LaunchAgents" / "com.claude-code-config.lark-mcp.plist"
        self.unit = self.home / ".config" / "systemd" / "user" / "lark-mcp.service"
        self.systemd_run = tmp / "run-systemd"

    def seed_old(self) -> None:
        self.seed_mcp("lark-mcp", "npx", OLD_ARGS)

    def stub_log(self, name: str) -> str:
        path = self.home / ".stub" / f"{name}-calls.log"
        return path.read_text() if path.exists() else ""

    def keychain(self) -> dict:
        path = self.home / ".stub" / "keychain.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def darwin(self, *args: str, menu: str | None = None, **env: str) -> subprocess.CompletedProcess:
        return self.run(*args, menu=menu, extra={"FAKE_UNAME": "Darwin", **env})

    def linux(self, *args: str, systemd: bool = True, **env: str) -> subprocess.CompletedProcess:
        if systemd:
            self.systemd_run.mkdir(exist_ok=True)
        extra = {"FAKE_UNAME": "Linux", "ACCC_TEST_SYSTEMD_RUN_DIR": str(self.systemd_run), **env}
        return self.run(*args, extra=extra)

    def is_ours(self) -> bool:
        script = f'source "{INSTALL_SH}"; mcp_is_ours lark-mcp'
        env = {"HOME": str(self.home), "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}", "LANG": "C"}
        return subprocess.run([BASH, "-c", script], env=env, capture_output=True, timeout=60).returncode == 0


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


@pytest.fixture
def lark(tmp_path: Path) -> LarkEnv:
    return LarkEnv(tmp_path)


def test_darwin_migrates_npx_entry_to_launchd_service(lark: LarkEnv) -> None:
    lark.seed_old()
    out = lark.darwin("--only", "mcp-lark").stdout

    assert lark.mcp()["lark-mcp"] == {"type": "http", "url": URL}
    assert "@larksuiteoapi/lark-mcp@0.5.1" in lark.stub_log("npm")
    plist = lark.plist.read_text()
    assert "<string>com.claude-code-config.lark-mcp</string>" in plist
    assert f"<string>{lark.conf / 'run.sh'}</string>" in plist and "<string>http</string>" in plist
    assert "KeepAlive" in plist and "RunAtLoad" in plist and "lark-mcp.log" in plist
    assert "bootstrap gui/" in lark.stub_log("launchctl")
    # Secret only in the (stubbed) Keychain, set through `security -i` (stdin).
    env = (lark.conf / "env").read_text()
    assert f"APP_ID={APP_ID}" in env and "LARK_MCP_PORT=3100" in env and "LARK_TOOLS=preset.light" in env
    assert SECRET not in env
    assert lark.keychain() == {f"claude-code-config.lark-mcp|{APP_ID}": SECRET}
    assert SECRET not in lark.stub_log("security")
    assert SECRET not in (lark.home / ".claude.json").read_text()
    assert mode(lark.conf / "env") == 0o600 and mode(lark.conf / "run.sh") == 0o700
    assert (lark.conf / "installed-by-claude-code-config").is_file()
    assert "shared launchd service" in out
    assert lark.is_ours()
    detail = lark.selection()["items"]["lark"]["lark"]
    assert detail == {"mode": "shared", "url": URL, "healthy": True, "service": "launchd"}


def test_rerun_keeps_registration_and_reuses_saved_credentials(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    bootstraps = lark.stub_log("launchctl").count("bootstrap")
    lark.darwin("--only", "mcp-lark")

    assert not any(c.startswith(("mcp remove", "mcp add")) for c in lark.calls())
    assert lark.stub_log("launchctl").count("bootstrap") == bootstraps
    assert lark.mcp()["lark-mcp"]["url"] == URL


def test_rerun_keeps_user_settings_in_env_file(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    env = lark.conf / "env"
    env.write_text(env.read_text().replace("LARK_TOOLS=preset.light", "LARK_TOOLS=preset.light,preset.doc.default")
                   + "LARK_DOMAIN=https://open.larksuite.com\n")
    lark.darwin("--only", "mcp-lark")

    text = env.read_text()
    assert "LARK_TOOLS=preset.light,preset.doc.default" in text
    assert "LARK_DOMAIN=https://open.larksuite.com" in text


def test_unwritable_npm_prefix_falls_back_to_npx_launcher(lark: LarkEnv) -> None:
    root = lark.home / ".stub" / "npm-global" / "lib" / "node_modules"
    root.mkdir(parents=True)
    root.chmod(0o555)
    try:
        lark.seed_old()
        out = lark.darwin("--only", "mcp-lark").stdout
    finally:
        root.chmod(0o755)

    assert "not writable" in out and "npm config set prefix" in out
    assert "install" not in lark.stub_log("npm")
    assert lark.mcp()["lark-mcp"]["command"] == str(lark.conf / "run.sh")
    assert "npx -y '@larksuiteoapi/lark-mcp@0.5.1'" in (lark.conf / "run.sh").read_text()
    assert not lark.plist.exists()


def test_port_override_moves_registration(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    lark.darwin("--only", "mcp-lark", LARK_MCP_PORT="3200")

    assert lark.mcp()["lark-mcp"]["url"] == "http://127.0.0.1:3200/mcp"
    assert "LARK_MCP_PORT=3200" in (lark.conf / "env").read_text()
    assert any(c.startswith("mcp remove lark-mcp") for c in lark.calls())


def test_linux_with_systemd_uses_user_unit(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.linux("--only", "mcp-lark")

    assert lark.mcp()["lark-mcp"] == {"type": "http", "url": URL}
    unit = lark.unit.read_text()
    assert f"EnvironmentFile={lark.conf / 'env'}\n" in unit
    assert "mcp -m streamable --host 127.0.0.1 -p 3100" in unit
    assert "Restart=on-failure" in unit and "WantedBy=default.target" in unit
    calls = lark.stub_log("systemctl")
    assert "--user daemon-reload" in calls and "--user enable lark-mcp.service" in calls
    assert "--user restart lark-mcp.service" in calls
    env = lark.conf / "env"
    assert f"APP_SECRET={SECRET}" in env.read_text() and mode(env) == 0o600
    assert not lark.plist.exists() and lark.keychain() == {}


def test_wsl_without_systemd_falls_back_to_stdio_launcher(lark: LarkEnv) -> None:
    lark.seed_old()
    out = lark.linux("--only", "mcp-lark", systemd=False, WSL_DISTRO_NAME="Test").stdout

    srv = lark.mcp()["lark-mcp"]
    assert srv["command"] == str(lark.conf / "run.sh") and srv["args"] == []
    assert SECRET not in (lark.home / ".claude.json").read_text()
    assert "per-session stdio" in out and "WSL" in out
    assert not lark.unit.exists() and lark.stub_log("systemctl").count("enable") == 0
    wrapper = (lark.conf / "run.sh").read_text()
    assert "@larksuiteoapi/lark-mcp/dist/cli.js" in wrapper and "npx" not in wrapper
    assert lark.is_ours()
    assert lark.selection()["items"]["lark"]["lark"] == {"mode": "stdio"}


def test_failed_health_check_removes_service_and_falls_back(lark: LarkEnv) -> None:
    lark.seed_old()
    out = lark.darwin("--only", "mcp-lark", FAKE_LARK_HEALTH="fail").stdout

    assert lark.mcp()["lark-mcp"]["command"] == str(lark.conf / "run.sh")
    assert not lark.plist.exists()
    assert "bootout" in lark.stub_log("launchctl")
    assert "did not answer an MCP initialize" in out


def test_ownership_detection(lark: LarkEnv) -> None:
    lark.seed_mcp("lark-mcp", "npx", OLD_ARGS)
    assert lark.is_ours()
    # http / launcher entries count as ours only with the marker.
    cfg = lark.home / ".claude.json"
    cfg.write_text(json.dumps({"mcpServers": {"lark-mcp": {"type": "http", "url": URL}}}))
    assert not lark.is_ours()
    lark.conf.mkdir(parents=True)
    (lark.conf / "installed-by-claude-code-config").write_text("")
    assert lark.is_ours()
    cfg.write_text(json.dumps({"mcpServers": {"lark-mcp": {"type": "http", "url": "http://127.0.0.1:9999/mcp"}}}))
    assert not lark.is_ours()
    lark.seed_mcp("lark-mcp", str(lark.conf / "run.sh"), [])
    assert lark.is_ours()
    lark.seed_mcp("lark-mcp", "node", ["/opt/my-lark/cli.js"])
    assert not lark.is_ours()


def test_foreign_entry_left_in_place(lark: LarkEnv) -> None:
    lark.seed_mcp("lark-mcp", "node", ["/opt/my-lark/cli.js", "mcp"])
    out = lark.darwin("--only", "mcp-lark").stdout

    assert lark.mcp()["lark-mcp"]["command"] == "node"
    assert "not registered by this installer" in out
    assert lark.stub_log("npm") == "" and not lark.conf.exists()


def test_deselect_removes_service_settings_and_keychain_item(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    out = lark.darwin(menu="claude-md").stdout

    assert "lark-mcp" not in lark.mcp()
    assert not lark.plist.exists() and not lark.conf.exists()
    assert lark.keychain() == {}
    assert "Removed the lark-mcp service" in out


def test_uninstall_removes_systemd_unit(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.linux("--only", "mcp-lark")
    lark.linux("--uninstall", "--force")

    assert "lark-mcp" not in lark.mcp()
    assert not lark.unit.exists() and not lark.conf.exists()
    assert "--user disable --now lark-mcp.service" in lark.stub_log("systemctl")


def test_health_check_bypasses_http_proxy(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark", http_proxy="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9")

    assert lark.mcp()["lark-mcp"]["url"] == URL
    calls = lark.stub_log("curl").splitlines()
    assert calls and all("--noproxy *" in c for c in calls)


SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


@pytest.mark.skipif(shutil.which("claude", path=SYSTEM_PATH) is not None, reason="claude on the system PATH")
@pytest.mark.skipif(shutil.which("jq", path=SYSTEM_PATH) is None, reason="needs jq on the system PATH")
def test_uninstall_without_claude_cli_still_removes_local_setup(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    (lark.bin / "claude").unlink()
    out = lark.darwin("--uninstall", "--force", PATH=f"{lark.bin}:{SYSTEM_PATH}").stdout

    assert "Claude CLI not found" in out
    assert not lark.plist.exists() and not lark.conf.exists()
    assert lark.keychain() == {}


def test_new_app_id_deletes_old_keychain_item(lark: LarkEnv) -> None:
    # Saved App ID cli_old whose secret cannot be read; the old npx entry
    # supplies new credentials, and cli_old's Keychain item must not linger.
    lark.conf.mkdir(parents=True)
    (lark.conf / "env").write_text("APP_ID=cli_old\nLARK_TOOLS=preset.light\nLARK_MCP_PORT=3100\n")
    (lark.conf / "installed-by-claude-code-config").write_text("")
    (lark.home / ".stub" / "keychain.json").write_text(json.dumps({"claude-code-config.lark-mcp|cli_old": "old"}))
    lark.seed_old()
    lark.darwin("--only", "mcp-lark", FAKE_KEYCHAIN_HIDE="cli_old")

    assert lark.keychain() == {f"claude-code-config.lark-mcp|{APP_ID}": SECRET}
    assert f"APP_ID={APP_ID}" in (lark.conf / "env").read_text()


def test_failed_registration_restores_previous_entry(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    out = lark.darwin("--only", "mcp-lark", LARK_MCP_PORT="3200", FAKE_CLAUDE_MCP_ADD_FAIL="1").stdout

    assert lark.mcp()["lark-mcp"] == {"type": "http", "url": URL}
    assert "Restored the previous lark-mcp registration" in out
    # The env file already says 3200; the entry on 3100 is still recognized.
    assert "LARK_MCP_PORT=3200" in (lark.conf / "env").read_text()
    assert lark.is_ours()


def test_package_upgrade_restarts_service(lark: LarkEnv) -> None:
    lark.seed_old()
    lark.darwin("--only", "mcp-lark")
    pkg = lark.home / ".stub" / "npm-global" / "lib" / "node_modules" / "@larksuiteoapi" / "lark-mcp" / "package.json"
    pkg.write_text(json.dumps({"name": "@larksuiteoapi/lark-mcp", "version": "0.5.0"}))
    bootstraps = lark.stub_log("launchctl").count("bootstrap")
    lark.darwin("--only", "mcp-lark")

    assert lark.stub_log("npm").count("install -g") == 2
    assert lark.stub_log("launchctl").count("bootstrap") == bootstraps + 1

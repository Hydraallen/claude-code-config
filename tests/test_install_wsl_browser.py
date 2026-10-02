"""install.sh inside WSL: Playwright MCP runs under a Windows node.exe and drives
the Windows Chrome; outside WSL nothing changes.

Builds on the throwaway-HOME harness of test_install_rerun_semantics.py and adds
stubs for the WSL interop pieces: `cmd.exe` (echo %VAR% / where node.exe),
`wslpath` (C:\\... <-> <tmp>/c/...) and a Windows `node.exe` that fakes both
`npm install` and a Playwright MCP server answering with a Windows user agent.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess

import pytest

from test_install_rerun_semantics import BASH, INSTALL_SH, Env, pytestmark  # noqa: F401

PLUGIN = "playwright@claude-plugins-official"

CMD_STUB = r'''#!/usr/bin/env python3
import os, sys
line = " ".join(a for a in sys.argv[1:] if a.lower() not in ("/d", "/c"))
env = {
    "LOCALAPPDATA": r"C:\Users\me\AppData\Local",
    "ProgramFiles": r"C:\Program Files",
    "ProgramFiles(x86)": r"C:\Program Files (x86)",
    "PROCESSOR_ARCHITECTURE": "AMD64",
}
if line.startswith("echo %") and line.endswith("%"):
    name = line[6:-1]
    print(env.get(name, f"%{name}%"), end="\r\n")
elif line == "where node.exe":
    if os.environ.get("FAKE_WIN_NODE") == "1":
        print(r"C:\Program Files\nodejs\node.exe", end="\r\n")
    else:
        print("INFO: Could not find files for the given pattern(s).", file=sys.stderr)
        sys.exit(1)
'''

WSLPATH_STUB = r'''#!/usr/bin/env python3
import os, sys
root = os.environ["FAKE_WIN_ROOT"]
mode, path = sys.argv[1], sys.argv[2]
if mode == "-u":
    drive, rest = path[0].lower(), path[3:].replace("\\", "/")
    print(f"{root}/{drive}/{rest}")
else:
    prefix = root + "/c/"
    if path.startswith(prefix):
        print("C:\\" + path[len(prefix):].replace("/", "\\"))
    else:
        print("\\\\wsl.localhost\\Test" + path.replace("/", "\\"))
'''

NODE_STUB = r'''#!/usr/bin/env python3
import json, os, sys
root = os.environ["FAKE_WIN_ROOT"]

def unix(p):
    return f"{root}/{p[0].lower()}/{p[3:].replace(chr(92), '/')}"

args = sys.argv[1:]
log = os.path.join(os.environ["HOME"], ".stub", "node-calls.log")
with open(log, "a") as fh:
    fh.write(json.dumps(args) + "\n")
if args and args[0].endswith("npm-cli.js"):
    prefix = unix(args[args.index("--prefix") + 1])
    version = args[-1].rsplit("@", 1)[1]
    pkg = os.path.join(prefix, "node_modules", "@playwright", "mcp")
    os.makedirs(pkg, exist_ok=True)
    with open(os.path.join(pkg, "package.json"), "w") as fh:
        json.dump({"name": "@playwright/mcp", "version": version}, fh)
    open(os.path.join(pkg, "cli.js"), "w").close()
    sys.exit(0)
ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/150.0.0.0 Safari/537.36"
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    if msg["method"] == "initialize":
        result = {"protocolVersion": "2025-06-18", "serverInfo": {"name": "Playwright", "version": "stub"}, "capabilities": {}}
    elif msg["params"]["name"] == "browser_evaluate":
        result = {"content": [{"type": "text", "text": "### Result\n\"" + ua + "\""}]}
    else:
        result = {"content": [{"type": "text", "text": "ok"}]}
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
'''

CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"


class WslEnv(Env):
    def __init__(self, tmp: Path, *, wsl: bool = True, chrome: bool = True, node: bool = True) -> None:
        super().__init__(tmp)
        self.win = tmp / "win"
        self.wsl = wsl
        self.node = node
        if wsl:
            for name, body in (("cmd.exe", CMD_STUB), ("wslpath", WSLPATH_STUB)):
                path = self.bin / name
                path.write_text(body)
                path.chmod(0o755)
        if chrome:
            exe = self.win / "c" / "Program Files" / "Google" / "Chrome" / "Application" / "chrome.exe"
            exe.parent.mkdir(parents=True)
            exe.write_text("")
        if node:
            nodejs = self.win / "c" / "Program Files" / "nodejs"
            (nodejs / "node_modules" / "npm" / "bin").mkdir(parents=True)
            (nodejs / "node_modules" / "npm" / "bin" / "npm-cli.js").write_text("")
            (nodejs / "node.exe").write_text(NODE_STUB)
            (nodejs / "node.exe").chmod(0o755)

    @property
    def node_exe(self) -> str:
        return str(self.win / "c" / "Program Files" / "nodejs" / "node.exe")

    @property
    def windows_root(self) -> Path:
        return self.win / "c" / "Users" / "me" / "AppData" / "Local" / "claude-code-config"

    def run(self, *args: str, menu: str | None = None, state_out: bool = False,
            extra: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "TMPDIR": str(self.home / ".stub"),
            "NET_TIMEOUT": "20",
            "LANG": "C",
            "FAKE_WIN_ROOT": str(self.win),
            "FAKE_WIN_NODE": "1" if self.node else "0",
        }
        if self.wsl:
            env["WSL_DISTRO_NAME"] = "Test"
        if menu is not None:
            env["ACCC_TEST_MENU_IDS"] = menu
        if state_out:
            env["ACCC_TEST_MENU_STATE_OUT"] = str(self.home / ".stub" / "menu-state.txt")
        env.update(extra or {})
        (self.home / ".stub" / "claude-calls.log").write_text("")
        result = subprocess.run(
            [BASH, str(INSTALL_SH), *args],
            env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600,
        )
        assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
        return result


@pytest.fixture
def wsl(tmp_path: Path) -> WslEnv:
    return WslEnv(tmp_path)


def test_wsl_registers_windows_chrome_and_reports_connection(wsl: WslEnv) -> None:
    out = wsl.run("--only", "plug-playwright").stdout

    srv = wsl.mcp()["playwright"]
    assert srv["command"] == wsl.node_exe
    assert srv["args"][0] == r"C:\Users\me\AppData\Local\claude-code-config\playwright-mcp\node_modules\@playwright\mcp\cli.js"
    assert srv["args"][1:5] == ["--browser", "chrome", "--executable-path", CHROME]
    assert srv["args"][5] == "--output-dir"
    assert srv["args"][6].startswith("\\\\wsl.localhost\\Test")
    assert PLUGIN not in wsl.plugins()
    assert (wsl.windows_root / ".claude-code-config-owned").is_file()
    assert "Playwright MCP is connected to the Windows browser" in out
    assert "Windows NT 10.0" in out
    assert f"Browser (WSL): Playwright MCP connected to Windows chrome ({CHROME})" in out


def test_wsl_rerun_keeps_registration(wsl: WslEnv) -> None:
    wsl.run("--only", "plug-playwright")
    out = wsl.run("--only", "plug-playwright").stdout
    assert "already points at the Windows browser" in out
    assert not any(c.startswith("mcp add") for c in wsl.calls())


def test_wsl_replaces_linux_registration_and_plugin(wsl: WslEnv) -> None:
    wsl.seed_mcp("playwright", "npx", ["@playwright/mcp@latest"])
    wsl.seed_plugin(PLUGIN)
    wsl.run("--only", "mcp")
    assert wsl.mcp()["playwright"]["command"] == wsl.node_exe
    assert PLUGIN not in wsl.plugins()


def test_wsl_leaves_foreign_registration(wsl: WslEnv) -> None:
    wsl.seed_mcp("playwright", "/usr/local/bin/my-playwright", [])
    out = wsl.run("--only", "mcp").stdout
    assert wsl.mcp()["playwright"]["command"] == "/usr/local/bin/my-playwright"
    assert "Browser (WSL): Playwright MCP NOT connected" in out


def test_wsl_browser_linux_keeps_plugin(wsl: WslEnv) -> None:
    wsl.run("--only", "plug-playwright", "--wsl-browser", "linux")
    assert PLUGIN in wsl.plugins()
    assert "playwright" not in wsl.mcp()


def test_wsl_without_windows_browser_keeps_plugin(tmp_path: Path) -> None:
    env = WslEnv(tmp_path, chrome=False)
    out = env.run("--only", "plug-playwright").stdout
    assert PLUGIN in env.plugins()
    assert "playwright" not in env.mcp()
    assert "Playwright will use a Linux browser: no Chrome or Edge found on Windows" in out


def test_outside_wsl_nothing_changes(tmp_path: Path) -> None:
    env = WslEnv(tmp_path, wsl=False)
    env.run("--only", "plug-playwright,mcp")
    assert PLUGIN in env.plugins()
    assert env.mcp()["playwright"] == {"type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"]}
    assert not (env.home / ".stub" / "node-calls.log").exists()


def test_wsl_deselect_and_uninstall_remove_windows_files(wsl: WslEnv) -> None:
    wsl.run("--only", "mcp")
    assert wsl.windows_root.is_dir()
    wsl.run(menu="claude-md")
    assert "playwright" not in wsl.mcp()
    assert not wsl.windows_root.exists()

    wsl.run("--only", "mcp")
    wsl.run("--uninstall", "--force")
    assert not wsl.windows_root.exists()


def test_wsl_dry_run_names_windows_browser(wsl: WslEnv) -> None:
    out = wsl.run("--dry-run", "--only", "plug-playwright").stdout
    assert f"driving {CHROME}" in out
    assert "playwright" not in wsl.mcp()
    assert not wsl.windows_root.exists()


def test_wsl_failed_windows_setup_keeps_plugin(tmp_path: Path) -> None:
    env = WslEnv(tmp_path, node=False)
    curl = env.bin / "curl"
    curl.write_text("#!/bin/sh\nexit 22\n")
    curl.chmod(0o755)
    env.seed_plugin(PLUGIN)
    out = env.run(menu="plug-playwright").stdout
    assert PLUGIN in env.plugins()
    assert "playwright" not in env.mcp()
    assert "Browser (WSL): Playwright MCP NOT connected" in out


def test_wsl_shared_windows_root_kept_for_other_distro(wsl: WslEnv) -> None:
    wsl.run("--only", "mcp", extra={"WSL_DISTRO_NAME": "Other"})
    wsl.run("--only", "mcp")
    wsl.run("--uninstall", "--force")
    assert wsl.windows_root.is_dir()
    assert {p.name for p in (wsl.windows_root / ".owners").iterdir()} == {"Other"}


def test_wsl_browser_linux_replaces_windows_registration(wsl: WslEnv) -> None:
    wsl.run("--only", "mcp")
    wsl.run("--only", "mcp", "--wsl-browser", "linux")
    assert wsl.mcp()["playwright"]["command"] == "npx"


def test_platform_line_wsl_chrome(wsl: WslEnv) -> None:
    out = wsl.run("--dry-run", "--only", "claude-md").stdout
    assert "Platform: WSL (Test) — Playwright → Windows Chrome" in out


def test_platform_line_wsl_linux_override(wsl: WslEnv) -> None:
    out = wsl.run("--dry-run", "--only", "claude-md", "--wsl-browser", "linux").stdout
    assert "Platform: WSL (Test) — Playwright → playwright plugin, Linux browser (--wsl-browser linux)" in out


def test_platform_line_wsl_no_browser(tmp_path: Path) -> None:
    out = WslEnv(tmp_path, chrome=False).run("--dry-run", "--only", "claude-md").stdout
    assert "Linux browser (no Chrome or Edge found on Windows)" in out


def test_platform_line_outside_wsl(tmp_path: Path) -> None:
    out = WslEnv(tmp_path, wsl=False).run("--dry-run", "--only", "claude-md").stdout
    os_name = "macOS" if os.uname().sysname == "Darwin" else "Linux"
    assert f"Platform: {os_name} — Playwright → playwright plugin" in out

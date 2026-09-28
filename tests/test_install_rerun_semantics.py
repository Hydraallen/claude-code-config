"""install.sh re-run semantics: detected initial menu state, "unchecked => removed"
on interactive runs only, and additive --all / --only / non-interactive runs.

Every run uses a throwaway HOME, a stubbed `claude` CLI (records its calls and
keeps plugins / marketplaces / MCP servers as files), a stubbed `npx` and a
`git` wrapper that fakes the DeepXiv clone and refuses every other clone, so
nothing touches the network or the real ~/.claude. The interactive selector is
driven through install.sh's internal ACCC_TEST_MENU_IDS hook.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import textwrap

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = ROOT / "install.sh"
REAL_GIT = shutil.which("git") or "/usr/bin/git"
# Run with INSTALL_TEST_BASH=/bin/bash to exercise macOS's bash 3.2.
BASH = os.environ.get("INSTALL_TEST_BASH", "bash")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(shutil.which("jq") is None, reason="install.sh needs jq"),
]

CLAUDE_STUB = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path

home = Path(os.environ["HOME"])
log = home / ".stub" / "claude-calls.log"
log.parent.mkdir(parents=True, exist_ok=True)
args = sys.argv[1:]
with log.open("a") as fh:
    fh.write(" ".join(args) + "\n")
plugins_dir = home / ".claude" / "plugins"
state = plugins_dir / "installed_plugins.json"
cfg = home / ".claude.json"
MKT = {
    "anthropics/skills": "anthropic-agent-skills",
    "affaan-m/everything-claude-code": "ecc",
    "Orchestra-Research/AI-research-SKILLs": "ai-research-skills",
    "blader/humanizer": "humanizer",
    "anthropics/claude-plugins-official": "claude-plugins-official",
    "openai/codex-plugin-cc": "openai-codex",
    "forrestchang/andrej-karpathy-skills": "karpathy-skills",
    "zarazhangrui/frontend-slides": "frontend-slides",
    "hugohe3/ppt-master": "ppt-master",
}

def load(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default

def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2))

rest = [a for a in args if a not in ("--scope", "user", "--transport", "stdio")]
if args[:1] == ["--version"]:
    print("2.1.200 (Claude Code)")
elif args[:3] == ["plugin", "marketplace", "add"]:
    repo = args[3].split("github.com/")[-1]
    mdir = plugins_dir / "marketplaces" / MKT.get(repo, repo.split("/")[-1])
    (mdir / ".claude-plugin").mkdir(parents=True, exist_ok=True)
    (mdir / ".claude-plugin" / "marketplace.json").write_text("{}")
elif args[:3] == ["plugin", "marketplace", "remove"]:
    mdir = plugins_dir / "marketplaces" / args[3]
    if not mdir.is_dir():
        sys.exit(1)
    shutil.rmtree(mdir)
elif args[:3] == ["plugin", "marketplace", "update"]:
    pass
elif rest[:2] == ["plugin", "install"]:
    data = load(state, {"version": 2, "plugins": {}})
    data["plugins"][rest[2]] = [{"scope": "user"}]
    save(state, data)
elif rest[:2] == ["plugin", "uninstall"]:
    data = load(state, {"version": 2, "plugins": {}})
    if rest[2] not in data["plugins"]:
        sys.exit(1)
    del data["plugins"][rest[2]]
    save(state, data)
elif rest[:2] == ["plugin", "update"]:
    pass
elif rest[:2] == ["mcp", "list"]:
    for name, srv in load(cfg, {}).get("mcpServers", {}).items():
        print(f"{name}: {srv.get('command', '')} {' '.join(srv.get('args', []))} - Connected")
elif rest[:2] == ["mcp", "add"]:
    sep = args.index("--")
    name = [a for a in args[2:sep] if a not in ("--scope", "user", "--transport", "stdio")][0]
    data = load(cfg, {})
    data.setdefault("mcpServers", {})[name] = {"type": "stdio", "command": args[sep + 1], "args": args[sep + 2:]}
    save(cfg, data)
elif rest[:2] == ["mcp", "remove"]:
    data = load(cfg, {})
    if rest[2] not in data.get("mcpServers", {}):
        sys.exit(1)
    del data["mcpServers"][rest[2]]
    save(cfg, data)
'''

NPX_STUB = r'''#!/usr/bin/env bash
# Fake `npx skills add <repo> ... --skill X [--skill Y]`: write each skill.
set -u
echo "$*" >> "$HOME/.stub/npx-calls.log"
want=false
for a in "$@"; do
    if $want; then
        mkdir -p "$HOME/.claude/skills/$a"
        printf -- '---\nname: %s\ndescription: stub %s\n---\n\nstub body for %s\n' "$a" "$a" "$a" > "$HOME/.claude/skills/$a/SKILL.md"
        if [[ "$a" == image-gen ]]; then
            mkdir -p "$HOME/.claude/skills/$a/scripts"
            echo 'print("stub")' > "$HOME/.claude/skills/$a/scripts/image_gen.py"
        fi
        want=false
    fi
    [[ "$a" == "--skill" ]] && want=true
done
exit 0
'''

GIT_STUB = r'''#!/usr/bin/env bash
# Fake the DeepXiv clone, refuse every other clone (no network), pass the rest
# (git -C <repo> rev-parse ... for the selection record) to the real git.
if [[ "${1-}" == "clone" ]]; then
    for a in "$@"; do dest="$a"; done
    case "$*" in
        *deepxiv_sdk*)
            for s in deepxiv-cli deepxiv-trending-digest deepxiv-baseline-table; do
                mkdir -p "$dest/skills/$s"
                printf 'stub %s\n' "$s" > "$dest/skills/$s/SKILL.md"
            done
            exit 0 ;;
        *) echo "git stub: no network in tests" >&2; exit 128 ;;
    esac
fi
exec "__REAL_GIT__" "$@"
'''

ZSHRC = textwrap.dedent(
    """\
    export KEEP_ME=1
    source ~/.claude/claude.zsh
    [ -f ~/.claude/claude.zsh ] && source ~/.claude/claude.zsh
    alias ll='ls -l'
    """
)

FOREIGN_PLUGIN = "foreign-tool@my-market"


class Env:
    def __init__(self, tmp: Path) -> None:
        self.home = tmp / "home"
        self.claude = self.home / ".claude"
        self.bin = tmp / "bin"
        (self.home / ".stub").mkdir(parents=True)
        self.bin.mkdir()
        for name, body in (("claude", CLAUDE_STUB), ("npx", NPX_STUB), ("git", GIT_STUB.replace("__REAL_GIT__", REAL_GIT))):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        (self.home / ".zshrc").write_text(ZSHRC)

    def run(self, *args: str, menu: str | None = None, state_out: bool = False) -> subprocess.CompletedProcess:
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "TMPDIR": str(self.home / ".stub"),
            "NET_TIMEOUT": "20",
            "LANG": "C",
        }
        if menu is not None:
            env["ACCC_TEST_MENU_IDS"] = menu
        if state_out:
            env["ACCC_TEST_MENU_STATE_OUT"] = str(self.home / ".stub" / "menu-state.txt")
        (self.home / ".stub" / "claude-calls.log").write_text("")
        result = subprocess.run(
            [BASH, str(INSTALL_SH), *args],
            env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600,
        )
        assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
        return result

    def menu_state(self) -> dict[str, int]:
        lines = (self.home / ".stub" / "menu-state.txt").read_text().splitlines()
        return {k: int(v) for k, v in (line.split("=", 1) for line in lines)}

    def calls(self) -> list[str]:
        return (self.home / ".stub" / "claude-calls.log").read_text().splitlines()

    def plugins(self) -> set[str]:
        path = self.claude / "plugins" / "installed_plugins.json"
        return set(json.loads(path.read_text())["plugins"]) if path.exists() else set()

    def marketplaces(self) -> set[str]:
        root = self.claude / "plugins" / "marketplaces"
        return {p.name for p in root.iterdir()} if root.exists() else set()

    def settings(self) -> dict:
        return json.loads((self.claude / "settings.json").read_text())

    def mcp(self) -> dict:
        path = self.home / ".claude.json"
        return json.loads(path.read_text()).get("mcpServers", {}) if path.exists() else {}

    def selection(self) -> dict:
        return json.loads((self.claude / "agent-config" / "selection.json").read_text())

    def seed_plugin(self, key: str) -> None:
        state = self.claude / "plugins" / "installed_plugins.json"
        data = json.loads(state.read_text()) if state.exists() else {"version": 2, "plugins": {}}
        data["plugins"][key] = [{"scope": "user"}]
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps(data))
        mdir = self.claude / "plugins" / "marketplaces" / key.split("@")[1] / ".claude-plugin"
        mdir.mkdir(parents=True, exist_ok=True)
        (mdir / "marketplace.json").write_text("{}")

    def seed_mcp(self, name: str, command: str, args: list[str]) -> None:
        path = self.home / ".claude.json"
        data = json.loads(path.read_text()) if path.exists() else {}
        data.setdefault("mcpServers", {})[name] = {"type": "stdio", "command": command, "args": args}
        path.write_text(json.dumps(data))

    def snapshot(self) -> dict[str, str]:
        out = {}
        for p in sorted(self.home.rglob("*")):
            if ".stub" in p.parts or p.is_dir():
                continue
            out[str(p.relative_to(self.home))] = p.read_bytes().hex() if p.stat().st_size < 200000 else str(p.stat().st_size)
        return out


# Interactive pick used for the first install. Deliberately not the defaults:
# codex instead of nothing, AI Research and DeepXiv on, some defaults off.
FIRST_PICK = [
    "claude-md", "settings", "rules-writing-style", "statusline", "lessons", "agents",
    "shell-wrapper", "co-author", "backend-glm", "backend-gpt",
    "rules-python", "rules-ts",
    "review-code-review", "review-codex",
    "plug-superpowers", "skill-mattpocock", "skill-update-config",
    "plug-context7",
    "skill-paper-reading", "ai-research", "deepxiv-cli",
    "mcp", "mcp-lark",
]

# Second interactive run: whole categories unchecked (Language Rules, Review,
# Academic Research, MCP Servers, Integrations, Model Backends) plus most of Core.
SECOND_PICK = ["claude-md", "settings", "plug-superpowers", "skill-update-config"]


@pytest.fixture(scope="module")
def env(tmp_path_factory: pytest.TempPathFactory) -> Env:
    e = Env(tmp_path_factory.mktemp("rerun"))
    # Foreign plugin + tombstoned plugin, and our own lark registration (the
    # installer cannot register lark without a tty, so seed what it would add).
    e.seed_plugin(FOREIGN_PLUGIN)
    e.seed_mcp("lark-mcp", "npx", ["-y", "@larksuiteoapi/lark-mcp", "mcp", "-a", "cli_x", "-s", "sec", "-t", "preset.light"])
    e.run(menu=",".join(FIRST_PICK))
    return e


def test_first_interactive_install(env: Env) -> None:
    c = env.claude
    assert (c / "rules" / "python").is_dir() and not (c / "rules" / "golang").exists()
    assert (c / "skills" / "paper-reading").is_dir() and not (c / "skills" / "cheatsheet-creator").exists()
    assert (c / "skills" / "deepxiv-cli").is_dir()
    assert (c / "skills" / "grilling").is_dir() and (c / ".mattpocock-skills").is_file()
    assert (c / "claude.zsh").is_file() and (c / "profiles" / "gpt.json").is_file()
    plugins = env.plugins()
    assert {"code-review@claude-plugins-official", "codex@openai-codex", "tokenization@ai-research-skills"} <= plugins
    assert FOREIGN_PLUGIN in plugins
    assert "playwright" in env.mcp() and "lark-mcp" in env.mcp()
    s = env.settings()
    assert "hooks/statusline.sh" in s["statusLine"]["command"]
    assert s["includeCoAuthoredBy"] is True
    owned = (c / "agent-config" / "script-owned.tsv").read_text()
    assert "skills/paper-reading\t" in owned and "rules/python\t" in owned


def test_rerun_menu_starts_from_detected_state(env: Env) -> None:
    before_plugins = env.plugins()
    env.run(menu="@initial", state_out=True)
    state = env.menu_state()
    checked = {k for k, v in state.items() if v == 1}
    # Everything installed by the first run is detected as checked...
    assert set(FIRST_PICK) <= checked, set(FIRST_PICK) - checked
    # ...and default-on items the first run left out are NOT re-checked: the
    # selection record remembers they were unchecked (and they are not installed).
    for item in ("rules-go", "skill-cheatsheet-creator", "plug-feature-dev", "backend-or", "skill-humanizer"):
        assert state[item] == 0, item
    # Submitting the detected state unchanged removes nothing.
    assert env.plugins() == before_plugins
    assert not any(call.startswith("plugin uninstall --scope user") for call in env.calls())
    assert not any(call.startswith(("mcp remove", "plugin marketplace remove")) for call in env.calls())


def test_rerun_deselect_removes_owned_items_with_backups(env: Env) -> None:
    c = env.claude
    # User edits to files the installer owns.
    py_rule = next((c / "rules" / "python").glob("*.md"))
    py_rule.write_text(py_rule.read_text() + "\nmy local tweak\n")
    (c / "skills" / "paper-reading" / "SKILL.md").write_text("my own paper reading\n")
    (c / "hooks" / "statusline.sh").write_text("#!/bin/bash\necho custom\n")
    (c / "skills" / "grilling" / "SKILL.md").write_text("edited grilling\n")
    (c / "lessons.md").write_text("# my lessons\n- keep me\n")
    # A same-name playwright server the user registered with another command.
    env.seed_mcp("playwright", "node", ["/opt/my-playwright/server.js"])

    result = env.run(menu=",".join(SECOND_PICK))
    out = result.stdout

    # Language rules / skills / DeepXiv / agent / mattpocock: gone.
    for rel in ("rules/python", "rules/typescript", "rules/writing-style.md", "skills/paper-reading",
                "skills/deepxiv-cli", "agents/search.md", "skills/grilling", "skills/teach",
                "hooks/statusline.sh", "claude.zsh", "system-prompt.txt", ".mattpocock-skills"):
        assert not (c / rel).exists(), rel
    assert (c / "skills" / "update-config").is_dir()
    # Modified copies were backed up first; unmodified ones were not.
    backups = list((c / "agent-config" / "backups").glob("*-deselect"))
    assert len(backups) == 1, backups
    b = backups[0]
    assert "my local tweak" in (b / "rules" / "python" / py_rule.name).read_text()
    assert (b / "skills" / "paper-reading" / "SKILL.md").read_text() == "my own paper reading\n"
    assert (b / "hooks" / "statusline.sh").read_text().endswith("echo custom\n")
    assert (b / "skills" / "grilling" / "SKILL.md").read_text() == "edited grilling\n"
    assert not (b / "rules" / "typescript").exists()
    assert not (b / "skills" / "deepxiv-cli").exists()
    assert "backed up to" in out
    # Settings: our statusLine and lessons hook dropped, co-author off; lessons.md kept.
    s = env.settings()
    assert "statusLine" not in s
    assert "LESSONS_FILE=" not in json.dumps(s.get("hooks", {}))
    assert s["includeCoAuthoredBy"] is False
    assert (c / "lessons.md").read_text() == "# my lessons\n- keep me\n"
    # Plugins: whole Review / Academic Research / Integrations categories removed, foreign kept.
    plugins = env.plugins()
    for key in ("code-review@claude-plugins-official", "codex@openai-codex",
                "tokenization@ai-research-skills", "context7@claude-plugins-official"):
        assert key not in plugins, key
    assert "superpowers@claude-plugins-official" in plugins
    assert FOREIGN_PLUGIN in plugins
    mkts = env.marketplaces()
    assert "openai-codex" not in mkts and "ai-research-skills" not in mkts
    assert "claude-plugins-official" in mkts and "my-market" in mkts
    # MCP: ours removed, the user's same-name server untouched with a warning.
    mcp = env.mcp()
    assert "lark-mcp" not in mcp
    assert mcp["playwright"]["command"] == "node"
    assert "was not registered by this installer" in out
    # Launcher: profiles kept, only the exact suggested rc line removed (backup kept).
    assert (c / "profiles" / "gpt.json").is_file() and (c / "profiles" / "glm.json").is_file()
    rc = (env.home / ".zshrc").read_text()
    assert "\nsource ~/.claude/claude.zsh\n" not in rc
    assert "[ -f ~/.claude/claude.zsh ] && source ~/.claude/claude.zsh" in rc
    assert "export KEEP_ME=1" in rc and "alias ll=" in rc
    assert (b / ".zshrc").read_text() == ZSHRC
    # selection.json reflects the removals and remembers what was unchecked.
    sel = env.selection()
    assert "paper-reading" not in sel["items"] and "codex-in-claude" not in sel["items"]
    assert "superpowers" in sel["items"]
    desel = set(sel["script_installer"]["deselected"])
    assert {"skill-paper-reading", "rules-python", "mcp-lark", "backend-gpt", "shell-wrapper"} <= desel


def test_rerun_after_deselect_keeps_unchecked_items_unchecked(env: Env) -> None:
    env.run(menu="@initial", state_out=True)
    state = env.menu_state()
    assert {k for k, v in state.items() if v == 1} == set(SECOND_PICK)


@pytest.mark.parametrize("args", [("--only", "plug-context7,skill-cheatsheet-creator"), ("--all",), ()])
def test_additive_runs_remove_nothing(env: Env, args: tuple[str, ...]) -> None:
    c = env.claude
    env.seed_plugin("claude-mem@thedotmack")          # tombstoned: always removed
    env.seed_plugin("fine-tuning@ai-research-skills")  # owned, not selected by default
    (c / "skills" / "update-config" / "SKILL.md").write_text("edited\n")
    rc_before = (env.home / ".zshrc").read_text()
    lessons_before = (c / "lessons.md").read_text()
    before = env.plugins()

    env.run(*args)  # no tty: `bash install.sh` with no args is the non-interactive default

    after = env.plugins()
    assert "claude-mem@thedotmack" not in after
    assert (before - {"claude-mem@thedotmack"}) <= after, (before - after)
    uninstalls = [call for call in env.calls() if call.startswith("plugin uninstall")]
    # Only tombstones, or the uninstall half of a selected plugin's reinstall.
    for call in uninstalls:
        key = call.split()[-1]
        assert key == "claude-mem@thedotmack" or key in after, call
    assert not any(call.startswith("mcp remove") for call in env.calls())
    assert not any(call.startswith("plugin marketplace remove") and "thedotmack" not in call for call in env.calls())
    assert (env.home / ".zshrc").read_text() == rc_before
    assert (c / "lessons.md").read_text() == lessons_before
    assert env.mcp()["playwright"]["command"] == "node"
    assert FOREIGN_PLUGIN in after
    s = env.settings()
    assert s["enabledPlugins"].get("fine-tuning@ai-research-skills") is not False
    if args == ("--all",):
        assert s["enabledPlugins"]["code-review@claude-plugins-official"] is True
    # Nothing the run did not select was deleted.
    assert (c / "skills" / "update-config").is_dir()
    assert not list((c / "agent-config" / "backups").glob("*-deselect"))[1:]


def test_dry_run_previews_every_removal_without_changes(tmp_path: Path) -> None:
    e = Env(tmp_path)
    e.seed_mcp("lark-mcp", "npx", ["-y", "@larksuiteoapi/lark-mcp", "mcp", "-a", "a", "-s", "b"])
    e.run(menu=",".join(FIRST_PICK))
    (e.claude / "skills" / "paper-reading" / "SKILL.md").write_text("mine\n")
    before = e.snapshot()
    out = e.run("--dry-run", menu="claude-md,settings").stdout
    assert e.snapshot() == before
    for needle in (
        "Would remove unchecked python rules",
        "Would remove unchecked rule writing-style.md",
        "Would back up (differs from the installed copy) and remove unchecked skill paper-reading",
        "Would remove unchecked DeepXiv skill deepxiv-cli",
        "Would remove unchecked agent search.md",
        "Would remove unchecked mattpocock skill: grilling",
        "Would remove unchecked MCP server: playwright",
        "Would remove unchecked MCP server: lark-mcp",
        "Would remove the statusLine that runs hooks/statusline.sh in settings.json",
        "Would remove the lessons SessionStart hook",
        "Would set includeCoAuthoredBy to false",
        "Would remove unchecked launcher (claude.zsh)",
        "Would back up ~/.zshrc and remove the line: source ~/.claude/claude.zsh",
        "Would uninstall: codex@openai-codex",
        "Would uninstall: tokenization@ai-research-skills",
        "Would remove marketplace (no remaining plugin needs it): openai-codex",
    ):
        assert needle in out, needle

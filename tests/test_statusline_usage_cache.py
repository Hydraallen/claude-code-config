from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
STATUSLINE = ROOT / "platforms" / "claude" / "templates" / "hooks" / "statusline.sh"
TOKEN = "test-token"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
DAY = 86400

STUB_CURL = """#!/bin/bash
echo call >> "$STUB_CURL_LOG"
cat > /dev/null
while [ $# -gt 0 ]; do
    [ "$1" = "-o" ] && out="$2"
    shift
done
cp "$STUB_RESPONSE" "$out"
printf 200
"""

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        shutil.which("bash") is None or shutil.which("jq") is None,
        reason="statusline.sh needs bash and jq",
    ),
]


def limit(
    seconds_to_reset: int,
    percentage: int,
    unit: int | None = None,
    number: int | None = None,
) -> dict:
    entry = {
        "type": "TOKENS_LIMIT",
        "percentage": percentage,
        "nextResetTime": (int(time.time()) + seconds_to_reset) * 1000,
    }
    if unit is not None:
        entry.update(unit=unit, number=number)
    return entry


FIVE_HOUR = (3, 5)
WEEKLY = (6, 1)


@dataclass(frozen=True)
class Harness:
    tmp: Path
    env: dict[str, str]
    cache: Path
    curl_log: Path
    response: Path

    def respond(self, *limits: dict) -> None:
        body = {"success": True, "data": {"limits": list(limits)}}
        self.response.write_text(json.dumps(body))

    def render(self) -> str:
        payload = json.dumps({"model": {"display_name": "GLM"}, "cwd": str(self.tmp)})
        done = subprocess.run(
            ["bash", str(STATUSLINE)],
            input=payload,
            capture_output=True,
            text=True,
            env=self.env,
            timeout=30,
            check=True,
        )
        return ANSI.sub("", done.stdout)

    def curl_calls(self) -> int:
        if not self.curl_log.exists():
            return 0
        return len(self.curl_log.read_text().splitlines())

    def wait_for_fetch(self) -> None:
        lock = self.cache.with_name(
            self.cache.name.replace("cache", "fetch").replace(".json", ".lock.d")
        )
        deadline = time.time() + 15
        while time.time() < deadline:
            if self.curl_calls() and not lock.exists():
                return
            time.sleep(0.05)
        pytest.fail("background fetch did not finish")

    def seed_cache(self, content: dict, age: int) -> None:
        self.cache.write_text(json.dumps(content))
        moment = time.time() - age
        os.utime(self.cache, (moment, moment))

    def seed_err(self, age: int) -> None:
        err = self.err_file()
        err.write_text("500\n")
        moment = time.time() - age
        os.utime(err, (moment, moment))

    def err_file(self) -> Path:
        return self.cache.with_name(self.cache.name + ".err")


@pytest.fixture
def harness(tmp_path: Path) -> Harness:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(STUB_CURL)
    curl.chmod(curl.stat().st_mode | stat.S_IEXEC)

    tmp = tmp_path / "tmp"
    tmp.mkdir()
    curl_log = tmp_path / "curl.log"
    response = tmp_path / "response.json"
    checksum = subprocess.run(
        ["cksum"], input=TOKEN, capture_output=True, text=True, check=True
    ).stdout.split()[0]

    env = {
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "HOME": str(tmp_path),
        "CLAUDE_CONFIG_DIR": str(tmp_path / "claude"),
        "TMPDIR": str(tmp),
        "TERM": "dumb",
        "COLUMNS": "200",
        "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
        "ANTHROPIC_AUTH_TOKEN": TOKEN,
        "STUB_CURL_LOG": str(curl_log),
        "STUB_RESPONSE": str(response),
    }
    return Harness(
        tmp=tmp_path,
        env=env,
        cache=tmp / f"claude-usage-cache-glm-{checksum}.json",
        curl_log=curl_log,
        response=response,
    )


def stale_five_hour_only() -> dict:
    return {
        "five_hour": {"utilization": 8, "resets_epoch": int(time.time()) + 3600}
    }


def test_fresh_cache_renders_without_fetching(harness: Harness) -> None:
    harness.seed_cache(stale_five_hour_only(), age=10)

    assert "glm 5h" in harness.render()
    time.sleep(0.3)
    assert harness.curl_calls() == 0


def test_future_mtime_cache_is_hidden_and_replaced(harness: Harness) -> None:
    harness.seed_cache(stale_five_hour_only(), age=-DAY)
    harness.respond(limit(3600, 9, *FIVE_HOUR), limit(2 * DAY, 52, *WEEKLY))

    first = harness.render()
    assert "glm 5h" not in first
    harness.wait_for_fetch()

    second = harness.render()
    assert "glm 5h" in second
    assert "9%" in second
    assert "glm 7d" in second
    assert "52%" in second


def test_future_mtime_err_does_not_suppress_fetch(harness: Harness) -> None:
    harness.seed_err(age=-DAY)
    harness.respond(limit(3600, 9, *FIVE_HOUR), limit(2 * DAY, 52, *WEEKLY))

    harness.render()
    harness.wait_for_fetch()

    assert "glm 7d" in harness.render()


def test_recent_err_still_suppresses_fetch(harness: Harness) -> None:
    harness.seed_err(age=10)
    harness.respond(limit(3600, 9, *FIVE_HOUR))

    harness.render()
    time.sleep(0.3)

    assert harness.curl_calls() == 0


@pytest.mark.parametrize(
    "five_tag, week_tag",
    [(FIVE_HOUR, WEEKLY), ((None, None), (None, None))],
    ids=["tagged", "untagged"],
)
def test_expired_five_hour_window_is_dropped(
    harness: Harness,
    five_tag: tuple[int | None, int | None],
    week_tag: tuple[int | None, int | None],
) -> None:
    harness.respond(limit(-60, 8, *five_tag), limit(2 * DAY, 52, *week_tag))

    harness.render()
    harness.wait_for_fetch()

    cached = json.loads(harness.cache.read_text())
    assert "five_hour" not in cached
    assert cached["seven_day"]["utilization"] == 52


def test_all_windows_expired_counts_as_failed_fetch(harness: Harness) -> None:
    harness.respond(limit(-60, 8, *FIVE_HOUR), limit(-60, 52, *WEEKLY))

    harness.render()
    harness.wait_for_fetch()

    assert not harness.cache.exists()
    assert harness.err_file().exists()

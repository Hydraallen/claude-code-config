#!/usr/bin/env python3
"""Check a selected stdio MCP initialize handshake without registering the server."""
import argparse
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time

USER_AGENT_FUNCTION = "() => navigator.userAgent"


class Session:
    def __init__(self, process, deadline):
        self.process = process
        self.deadline = deadline
        self.messages = queue.Queue()
        self.next_id = 1
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.messages.put(line)
        self.messages.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while time.monotonic() < self.deadline:
            try:
                line = self.messages.get(timeout=max(0.01, self.deadline - time.monotonic()))
            except queue.Empty:
                break
            if line is None:
                raise ValueError(f"Server exited before {method} completed")
            try:
                response = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(response, dict) and response.get("id") == request_id:
                if "error" in response:
                    raise ValueError(f"Server rejected {method}: {response['error']}")
                return response.get("result", {})
        raise ValueError(f"{method} did not complete within the timeout")


def tool_text(result):
    if not isinstance(result, dict) or result.get("isError"):
        raise ValueError(f"Browser tool failed: {json.dumps(result)[:500]}")
    return "\n".join(item.get("text", "") for item in result.get("content", []) if isinstance(item, dict))


def probe_browser(session):
    tool_text(session.request("tools/call", {"name": "browser_navigate", "arguments": {"url": "about:blank"}}))
    text = tool_text(session.request("tools/call", {"name": "browser_evaluate",
                                                    "arguments": {"function": USER_AGENT_FUNCTION}}))
    user_agent = next((line.strip().strip('"') for line in text.splitlines() if "Mozilla/" in line), "")
    try:
        session.request("tools/call", {"name": "browser_close", "arguments": {}})
    except ValueError:
        pass
    if not user_agent:
        raise ValueError("browser_evaluate did not return a user agent")
    return user_agent


def check(command, timeout, browser=False):
    options = {"start_new_session": True} if os.name != "nt" else {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1, **options)
    session = Session(process, time.monotonic() + timeout)
    try:
        result = session.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                "clientInfo": {"name": "agent-config-check", "version": "1.0"}})
        if not isinstance(result, dict) or not result.get("serverInfo") or not result.get("protocolVersion"):
            raise ValueError("Server rejected initialize or returned an incomplete response")
        session.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        report = {"status": "initialize-passed", "server": result["serverInfo"]}
        if browser:
            report["user_agent"] = probe_browser(session)
            report["status"] = "browser-passed"
        return report
    finally:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        else:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                process.kill()
            else:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=5)
        process.stdin.close()
        process.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--browser", action="store_true",
                        help="Playwright MCP only: open about:blank and report the browser user agent")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("Pass the server command after --")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        print(json.dumps(check(command, args.timeout, args.browser)))
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)

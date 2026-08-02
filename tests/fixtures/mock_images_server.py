#!/usr/bin/env python3
"""Loopback-only OpenAI Images mock for image-gen wrapper tests.

Test fixture (not upstream Skill code). Stdlib-only, binds to 127.0.0.1,
never records secrets. Implements:

  GET  /healthz               -> 200 {}                    (liveness only)
  GET  /v1/models             -> 200 list (auth optional)  (capability probe)
  POST /v1/images/generations -> 200 {"data":[{"b64_json":...}]}
  POST /v1/images/edits       -> 200 {"data":[{"b64_json":...}]}  (multipart)
  GET  /records               -> 200 non-secret observation dump

Capability: /v1/models includes "gpt-image-2" unless --no-oauth is set (which
models an OAuth-inactive state). When --expect-key is set, /v1/models and the
image routes require `Authorization: Bearer <key>` or return 401.

Non-secret observations (route counts, model seen, multipart field name) are
written to --records-file after each request so tests can assert without an
extra HTTP round-trip and without exposing the key.
"""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_PNG_B64 = b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockImages/1.0"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _auth_ok(self):
        if not self.server.expect_key:
            return True
        got = self.headers.get("Authorization", "")
        return got == "Bearer " + self.server.expect_key

    def _record(self, **kw):
        for k, v in kw.items():
            self.server.records[k] = v
        self.server.flush_records()

    def _check_model(self, raw):
        ctype = (self.headers.get("Content-Type", "") or "").lower()
        model = None
        field = None
        if ctype.startswith("application/json"):
            try:
                obj = json.loads(raw.decode("utf-8") or "{}")
                model = obj.get("model")
            except Exception:
                return None, None, False
        else:
            try:
                text = raw.decode("utf-8", errors="replace")
                mi = text.find('name="model"')
                if mi >= 0:
                    seg = text[mi + len('name="model"'):]
                    start = seg.find("\r\n\r\n")
                    end = seg.find("\r\n--")
                    if start >= 0 and end > start:
                        model = seg[start + 4:end].strip()
                ii = text.find('name="image')
                if ii >= 0:
                    seg = text[ii + len('name="'):]
                    end = seg.find('"')
                    field = seg[:end] if end > 0 else None
            except Exception:
                model, field = None, None
        return model, field, model == "gpt-image-2"

    def do_GET(self):
        if self.path == "/healthz":
            self._record(health=self.server.records.get("health", 0) + 1)
            self._send(200, {"status": "ok"})
        elif self.path == "/v1/models":
            if not self._auth_ok():
                self._record(models_401=self.server.records.get("models_401", 0) + 1)
                self._send(401, {"error": "unauthorized"})
                return
            mode = self.server.models_mode
            self._record(models=self.server.records.get("models", 0) + 1, models_mode=mode)
            if mode == "malformed":
                body = b'not-json{"data":'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if mode == "nonarray":
                self._send(200, {"object": "list", "data": {"id": "gpt-image-2"}})
                return
            if mode == "substring":
                data = [{"id": "not-gpt-image-2"}]
            elif mode == "wrongfield":
                data = [{"id": "gpt-4o", "object": "gpt-image-2"}]
            elif mode == "no-oauth":
                data = [{"id": "gpt-3.5-turbo"}]
            else:
                data = [{"id": "gpt-image-2"}, {"id": "gpt-4o"}]
            self._send(200, {"object": "list", "data": data})
        elif self.path == "/records":
            self._send(200, self.server.records)
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._auth_ok():
            self._send(401, {"error": "unauthorized"})
            return
        raw = self._read_body()
        if self.path == "/v1/images/generations":
            model, _field, ok = self._check_model(raw)
            self._record(generations=self.server.records.get("generations", 0) + 1,
                         gen_model=model)
            if not ok:
                self._send(400, {"error": "model must be gpt-image-2"})
                return
            self._send(200, {"data": [{"b64_json": _PNG_B64.decode("ascii")}]})
        elif self.path == "/v1/images/edits":
            model, field, ok = self._check_model(raw)
            ctype = (self.headers.get("Content-Type", "") or "").lower()
            self._record(edits=self.server.records.get("edits", 0) + 1,
                         edit_model=model, edit_field=field,
                         edit_multipart=ctype.startswith("multipart/"))
            if not ok or field != "image[]":
                self._send(400, {"error": "edits require model gpt-image-2 and image[]"})
                return
            self._send(200, {"data": [{"b64_json": _PNG_B64.decode("ascii")}]})
        else:
            self._send(404, {"error": "not found"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file", default="")
    ap.add_argument("--records-file", default="")
    ap.add_argument("--expect-key", default="")
    ap.add_argument("--models-mode", default="normal",
                    help="normal|no-oauth|substring|wrongfield|malformed|nonarray")
    args = ap.parse_args()
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), _Handler)
    httpd.records = {}
    httpd.expect_key = args.expect_key
    httpd.models_mode = args.models_mode
    lock = threading.Lock()

    def flush():
        if not args.records_file:
            return
        with lock:
            try:
                with open(args.records_file, "w") as fh:
                    json.dump(httpd.records, fh)
            except Exception:
                pass
    httpd.flush_records = flush
    actual = httpd.server_address[1]
    if args.port_file:
        with open(args.port_file, "w") as fh:
            fh.write(str(actual))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()

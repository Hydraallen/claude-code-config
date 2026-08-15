#!/usr/bin/env python3
"""
Repository-owned image generation wrapper for the network-installed
sinedied/agent-skills:image-gen Skill.

Calls OpenRouter's image endpoint directly (POST /api/v1/images). The upstream
image_gen.py is NOT invoked: its /v1/images/generations and /v1/images/edits
routes do not exist on OpenRouter, and image editing there is expressed as
reference images on the same generation endpoint.

Design constraints:
  - Python 3.8+ standard library only, no third-party dependencies.
  - The API key is never accepted in argv, printed, or logged. It is read only
    from the OpenRouter profile and used only as an Authorization header.
  - Neither is the API base: --base-url is rejected, and IMAGE_GEN_BASE_URL is
    restricted to openrouter.ai (https) or a loopback host, so the key cannot
    be redirected to an attacker-controlled endpoint.
  - Fail-closed: the target model must be listed by GET /api/v1/images/models
    before any generation request is sent. There is no bypass switch.

Environment:
  IMAGE_GEN_PROFILE    profile JSON path (default ~/.claude/profiles/or.json)
  IMAGE_GEN_BASE_URL   API base (default https://openrouter.ai/api/v1); only
                       openrouter.ai over https or a loopback host is accepted
  IMAGE_GEN_MODEL      default model (default openai/gpt-image-2)
  IMAGE_GEN_TIMEOUT    per-request timeout in seconds (default 300)

Exit codes:
  0 success | 1 API or I/O failure | 2 argument usage error
  3 no usable API key | 4 model availability precheck failed
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, NoReturn, Optional

DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
BASE_URL_HOST = "openrouter.ai"
BASE_URL_LOOPBACK_HOSTS = ("127.0.0.1", "::1", "localhost")
DEFAULT_MODEL = "openai/gpt-image-2"
DEFAULT_PROFILE = Path.home() / ".claude" / "profiles" / "or.json"
DEFAULT_TIMEOUT = 300.0
MAX_INPUT_REFERENCES = 16

EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_CREDENTIALS = 3
EXIT_PRECHECK = 4

KEY_CHARSET = re.compile(r"^[A-Za-z0-9._~-]+$")
SIZE_PATTERN = re.compile(r"^(auto|512|1K|2K|4K|[0-9]{2,5}x[0-9]{2,5})$")

MEDIA_TYPE_EXTENSIONS = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/webp": "webp",
    "image/svg+xml": "svg",
}


def _die(message: str, code: int = EXIT_ERROR) -> NoReturn:
    print("image-gen: " + message, file=sys.stderr)
    raise SystemExit(code)


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

def _usable_key(value: str) -> bool:
    return bool(value) and not value.startswith("YOUR_") and bool(KEY_CHARSET.match(value))


def _profile_path() -> Path:
    override = os.environ.get("IMAGE_GEN_PROFILE")
    return Path(override) if override else DEFAULT_PROFILE


def _profile_token(path: Path) -> Optional[str]:
    try:
        with path.open(encoding="utf-8") as handle:
            profile = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(profile, dict):
        return None
    env = profile.get("env")
    if not isinstance(env, dict):
        return None
    token = env.get("ANTHROPIC_AUTH_TOKEN")
    return token if isinstance(token, str) else None


def _resolve_api_key() -> str:
    path = _profile_path()
    token = _profile_token(path)
    if token is None:
        _die(
            "no OpenRouter API key found. Install the OpenRouter backend "
            "(./install.sh, tick \"OpenRouter\") and put your key from "
            "https://openrouter.ai/keys into {0} as .env.ANTHROPIC_AUTH_TOKEN"
            .format(path),
            EXIT_CREDENTIALS,
        )
    token = token.strip()
    if not _usable_key(token):
        _die(
            "{0} does not hold a usable OpenRouter key. Replace "
            ".env.ANTHROPIC_AUTH_TOKEN with your key from "
            "https://openrouter.ai/keys".format(path),
            EXIT_CREDENTIALS,
        )
    return token


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def _timeout() -> float:
    raw = os.environ.get("IMAGE_GEN_TIMEOUT", "")
    if not raw:
        return DEFAULT_TIMEOUT
    try:
        value = float(raw)
    except ValueError:
        _die("IMAGE_GEN_TIMEOUT is not a number: {0!r}".format(raw), EXIT_USAGE)
    if value <= 0:
        _die("IMAGE_GEN_TIMEOUT must be positive", EXIT_USAGE)
    return value


def _send(request: urllib.request.Request) -> Dict[str, Any]:
    try:
        with urllib.request.urlopen(request, timeout=_timeout()) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", "replace")[:2000]
        except OSError:
            detail = "<response body unreadable>"
        _die("HTTP {0} from {1}: {2}".format(exc.code, request.full_url, detail))
    except (urllib.error.URLError, OSError) as exc:
        _die("request to {0} failed: {1}".format(request.full_url, exc))
    except ValueError:
        _die("{0} returned a body that is not valid JSON".format(request.full_url))
    if not isinstance(payload, dict):
        _die("{0} returned JSON that is not an object".format(request.full_url))
    return payload


def _get_json(url: str, key: str) -> Dict[str, Any]:
    request = urllib.request.Request(
        url, method="GET", headers={"Authorization": "Bearer " + key}
    )
    return _send(request)


def _post_json(url: str, key: str, body: Dict[str, Any]) -> Dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
    )
    return _send(request)


def _fetch_bytes(url: str) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        _die(
            "refusing to fetch a returned image over {0} scheme"
            .format(parsed.scheme or "no")
        )
    try:
        with urllib.request.urlopen(url, timeout=_timeout()) as response:
            return response.read()
    except (urllib.error.URLError, OSError) as exc:
        _die("failed to download returned image: {0}".format(exc))


# ---------------------------------------------------------------------------
# Fail-closed model availability precheck
# ---------------------------------------------------------------------------

def _require_model(base_url: str, key: str, model: str) -> None:
    payload = _get_json(base_url + "/images/models", key)
    entries = payload.get("data")
    if not isinstance(entries, list):
        _die(
            "{0}/images/models did not return a model list; refusing to "
            "generate against an unverified endpoint".format(base_url),
            EXIT_PRECHECK,
        )
    for entry in entries:
        if isinstance(entry, dict) and entry.get("id") == model:
            return
    available = sorted(
        str(entry.get("id"))
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    )
    hint = ", ".join(available[:8]) or "<none>"
    _die(
        "model {0!r} is not offered by {1}/images/models. Pick one with "
        "--model (first few available: {2})".format(model, base_url, hint),
        EXIT_PRECHECK,
    )


# ---------------------------------------------------------------------------
# Input references (image-to-image)
# ---------------------------------------------------------------------------

def _encode_reference(reference: str) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(reference)
    if parsed.scheme in ("http", "https"):
        url = reference
    else:
        path = Path(reference)
        if not path.is_file():
            _die("input image not found: {0}".format(reference), EXIT_USAGE)
        media_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        try:
            encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        except OSError as exc:
            _die("cannot read input image {0}: {1}".format(reference, exc))
        url = "data:{0};base64,{1}".format(media_type, encoded)
    return {"type": "image_url", "image_url": {"url": url}}


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def _unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    counter = 2
    while True:
        candidate = path.parent / "{0}_{1}{2}".format(path.stem, counter, path.suffix)
        if not candidate.exists():
            return candidate
        counter += 1


def _extension_for(media_type: Any, fallback: Optional[str]) -> str:
    if fallback:
        return fallback
    if isinstance(media_type, str):
        return MEDIA_TYPE_EXTENSIONS.get(media_type, "png")
    return "png"


def _save_images(items: List[Any], output: str, fmt: Optional[str]) -> List[str]:
    target_root = Path(output)
    multiple = len(items) > 1
    file_mode = bool(target_root.suffix) and not output.endswith("/")

    try:
        if file_mode:
            target_root.parent.mkdir(parents=True, exist_ok=True)
        else:
            target_root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        _die("cannot create output location {0}: {1}".format(output, exc))

    saved: List[str] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        encoded = item.get("b64_json")
        url = item.get("url")
        if isinstance(encoded, str) and encoded:
            try:
                data = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError):
                _die(
                    "image {0} in the response is not valid base64"
                    .format(index + 1)
                )
        elif isinstance(url, str) and url:
            data = _fetch_bytes(url)
        else:
            continue

        if file_mode:
            if multiple:
                stem = "{0}_{1}".format(target_root.stem, index + 1)
                target = _unique_path(
                    target_root.parent / (stem + target_root.suffix)
                )
            else:
                target = _unique_path(target_root)
        else:
            extension = _extension_for(item.get("media_type"), fmt)
            target = _unique_path(
                target_root / "image_{0}.{1}".format(index + 1, extension)
            )

        try:
            target.write_bytes(data)
        except OSError as exc:
            _die("cannot write {0}: {1}".format(target, exc))
        saved.append(str(target))

        revised = item.get("revised_prompt")
        if isinstance(revised, str) and revised:
            print(
                "[Image {0}] Revised prompt: {1}".format(index + 1, revised),
                file=sys.stderr,
            )

    return saved


# ---------------------------------------------------------------------------
# Request body
# ---------------------------------------------------------------------------

def _resolve_base_url() -> str:
    raw = os.environ.get("IMAGE_GEN_BASE_URL") or DEFAULT_BASE_URL
    parsed = urllib.parse.urlparse(raw)
    host = (parsed.hostname or "").lower()
    if host in BASE_URL_LOOPBACK_HOSTS:
        if parsed.scheme not in ("http", "https"):
            _die(
                "IMAGE_GEN_BASE_URL must use http or https, got {0!r}"
                .format(parsed.scheme or ""),
                EXIT_USAGE,
            )
    elif host == BASE_URL_HOST or host.endswith("." + BASE_URL_HOST):
        if parsed.scheme != "https":
            _die(
                "IMAGE_GEN_BASE_URL must use https for {0}, got {1!r}"
                .format(host, parsed.scheme or ""),
                EXIT_USAGE,
            )
    else:
        _die(
            "IMAGE_GEN_BASE_URL host {0!r} is not allowed: the API key may only "
            "be sent to https://{1} (or a subdomain of it), or to a loopback "
            "host ({2}) for local testing"
            .format(host or raw, BASE_URL_HOST, ", ".join(BASE_URL_LOOPBACK_HOSTS)),
            EXIT_USAGE,
        )
    return raw.rstrip("/")


def _resolve_model(args: argparse.Namespace) -> str:
    return args.model or os.environ.get("IMAGE_GEN_MODEL") or DEFAULT_MODEL


def _build_body(
    args: argparse.Namespace, model: str, references: List[Dict[str, Any]]
) -> Dict[str, Any]:
    body: Dict[str, Any] = {"model": model, "prompt": args.prompt}
    if args.n and args.n != 1:
        body["n"] = args.n
    if args.size:
        body["size"] = args.size
    if args.aspect_ratio:
        body["aspect_ratio"] = args.aspect_ratio
    if args.resolution:
        body["resolution"] = args.resolution
    if args.quality:
        body["quality"] = args.quality
    if args.background:
        body["background"] = args.background
    if args.output_format:
        body["output_format"] = args.output_format
    if args.output_compression is not None:
        body["output_compression"] = args.output_compression
    if args.seed is not None:
        body["seed"] = args.seed
    if references:
        body["input_references"] = references
    return body


def _run(args: argparse.Namespace, references: List[Dict[str, Any]]) -> None:
    if args.api_key:
        _die(
            "--api-key is not accepted: the key must never appear in argv. "
            "Store it in {0} as .env.ANTHROPIC_AUTH_TOKEN instead"
            .format(_profile_path()),
            EXIT_USAGE,
        )
    if args.base_url:
        _die(
            "--base-url is not accepted: the API base must never come from "
            "argv, because it decides which host receives the key. Set "
            "IMAGE_GEN_BASE_URL in the environment instead",
            EXIT_USAGE,
        )
    if args.n is not None and not 1 <= args.n <= 10:
        _die("--n must be between 1 and 10", EXIT_USAGE)
    if args.size and not SIZE_PATTERN.match(args.size):
        _die(
            "--size {0!r} is not a tier (512/1K/2K/4K/auto) or a WxH pixel value"
            .format(args.size),
            EXIT_USAGE,
        )
    if args.output_compression is not None and not 0 <= args.output_compression <= 100:
        _die("--output-compression must be between 0 and 100", EXIT_USAGE)

    base_url = _resolve_base_url()
    key = _resolve_api_key()
    model = _resolve_model(args)

    _require_model(base_url, key, model)

    payload = _post_json(
        base_url + "/images", key, _build_body(args, model, references)
    )
    items = payload.get("data")
    if not isinstance(items, list) or not items:
        _die("no images returned by the API")

    saved = _save_images(items, args.output, args.output_format)
    if not saved:
        _die("the API response carried no decodable image data")
    for path in saved:
        print(path)


def cmd_generate(args: argparse.Namespace) -> None:
    if args.moderation:
        print(
            "image-gen: --moderation has no OpenRouter equivalent and is ignored",
            file=sys.stderr,
        )
    _run(args, [])


def cmd_edit(args: argparse.Namespace) -> None:
    if args.mask:
        _die(
            "--mask (inpainting) has no OpenRouter equivalent: POST "
            "/api/v1/images accepts reference images but no mask. Describe the "
            "region to change in the prompt instead",
            EXIT_USAGE,
        )
    if len(args.image) > MAX_INPUT_REFERENCES:
        _die(
            "at most {0} input images are accepted".format(MAX_INPUT_REFERENCES),
            EXIT_USAGE,
        )
    _run(args, [_encode_reference(item) for item in args.image])


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="image-gen-openrouter",
        description="Generate or edit images via the OpenRouter image API.",
    )

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--api-key", help=argparse.SUPPRESS)
    common.add_argument("--base-url", help=argparse.SUPPRESS)
    common.add_argument(
        "--model", "-m", help="Model id (default: {0}).".format(DEFAULT_MODEL)
    )
    common.add_argument(
        "--n", type=int, default=1, help="Number of images to generate (1-10)."
    )
    common.add_argument("--size", "-s", help="Size tier (512/1K/2K/4K) or WxH pixels.")
    common.add_argument("--aspect-ratio", help="Aspect ratio, e.g. 1:1, 16:9, 4:3.")
    common.add_argument(
        "--resolution", choices=["512", "1K", "2K", "4K"], help="Resolution tier."
    )
    common.add_argument(
        "--quality", "-q", choices=["auto", "low", "medium", "high"],
        help="Image quality (default: provider default).",
    )
    common.add_argument(
        "--background", choices=["auto", "transparent", "opaque"],
        help="Background mode.",
    )
    common.add_argument(
        "--output-format", "-f", choices=["png", "jpeg", "webp", "svg"],
        help="Output image format.",
    )
    common.add_argument(
        "--output-compression", type=int, metavar="0-100",
        help="Compression level for jpeg/webp.",
    )
    common.add_argument("--seed", type=int, help="Seed for deterministic generation.")
    common.add_argument(
        "--output", "-o", default=".",
        help="Output file path or directory (default: current dir). With a file "
             "path, intermediate directories are created; with --n >1 a _N suffix "
             "is appended. Existing files are never overwritten.",
    )

    sub = parser.add_subparsers(dest="command")
    sub.required = True

    generate = sub.add_parser(
        "generate", aliases=["gen"], parents=[common],
        help="Generate image(s) from a text prompt.",
    )
    generate.add_argument("prompt", help="Text prompt describing the desired image.")
    generate.add_argument("--moderation", choices=["auto", "low"], help=argparse.SUPPRESS)
    generate.set_defaults(func=cmd_generate)

    edit = sub.add_parser(
        "edit", parents=[common],
        help="Generate from a prompt plus reference image(s).",
    )
    edit.add_argument("prompt", help="Text description of the desired result.")
    edit.add_argument(
        "--image", "-i", action="append", required=True,
        help="Reference image: local path or http(s) URL (repeatable, up to 16).",
    )
    edit.add_argument("--mask", help=argparse.SUPPRESS)
    edit.set_defaults(func=cmd_edit)

    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

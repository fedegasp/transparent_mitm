#!/usr/bin/env python3
"""
Mock dashboard
==============
Web UI to manage the mocks served by the mitmproxy addon
``~/.mitmproxy/scripts/mocks.py``. It runs as a separate process in the
mitmproxy container, started by ``entrypoint.sh``, and is reached from the Mac
at http://mitmproxy.test:8082 (``./mitm mock``, or ``M`` in the console).

Plain HTTP on purpose: see HISTORY, item 19. TLS with a certificate issued by
mitmproxy's own CA was tried and reverted — Digital Guardian re-signs the
browser's connections, so the browser never sees that certificate.

The two processes share the ``/mocks`` volume (``./mocks`` on the Mac), and
every file has a single writer.

    dashboard  ──writes──▶  enabled, mocks.json, files/  ──read──▶  addon
    addon      ──writes──▶  hits.json                    ──read──▶  dashboard

A new mock can also be copied from a real request. The flows live in
mitmproxy's memory, so the dashboard asks the addon for them by writing
``ask/<token>.req`` and waiting for the ``ask/<token>.res`` it writes back
(``/api/history``); the addon polls that directory.

``enabled`` is an empty file whose mere existence means "mocks active". It is
**removed at startup**: after every container start the mocks are off until the
switch in the UI is turned on. The container intercepts the traffic of the
whole LAN, and a mock left on would be hard to diagnose.

Access is restricted to the container network (``MITM_VM_NET``, i.e. the Mac
through vmnet): LAN clients can reach the container, and get a 403.

Environment:
    MITM_VM_NET   container network (e.g. 192.168.64.3/24). Empty: no
                  restriction (only for running it by hand during development).
    MOCKS_DIR     data directory, default /mocks
    MOCK_UI_PORT  listen port, default 8082
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import mimetypes
import os
import re
import time
import uuid
from pathlib import Path
from typing import Any

import tornado.web

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MOCKS_DIR = Path(os.environ.get("MOCKS_DIR", "/mocks"))
FILES_DIR = MOCKS_DIR / "files"
MOCKS_FILE = MOCKS_DIR / "mocks.json"
HITS_FILE = MOCKS_DIR / "hits.json"
ENABLED_FILE = MOCKS_DIR / "enabled"
ASK_DIR = MOCKS_DIR / "ask"

# The addon polls ASK_DIR every 0.3s: a couple of seconds are enough, unless
# mitmproxy is restarting (console: q) or the addon failed to load
ASK_TIMEOUT = 4.0
ASK_POLL = 0.05

STATIC_DIR = Path(__file__).resolve().parent
PORT = int(os.environ.get("MOCK_UI_PORT", "8082"))

METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

# Status codes that must not carry a body (RFC 9110 §6.4.1)
NO_BODY_STATUS = {204, 304}


def _allowed_network() -> ipaddress.IPv4Network | None:
    """Network allowed to reach the dashboard, from MITM_VM_NET."""
    spec = os.environ.get("MITM_VM_NET", "").strip()
    if not spec:
        return None
    try:
        return ipaddress.ip_network(spec, strict=False)
    except ValueError:
        print(f"mockui: invalid MITM_VM_NET '{spec}', access not restricted")
        return None


ALLOWED_NETWORK = _allowed_network()


# ---------------------------------------------------------------------------
# Store: mocks.json, uploaded files, enabled switch
# ---------------------------------------------------------------------------

def _write_atomic(path: Path, data: bytes) -> None:
    """Write through a temporary file + rename: the addon never reads a
    half-written file."""
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


async def ask_addon(what: str, **fields: Any) -> dict[str, Any]:
    """Ask the mitmproxy addon something only it can see: the flow history.

    Request and answer are two files, each with a single writer, as everything
    else here. The token keeps the answers of several browsers apart.
    """
    token = uuid.uuid4().hex
    ASK_DIR.mkdir(parents=True, exist_ok=True)
    request = ASK_DIR / f"{token}.req"
    answer = ASK_DIR / f"{token}.res"
    _write_atomic(request, json.dumps({"what": what, **fields}).encode())
    try:
        deadline = time.monotonic() + ASK_TIMEOUT
        while time.monotonic() < deadline:
            await asyncio.sleep(ASK_POLL)
            if not answer.exists():
                continue
            try:
                data = json.loads(answer.read_text())
            except (OSError, ValueError):
                raise tornado.web.HTTPError(502, reason="malformed answer from mitmproxy")
            if not isinstance(data, dict):
                raise tornado.web.HTTPError(502, reason="malformed answer from mitmproxy")
            if data.get("error"):
                raise tornado.web.HTTPError(502, reason=_reason(data["error"]))
            return data
        raise tornado.web.HTTPError(
            504, reason="mitmproxy is not answering: is it running?"
        )
    finally:
        request.unlink(missing_ok=True)
        answer.unlink(missing_ok=True)


def _reason(message: str) -> str:
    """HTTP reason phrase: one line, and short — the UI shows it as it is."""
    return re.sub(r"[^\x20-\x7e]", " ", str(message))[:120] or "error"


def load_mocks() -> list[dict[str, Any]]:
    try:
        data = json.loads(MOCKS_FILE.read_text())
    except (OSError, ValueError):
        return []
    mocks = data.get("mocks") if isinstance(data, dict) else data
    return mocks if isinstance(mocks, list) else []


def save_mocks(mocks: list[dict[str, Any]]) -> None:
    _write_atomic(MOCKS_FILE, json.dumps({"mocks": mocks}, indent=2).encode())


def load_hits() -> dict[str, Any]:
    try:
        hits = json.loads(HITS_FILE.read_text())
    except (OSError, ValueError):
        return {}
    return hits if isinstance(hits, dict) else {}


def is_enabled() -> bool:
    return ENABLED_FILE.exists()


def set_enabled(value: bool) -> None:
    if value:
        ENABLED_FILE.touch()
    else:
        ENABLED_FILE.unlink(missing_ok=True)


def find(mocks: list[dict[str, Any]], mock_id: str) -> int:
    for i, mock in enumerate(mocks):
        if mock.get("id") == mock_id:
            return i
    raise tornado.web.HTTPError(404, "mock not found")


# ---------------------------------------------------------------------------
# Validation: everything coming from the browser is rebuilt field by field,
# never stored as it arrives.
# ---------------------------------------------------------------------------

def _pairs(value: Any) -> list[dict[str, str]]:
    out = []
    if isinstance(value, list):
        for item in value:
            if isinstance(item, dict) and str(item.get("key", "")).strip():
                out.append(
                    {"key": str(item["key"]).strip(), "value": str(item.get("value", ""))}
                )
    return out


def clean_mock(data: Any, previous: dict[str, Any] | None = None) -> dict[str, Any]:
    """Build a valid mock from the JSON sent by the browser.

    ``body_file``/``body_filename`` are never taken from the request: they are
    only set by the upload route, and preserved from ``previous``.
    """
    if not isinstance(data, dict):
        raise tornado.web.HTTPError(400, "a JSON object is expected")

    previous = previous or {}

    try:
        status = int(data.get("status", 200))
    except (TypeError, ValueError):
        raise tornado.web.HTTPError(400, "invalid status code")
    if not 100 <= status <= 599:
        raise tornado.web.HTTPError(400, "status code outside 100-599")

    methods = [m for m in METHODS if m in (data.get("methods") or [])]
    body_mode = "file" if data.get("body_mode") == "file" else "text"

    return {
        "id": previous.get("id") or uuid.uuid4().hex[:12],
        "name": str(data.get("name", "")).strip() or "mock",
        # The form has no switch (it is on the card): when "enabled" is
        # missing, keep what is stored instead of turning the mock back on
        "enabled": bool(data["enabled"]) if "enabled" in data else previous.get("enabled", True),
        "methods": methods,
        "host": str(data.get("host", "")).strip().lower(),
        "path": str(data.get("path", "")).strip(),
        "query": _pairs(data.get("query")),
        "status": status,
        "content_type": str(data.get("content_type", "")).strip(),
        "headers": _pairs(data.get("headers")),
        "body_mode": body_mode,
        "body": str(data.get("body", "")),
        "body_file": previous.get("body_file", ""),
        "body_filename": previous.get("body_filename", ""),
    }


def _safe_filename(name: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(name)).lstrip(".")
    return name[:80] or "body"


def body_path(mock: dict[str, Any]) -> Path | None:
    """Absolute path of the uploaded file, or None if there is none.

    The path is resolved and checked against files/: mocks.json is editable by
    hand from the Mac, so body_file is treated as untrusted input.
    """
    rel = mock.get("body_file")
    if not rel:
        return None
    path = (MOCKS_DIR / rel).resolve()
    return path if path.is_relative_to(FILES_DIR.resolve()) else None


def remove_body_file(mock: dict[str, Any]) -> None:
    path = body_path(mock)
    if path:
        path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

class Access:
    """Allow-list on the container network, shared by every handler."""

    def prepare(self) -> None:  # type: ignore[override]
        if ALLOWED_NETWORK is None:
            return
        try:
            remote = ipaddress.ip_address(self.request.remote_ip)  # type: ignore[attr-defined]
        except ValueError:
            raise tornado.web.HTTPError(403)
        if remote not in ALLOWED_NETWORK:
            raise tornado.web.HTTPError(403, "the dashboard is only reachable from the Mac")


class ApiHandler(Access, tornado.web.RequestHandler):
    def json_body(self) -> Any:
        try:
            return json.loads(self.request.body or b"{}")
        except ValueError:
            raise tornado.web.HTTPError(400, "malformed JSON")

    def write_state(self, mocks: list[dict[str, Any]] | None = None) -> None:
        self.write(
            {
                "enabled": is_enabled(),
                "mocks": load_mocks() if mocks is None else mocks,
                "hits": load_hits(),
                "methods": METHODS,
                "no_body_status": sorted(NO_BODY_STATUS),
            }
        )


class MocksHandler(ApiHandler):
    def get(self) -> None:
        self.write_state()

    def post(self) -> None:
        mocks = load_mocks()
        mocks.append(clean_mock(self.json_body()))
        save_mocks(mocks)
        self.write_state(mocks)


class MockHandler(ApiHandler):
    def put(self, mock_id: str) -> None:
        mocks = load_mocks()
        i = find(mocks, mock_id)
        updated = clean_mock(self.json_body(), previous=mocks[i])
        if updated["body_mode"] == "text" and mocks[i].get("body_file"):
            # Going back to the text body: the uploaded file is no longer
            # referenced by anything, remove it
            remove_body_file(mocks[i])
            updated["body_file"] = ""
            updated["body_filename"] = ""
        mocks[i] = updated
        save_mocks(mocks)
        self.write_state(mocks)

    def delete(self, mock_id: str) -> None:
        mocks = load_mocks()
        remove_body_file(mocks.pop(find(mocks, mock_id)))
        save_mocks(mocks)
        self.write_state(mocks)


class MoveHandler(ApiHandler):
    def post(self, mock_id: str) -> None:
        mocks = load_mocks()
        i = find(mocks, mock_id)
        j = i - 1 if self.json_body().get("direction") == "up" else i + 1
        if 0 <= j < len(mocks):
            mocks[i], mocks[j] = mocks[j], mocks[i]
            save_mocks(mocks)
        self.write_state(mocks)


class BodyHandler(ApiHandler):
    """Upload (and download) of the response content as a file."""

    def post(self, mock_id: str) -> None:
        files = self.request.files.get("file") or []
        if not files:
            raise tornado.web.HTTPError(400, "no file received")
        upload = files[0]

        mocks = load_mocks()
        i = find(mocks, mock_id)
        remove_body_file(mocks[i])

        filename = _safe_filename(upload["filename"])
        FILES_DIR.mkdir(parents=True, exist_ok=True)
        (FILES_DIR / f"{mock_id}-{filename}").write_bytes(upload["body"])

        mocks[i]["body_file"] = f"files/{mock_id}-{filename}"
        mocks[i]["body_filename"] = filename
        mocks[i]["body_mode"] = "file"
        if not mocks[i].get("content_type"):
            guessed, _ = mimetypes.guess_type(filename)
            mocks[i]["content_type"] = guessed or "application/octet-stream"
        save_mocks(mocks)
        self.write_state(mocks)

    def get(self, mock_id: str) -> None:
        mocks = load_mocks()
        mock = mocks[find(mocks, mock_id)]
        path = body_path(mock)
        if not path or not path.is_file():
            raise tornado.web.HTTPError(404, "no file for this mock")
        self.set_header("Content-Type", "application/octet-stream")
        self.set_header(
            "Content-Disposition", f'attachment; filename="{mock["body_filename"]}"'
        )
        self.write(path.read_bytes())


class HistoryHandler(ApiHandler):
    """Requests of the current history, to copy a mock from a real one."""

    async def get(self) -> None:
        self.write(await ask_addon("list"))


class HistoryFlowHandler(ApiHandler):
    """Fields of a new mock built from one of those requests.

    Nothing is saved: the dashboard fills the form with them, and it is the
    usual save that creates the mock (``clean_mock`` rebuilds it field by
    field anyway, so these values are not trusted any more than the others).
    """

    async def get(self, flow_id: str) -> None:
        answer = await ask_addon("flow", id=flow_id)
        self.write({
            "mock": answer.get("mock", {}),
            "note": str(answer.get("note", "")),
            # The content was left out of the form (binary, or too big): the
            # dashboard offers it for download instead
            "download": bool(answer.get("download")),
        })


class HistoryBodyHandler(ApiHandler):
    """The real content of a response, downloaded as a file.

    The addon writes it next to its answer (see ``save_body``); here it is
    handed to the browser and removed — it is a copy, not a store.
    """

    async def get(self, flow_id: str) -> None:
        answer = await ask_addon("body", id=flow_id)
        name = _safe_filename(str(answer.get("name", "")))
        file = (ASK_DIR / os.path.basename(str(answer.get("file", "")))).resolve()
        if not file.is_relative_to(ASK_DIR.resolve()) or not file.is_file():
            raise tornado.web.HTTPError(502, reason="content not received from mitmproxy")
        try:
            self.set_header("Content-Type", "application/octet-stream")
            self.set_header("Content-Disposition", f'attachment; filename="{name}"')
            self.write(file.read_bytes())
        finally:
            file.unlink(missing_ok=True)


class EnabledHandler(ApiHandler):
    """Global switch. Not persisted: see the note at the top of the file."""

    def get(self) -> None:
        self.write_state()

    def post(self) -> None:
        set_enabled(bool(self.json_body().get("enabled")))
        print(f"mockui: mocks {'enabled' if is_enabled() else 'disabled'}")
        self.write_state()


class IndexHandler(Access, tornado.web.RequestHandler):
    def get(self) -> None:
        self.set_header("Content-Type", "text/html; charset=utf-8")
        self.set_header("Cache-Control", "no-store")
        self.write((STATIC_DIR / "index.html").read_bytes())


class AssetHandler(Access, tornado.web.StaticFileHandler):
    """Only app.js and style.css: the directory also holds server.py.

    No caching: ./mockui is a volume, edited from the Mac, and a cached page
    would keep showing the previous version after a change.
    """

    def set_extra_headers(self, path: str) -> None:
        self.set_header("Cache-Control", "no-store")


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

def make_app() -> tornado.web.Application:
    return tornado.web.Application(
        [
            (r"/", IndexHandler),
            (r"/(app\.js|style\.css)", AssetHandler, {"path": str(STATIC_DIR)}),
            (r"/api/mocks", MocksHandler),
            (r"/api/mocks/([0-9a-f]+)", MockHandler),
            (r"/api/mocks/([0-9a-f]+)/move", MoveHandler),
            (r"/api/mocks/([0-9a-f]+)/body", BodyHandler),
            (r"/api/enabled", EnabledHandler),
            (r"/api/history", HistoryHandler),
            (r"/api/history/([0-9a-fA-F-]{8,64})", HistoryFlowHandler),
            (r"/api/history/([0-9a-fA-F-]{8,64})/body", HistoryBodyHandler),
        ],
        # Uploaded contents can be large (a recorded response body)
        max_buffer_size=64 * 1024 * 1024,
    )


async def main() -> None:
    FILES_DIR.mkdir(parents=True, exist_ok=True)
    # Answers to requests of a previous run: nobody is waiting for them
    ASK_DIR.mkdir(parents=True, exist_ok=True)
    for leftover in ASK_DIR.iterdir():
        leftover.unlink(missing_ok=True)
    # Mocks always start off, whatever the previous run left behind
    set_enabled(False)
    if not MOCKS_FILE.exists():
        save_mocks([])

    make_app().listen(PORT, address="0.0.0.0")
    where = ALLOWED_NETWORK or "anywhere (MITM_VM_NET not set)"
    print(f"mockui: listening on :{PORT}, allowed from {where}, mocks disabled")
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())

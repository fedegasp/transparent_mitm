"""
mitmproxy addon: mocks
======================
Serves the mocks defined from the dashboard (``mockui/server.py``, reachable
at http://mitmproxy.test:8082) in place of the real response.

The two processes share the ``/mocks`` volume (``./mocks`` on the Mac), and
every file has a single writer.

    dashboard  ──writes──▶  enabled, mocks.json, files/  ──read──▶  this addon
    this addon ──writes──▶  hits.json                    ──read──▶  dashboard

The one thing the dashboard cannot see on its own is the flow history, which
lives in mitmproxy's memory: it asks for it by writing ``ask/<token>.req``,
and this addon answers in ``ask/<token>.res`` (the same request/answer channel
``mac-editor.sh`` uses towards the Mac; each file still has a single writer).

``enabled`` is an empty file whose mere existence means "mocks active"; the
dashboard removes it when it starts, so after every container start the mocks
are off until the switch in the UI is turned on.

A mock matches on the HTTP method (a set, empty = any), the host, the path and
the key/value pairs to be found in the query string. Host and path accept a
trailing ``*`` as a wildcard (and the host also a leading ``*.``); empty means
any. The first enabled mock that matches, in list order, wins.

The response is built in the ``request`` hook, so the request never reaches the
server. The flow stays visible in mitmproxy, marked and with a comment saying
which mock answered.

Commands:
    mock.dashboard   open the dashboard in the browser on the Mac (key M)
"""

from __future__ import annotations

import asyncio
import json
import logging
import mimetypes
import re
import time
from pathlib import Path
from typing import Any

from mitmproxy import command, ctx, http

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MOCKS_DIR = Path("/mocks")
FILES_DIR = MOCKS_DIR / "files"
MOCKS_FILE = MOCKS_DIR / "mocks.json"
HITS_FILE = MOCKS_DIR / "hits.json"
ENABLED_FILE = MOCKS_DIR / "enabled"

# Channel towards the Mac, the same one mac-editor.sh uses: ./mitm open and
# ./mitm attach watch this directory while a terminal is attached
EDIT_DIR = Path("/edit")
URL_FILE = EDIT_DIR / "mock-dashboard.url"
URL_REQUEST = EDIT_DIR / "mock-dashboard.url.open"
URL_ERROR = EDIT_DIR / "mock-dashboard.url.error"

DASHBOARD_URL = "http://mitmproxy.test:8082/"

# Status codes that must not carry a body (RFC 9110 §6.4.1)
NO_BODY_STATUS = {204, 304}

# Hits are counted in memory and written at most once every HITS_INTERVAL
# seconds: one file write per request would be pointless I/O
HITS_INTERVAL = 2.0

# Requests of the dashboard for the flow history (see the header): it writes
# <token>.req here, this addon answers in <token>.res and removes the request.
ASK_DIR = MOCKS_DIR / "ask"
ASK_INTERVAL = 0.3    # polling: one listing of a directory that is almost always empty
ASK_TTL = 60.0        # answers nobody read (dashboard reloaded, browser closed)

# Flows offered to the picker, newest first. The response content is copied
# into the form only if it is text and not too big: a mock with a truncated
# body would be worse than one to fill in by hand. What is left out can be
# downloaded as a file (<token>.body, written next to the answer).
HISTORY_MAX = 200
HISTORY_BODY_MAX = 512 * 1024

# Content types copied into the form as text; the others are offered as a
# file. The bytes are not enough to decide: mitmproxy decodes a PNG into text
# without complaining (it falls back to an encoding that never fails).
TEXT_TYPES = (
    "text/", "application/json", "application/xml", "application/javascript",
    "application/ecmascript", "application/x-www-form-urlencoded",
)

# Response headers not copied into the mock: those that describe the body
# (rebuilt by Response.make from the mock's own content), the hop-by-hop ones
# and those that only add noise. Content-Type has its own field in the form.
SKIP_HEADERS = {
    "content-type", "content-length", "content-encoding", "transfer-encoding",
    "connection", "keep-alive", "upgrade", "trailer", "te", "proxy-connection",
    "proxy-authenticate", "date", "server", "alt-svc",
}


# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

def matches_pattern(pattern: str, value: str) -> bool:
    """Empty pattern = anything; ``*.suffix`` and ``prefix*`` as wildcards."""
    if not pattern:
        return True
    if pattern.startswith("*."):
        return value == pattern[2:] or value.endswith(pattern[1:])
    if pattern.endswith("*"):
        return value.startswith(pattern[:-1])
    return value == pattern


def matches(mock: dict[str, Any], request: http.Request) -> bool:
    methods = mock.get("methods") or []
    if methods and request.method.upper() not in methods:
        return False
    if not matches_pattern(mock.get("host", "").lower(), request.pretty_host.lower()):
        return False
    if not matches_pattern(mock.get("path", ""), request.path.split("?", 1)[0]):
        return False
    for pair in mock.get("query") or []:
        if pair["value"] not in request.query.get_all(pair["key"]):
            return False
    return True


# ---------------------------------------------------------------------------
# History: a real flow turned into the form of a new mock
# ---------------------------------------------------------------------------

def summary(flow: http.HTTPFlow) -> dict[str, Any]:
    """One line of the picker."""
    response = flow.response
    content = response.raw_content if response else None
    return {
        "id": flow.id,
        "time": time.strftime("%H:%M:%S", time.localtime(flow.request.timestamp_start)),
        "method": flow.request.method,
        "host": flow.request.pretty_host,
        "path": flow.request.path,
        "status": response.status_code if response else None,
        "content_type": response.headers.get("content-type", "").split(";")[0] if response else "",
        "size": len(content) if content is not None else None,
    }


def size_text(count: int) -> str:
    return f"{count} B" if count < 1024 else f"{count / 1024:.0f} KB"


def is_text(content_type: str) -> bool:
    """Empty Content-Type: left to the strict decoding of response_body."""
    kind = content_type.split(";")[0].strip().lower()
    return not kind or kind.startswith(TEXT_TYPES) or kind.endswith(("+json", "+xml"))


def response_body(response: http.Response) -> tuple[str, str, bool]:
    """Content of the response as text for the form, why it is missing, and
    whether it can at least be downloaded as a file."""
    content = response.get_content(strict=False)
    if content is None:
        return "", "Streamed response: the content was not kept", False
    if not content:
        return "", "", False
    kind = response.headers.get("content-type", "")
    size = size_text(len(content))
    if len(content) > HISTORY_BODY_MAX:
        return "", f"Content of {size}: not copied into the form (limit {HISTORY_BODY_MAX // 1024} KB)", True
    if not is_text(kind):
        return "", f"Binary content ({kind.split(';')[0]}, {size}): not copied into the form", True
    try:
        return response.get_text(strict=True) or "", "", False
    except ValueError:
        return "", f"Content of {size} not decodable: not copied into the form", True


def download_name(flow: http.HTTPFlow) -> str:
    """The URL of the request as a file name, for the downloaded content."""
    url = f"{flow.request.pretty_host}{flow.request.path.split('?', 1)[0]}"
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", url).strip("-.")[:80] or "response"
    kind = (flow.response.headers.get("content-type", "") if flow.response else "")
    suffix = mimetypes.guess_extension(kind.split(";")[0].strip()) or ""
    return name if name.endswith(suffix) else name + suffix


def prefill(flow: http.HTTPFlow) -> dict[str, Any]:
    """Fields of a new mock that reproduces this flow, and a note for the UI.

    The match is the request without its query string (every parameter of a
    real URL as a condition would make the mock match almost nothing); the
    response is the real one, which is what there is to edit.
    """
    request = flow.request
    path = request.path.split("?", 1)[0]
    mock: dict[str, Any] = {
        "name": f"{request.method} {request.pretty_host}{path}",
        "enabled": True,
        "methods": [request.method.upper()],
        "host": request.pretty_host.lower(),
        "path": path,
        "query": [],
        "status": 200,
        "content_type": "",
        "headers": [],
        "body_mode": "text",
        "body": "",
    }
    if flow.response:
        mock["status"] = flow.response.status_code
        mock["content_type"] = flow.response.headers.get("content-type", "")
        mock["headers"] = [
            {"key": key, "value": value}
            for key, value in flow.response.headers.items(multi=True)
            if key.lower() not in SKIP_HEADERS
        ]
        mock["body"], note, download = response_body(flow.response)
    else:
        note, download = "No response: only the request has been copied", False
    return {"mock": mock, "note": note, "download": download}


# ---------------------------------------------------------------------------
# Addon
# ---------------------------------------------------------------------------

class Mocks:
    def __init__(self) -> None:
        self.mocks: list[dict[str, Any]] = []
        self.mtime: float | None = None
        self.hits: dict[str, dict[str, Any]] = self._read_hits()
        self.flush_scheduled = False
        self.polling = False

    # --- mocks.json, reloaded when it changes -----------------------------

    def reload(self) -> None:
        """Reread mocks.json if its mtime changed (one stat per request)."""
        try:
            mtime = MOCKS_FILE.stat().st_mtime
        except OSError:
            self.mocks, self.mtime = [], None
            return
        if mtime == self.mtime:
            return
        try:
            data = json.loads(MOCKS_FILE.read_text())
            self.mocks = data["mocks"] if isinstance(data, dict) else data
        except (OSError, ValueError, KeyError, TypeError) as exc:
            logging.warning(f"[mocks] {MOCKS_FILE} unreadable: {exc}")
            self.mocks = []
        self.mtime = mtime
        # Counters of deleted mocks: dropping them here, and not from the
        # dashboard, keeps hits.json with a single writer
        ids = {mock.get("id") for mock in self.mocks}
        pruned = {k: v for k, v in self.hits.items() if k in ids}
        if len(pruned) != len(self.hits):
            self.hits = pruned
            self.schedule_flush()
        logging.info(f"[mocks] {len(self.mocks)} mocks loaded")

    # --- hit counters, for the dashboard ----------------------------------

    @staticmethod
    def _read_hits() -> dict[str, dict[str, Any]]:
        try:
            hits = json.loads(HITS_FILE.read_text())
            return hits if isinstance(hits, dict) else {}
        except (OSError, ValueError):
            return {}

    def count_hit(self, mock_id: str) -> None:
        entry = self.hits.setdefault(mock_id, {"count": 0, "last": ""})
        entry["count"] += 1
        entry["last"] = time.strftime("%H:%M:%S")
        self.schedule_flush()

    def schedule_flush(self) -> None:
        if not self.flush_scheduled:
            self.flush_scheduled = True
            asyncio.get_running_loop().call_later(HITS_INTERVAL, self.flush_hits)

    def flush_hits(self) -> None:
        self.flush_scheduled = False
        try:
            tmp = HITS_FILE.with_name(".hits.json.tmp")
            tmp.write_text(json.dumps(self.hits))
            tmp.replace(HITS_FILE)
        except OSError as exc:
            logging.warning(f"[mocks] cannot write {HITS_FILE}: {exc}")

    # --- response ----------------------------------------------------------

    @staticmethod
    def body_of(mock: dict[str, Any]) -> bytes:
        if mock.get("body_mode") != "file":
            return str(mock.get("body", "")).encode()
        rel = mock.get("body_file")
        if not rel:
            return b""
        # body_file is also editable by hand from the Mac: never leave files/
        path = (MOCKS_DIR / rel).resolve()
        if not path.is_relative_to(FILES_DIR.resolve()):
            logging.warning(f"[mocks] '{rel}' outside {FILES_DIR}, ignored")
            return b""
        try:
            return path.read_bytes()
        except OSError as exc:
            logging.warning(f"[mocks] cannot read '{rel}': {exc}")
            return b""

    def respond(self, mock: dict[str, Any], flow: http.HTTPFlow) -> None:
        status = int(mock.get("status", 200))
        body = b"" if status in NO_BODY_STATUS or status < 200 else self.body_of(mock)

        headers: list[tuple[bytes, bytes]] = []
        if body:
            content_type = mock.get("content_type") or "text/plain; charset=utf-8"
            headers.append((b"Content-Type", content_type.encode()))
        for pair in mock.get("headers") or []:
            headers.append((pair["key"].encode(), str(pair["value"]).encode()))

        flow.response = http.Response.make(status, body, headers)
        flow.marked = ":large_purple_circle:"
        flow.comment = f"mock: {mock.get('name', '')}"
        self.count_hit(mock["id"])

    # --- hooks -------------------------------------------------------------

    def request(self, flow: http.HTTPFlow) -> None:
        if not ENABLED_FILE.exists():
            return
        self.reload()
        for mock in self.mocks:
            if mock.get("enabled") and matches(mock, flow.request):
                self.respond(mock, flow)
                return

    def running(self) -> None:
        if not self.polling:
            self.polling = True
            self.poll_ask()

    def done(self) -> None:
        # Also called on the old instance when the addon is reloaded: without
        # this, two pollers would race for the same requests
        self.polling = False
        if self.flush_scheduled:
            self.flush_hits()

    # --- requests of the dashboard ----------------------------------------

    def poll_ask(self) -> None:
        """Answer the dashboard's requests (see the header).

        Polling, and not a socket: a socket in the addon would have to be
        released and reopened at every hot reload. One listing of an almost
        always empty directory every ASK_INTERVAL costs nothing.
        """
        if not self.polling:
            return
        now = time.time()
        try:
            ASK_DIR.mkdir(exist_ok=True)
            entries = list(ASK_DIR.iterdir())
        except OSError as exc:
            logging.warning(f"[mocks] {ASK_DIR} unusable: {exc}")
            entries = []
        for path in entries:
            try:
                if path.suffix == ".req":
                    self.answer(path)
                elif now - path.stat().st_mtime > ASK_TTL:
                    path.unlink(missing_ok=True)
            except OSError as exc:
                logging.warning(f"[mocks] {path.name}: {exc}")
        asyncio.get_running_loop().call_later(ASK_INTERVAL, self.poll_ask)

    def answer(self, path: Path) -> None:
        """Read a request, remove it and write the answer next to it."""
        try:
            ask = json.loads(path.read_text())
        except (OSError, ValueError):
            ask = {}
        path.unlink(missing_ok=True)
        try:
            data = self.handle(ask if isinstance(ask, dict) else {}, path.stem)
        except Exception as exc:  # the dashboard must get an answer anyway
            logging.warning(f"[mocks] request {ask}: {exc}")
            data = {"error": str(exc)}
        result = path.with_suffix(".res")
        tmp = result.with_name(f".{result.name}.tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(result)

    def handle(self, ask: dict[str, Any], token: str) -> dict[str, Any]:
        what = ask.get("what")
        if what == "list":
            return {"flows": [summary(flow) for flow in self.flows()[:HISTORY_MAX]]}
        if what in ("flow", "body"):
            flow = next((f for f in self.flows() if f.id == ask.get("id")), None)
            if flow is None:
                return {"error": "the request is no longer in the history"}
            return prefill(flow) if what == "flow" else self.save_body(flow, token)
        return {"error": f"unknown request '{what}'"}

    @staticmethod
    def save_body(flow: http.HTTPFlow, token: str) -> dict[str, Any]:
        """Write the content of the response next to the answer, for the
        dashboard to hand it to the browser and remove it.

        The content, not the bytes on the wire: a gzipped file would be of no
        use. It is not passed inside the answer (base64 of a few MB for every
        video), and it is not kept: what is downloaded is a copy of what is in
        mitmproxy's memory at that moment.
        """
        content = flow.response.get_content(strict=False) if flow.response else None
        if not content:
            return {"error": "this response has no content"}
        file = ASK_DIR / f"{token}.body"
        tmp = file.with_name(f".{file.name}.tmp")
        tmp.write_bytes(content)
        tmp.replace(file)
        return {"file": file.name, "name": download_name(flow), "size": len(content)}

    @staticmethod
    def flows() -> list[http.HTTPFlow]:
        """HTTP flows of the current history, newest first.

        The source is mitmproxy's view addon, i.e. exactly what the console or
        the web UI is showing, filter included. Its order depends on the
        options (view_order, view_order_reversed): the picker sorts by itself.
        """
        view = ctx.master.addons.get("view")
        if view is None:
            raise RuntimeError("history not available (no view addon)")
        flows = [flow for flow in view if isinstance(flow, http.HTTPFlow)]
        flows.sort(key=lambda flow: flow.request.timestamp_start, reverse=True)
        return flows

    # --- command -----------------------------------------------------------

    @command.command("mock.dashboard")
    def dashboard(self) -> None:
        """Open the mock dashboard in the browser on the Mac."""
        logging.info(f"[mocks] dashboard: {DASHBOARD_URL}")
        self._ask_mac()

    def _ask_mac(self, attempt: int = 0) -> None:
        """Write the request for ./mitm open/attach, which claims it by
        renaming it; if nobody is attached it stays there (see _check_opened).

        A file removed on the Mac stays visible through the volume for ~1s, and
        recreating it in the meantime fails with ENOENT: listing the directory
        refreshes the entry, as mac-editor.sh does when reading back. The retry
        goes through the event loop, never a sleep: this addon is in the path
        of every request.
        """
        loop = asyncio.get_running_loop()
        try:
            EDIT_DIR.mkdir(exist_ok=True)
            list(EDIT_DIR.iterdir())
            URL_ERROR.unlink(missing_ok=True)
            URL_FILE.write_text(DASHBOARD_URL)
            URL_REQUEST.write_text("url")
        except OSError as exc:
            if attempt < 9:
                loop.call_later(0.2, self._ask_mac, attempt + 1)
            else:
                logging.error(f"[mocks] cannot ask the Mac to open the dashboard: {exc}")
            return
        loop.call_later(3.0, self._check_opened)

    @staticmethod
    def _check_opened() -> None:
        list(EDIT_DIR.iterdir())
        # ./mitm open reports a failed `open` here (wrong URL, no browser, ...)
        if URL_ERROR.exists():
            error = URL_ERROR.read_text().strip()
            URL_ERROR.unlink(missing_ok=True)
            logging.log(logging.CRITICAL, f"[mocks] the Mac did not open the dashboard: {error}")
            return
        if not URL_REQUEST.exists():
            return
        URL_REQUEST.unlink(missing_ok=True)
        URL_FILE.unlink(missing_ok=True)
        logging.log(
            logging.CRITICAL,
            f"[mocks] no terminal attached (./mitm open): open {DASHBOARD_URL} by hand",
        )


addons = [Mocks()]

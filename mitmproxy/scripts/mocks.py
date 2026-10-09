"""
mitmproxy addon: mocks
======================
Serves the mocks defined from the dashboard (``mockui/server.py``, reachable
at http://mitmproxy.test:8082) in place of the real response.

The two processes never talk to each other: they share the ``/mocks`` volume
(``./mocks`` on the Mac), and every file has a single writer.

    dashboard  ──writes──▶  enabled, mocks.json, files/  ──read──▶  this addon
    this addon ──writes──▶  hits.json                    ──read──▶  dashboard

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
import time
from pathlib import Path
from typing import Any

from mitmproxy import command, http

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
# Addon
# ---------------------------------------------------------------------------

class Mocks:
    def __init__(self) -> None:
        self.mocks: list[dict[str, Any]] = []
        self.mtime: float | None = None
        self.hits: dict[str, dict[str, Any]] = self._read_hits()
        self.flush_scheduled = False

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

    def done(self) -> None:
        if self.flush_scheduled:
            self.flush_hits()

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

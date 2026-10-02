"""
mitmproxy addon: export.files
==============================
Adds the command `export.files <flows> <path_template>`, which exports all
the selected requests in raw format.

Path template format
--------------------
The template must contain a sequence of one or more consecutive '#' that
will be replaced with a sequential number starting from 1, zero-padded to
the number of '#' present.

Examples:
  export.files @shown /tmp/flow_###.raw   →  flow_001.raw, flow_002.raw …
  export.files @all   /tmp/req_#.raw      →  req_1.raw, req_2.raw …
  export.files @focus /tmp/dump_#####.bin →  dump_00001.bin …

Exported raw format
-------------------
For each flow the following are written:
  - the raw HTTP request  (request line + headers + body)
  - a visual separator
  - the raw HTTP response (status line + headers + body), if available

Installation
------------
  mitmproxy -s export_files.py
  mitmweb   -s export_files.py
  mitmdump  -s export_files.py

From the mitmproxy prompt:
  : export.files @shown /tmp/flow_###.raw
"""

from __future__ import annotations

import logging
import re
from collections.abc import Sequence
from pathlib import Path

from mitmproxy import command, ctx, flow, http, types
from mitmproxy.net.http import http1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_SEPARATOR = b"\r\n" + b"-" * 60 + b"\r\n"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve_path(template: str, index: int) -> Path:
    """Replace the first sequence of '#' with the zero-padded sequential number."""
    match = re.search(r"(#+)", template)
    if not match:
        raise ValueError(
            f"The template '{template}' does not contain any '#' character."
        )
    hashes = match.group(1)
    replacement = str(index).zfill(len(hashes))
    return Path(template.replace(hashes, replacement, 1))


def _request_to_raw(req: http.Request) -> bytes:
    """Serialize the Request in HTTP/1.1 wire format."""
    head = http1.assemble_request_head(req)
    body = req.raw_content or b""
    return head + body


def _response_to_raw(resp: http.Response) -> bytes:
    """Serialize the Response in HTTP/1.1 wire format."""
    head = http1.assemble_response_head(resp)
    body = resp.raw_content or b""
    return head + body


def _flow_to_raw(f: http.HTTPFlow) -> bytes:
    """Convert an HTTPFlow into the raw payload to write to disk."""
    parts: list[bytes] = [_request_to_raw(f.request), _SEPARATOR]
    if f.response is not None:
        parts.append(_response_to_raw(f.response))
    else:
        parts.append(b"[No response captured]\r\n")
    return b"".join(parts)


# ---------------------------------------------------------------------------
# Addon
# ---------------------------------------------------------------------------

class ExportFiles:
    """Addon that registers the ``export.files`` command."""

    @command.command("export.files")
    def export_files(
        self,
        flows: Sequence[flow.Flow],
        path: types.Path,
    ) -> None:
        """
        Export the selected flows in raw format using a path template.

        The template must contain one or more consecutive '#' that will be
        replaced with a zero-padded sequential number (e.g. ### → 001).

        Usage:
            export.files @shown /tmp/flow_###.raw
            export.files @all   /tmp/capture_##.bin
            export.files @focus /tmp/single_#.raw
        """
        template = str(path)

        if not re.search(r"#+", template):
            logging.error(
                f"[export.files] The template '{template}' does not contain '#'. "
                "Specify at least one '#' for the sequential number."
            )
            return

        exported = 0
        skipped = 0
        errors = 0

        for idx, f in enumerate(flows, start=1):
            if not isinstance(f, http.HTTPFlow):
                logging.warning(
                    f"[export.files] Flow #{idx} is not an HTTPFlow — skipped."
                )
                skipped += 1
                continue

            try:
                dest = _resolve_path(template, idx)
            except ValueError as exc:
                logging.error(f"[export.files] {exc}")
                return

            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(_flow_to_raw(f))
                logging.info(
                    f"[export.files] [{idx}] "
                    f"{f.request.method} {f.request.pretty_url} → {dest}"
                )
                exported += 1
            except OSError as exc:
                logging.error(
                    f"[export.files] Cannot write '{dest}': {exc}"
                )
                errors += 1

        parts = [f"{exported} files exported"]
        if skipped:
            parts.append(f"{skipped} skipped")
        if errors:
            parts.append(f"{errors} errors")
        logging.log(logging.CRITICAL, f"[export.files] Done: {', '.join(parts)}.")


addons = [ExportFiles()]

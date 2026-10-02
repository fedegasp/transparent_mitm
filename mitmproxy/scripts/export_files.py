"""
mitmproxy addon: export.files
==============================
Aggiunge il comando `export.files <flows> <path_template>` che esporta in
formato raw tutte le chiamate selezionate.

Formato del path template
--------------------------
Il template deve contenere una sequenza di uno o più '#' consecutivi che
verranno sostituiti con un numero progressivo a partire da 1, con padding
di zeri pari al numero di '#' presenti.

Esempi:
  export.files @shown /tmp/flow_###.raw   →  flow_001.raw, flow_002.raw …
  export.files @all   /tmp/req_#.raw      →  req_1.raw, req_2.raw …
  export.files @focus /tmp/dump_#####.bin →  dump_00001.bin …

Formato raw esportato
---------------------
Per ogni flow vengono scritti:
  - la request HTTP grezza  (request line + headers + body)
  - un separatore visivo
  - la response HTTP grezza (status line + headers + body), se disponibile

Installazione
-------------
  mitmproxy -s export_files.py
  mitmweb   -s export_files.py
  mitmdump  -s export_files.py

Dal prompt di mitmproxy:
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
# Costanti
# ---------------------------------------------------------------------------

_SEPARATOR = b"\r\n" + b"-" * 60 + b"\r\n"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve_path(template: str, index: int) -> Path:
    """Sostituisce la prima sequenza di '#' con il numero progressivo zero-padded."""
    match = re.search(r"(#+)", template)
    if not match:
        raise ValueError(
            f"Il template '{template}' non contiene nessun carattere '#'."
        )
    hashes = match.group(1)
    replacement = str(index).zfill(len(hashes))
    return Path(template.replace(hashes, replacement, 1))


def _request_to_raw(req: http.Request) -> bytes:
    """Serializza la Request in formato wire HTTP/1.1."""
    head = http1.assemble_request_head(req)
    body = req.raw_content or b""
    return head + body


def _response_to_raw(resp: http.Response) -> bytes:
    """Serializza la Response in formato wire HTTP/1.1."""
    head = http1.assemble_response_head(resp)
    body = resp.raw_content or b""
    return head + body


def _flow_to_raw(f: http.HTTPFlow) -> bytes:
    """Converte un HTTPFlow nel payload raw da scrivere su disco."""
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
    """Addon che registra il comando ``export.files``."""

    @command.command("export.files")
    def export_files(
        self,
        flows: Sequence[flow.Flow],
        path: types.Path,
    ) -> None:
        """
        Esporta i flow selezionati in formato raw usando un path template.

        Il template deve contenere una o più '#' consecutive che verranno
        sostituite con un numero progressivo zero-padded (es. ### → 001).

        Uso:
            export.files @shown /tmp/flow_###.raw
            export.files @all   /tmp/capture_##.bin
            export.files @focus /tmp/single_#.raw
        """
        template = str(path)

        if not re.search(r"#+", template):
            logging.error(
                f"[export.files] Il template '{template}' non contiene '#'. "
                "Specifica almeno un '#' per il numero progressivo."
            )
            return

        exported = 0
        skipped = 0
        errors = 0

        for idx, f in enumerate(flows, start=1):
            if not isinstance(f, http.HTTPFlow):
                logging.warning(
                    f"[export.files] Flow #{idx} non è un HTTPFlow — ignorato."
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
                    f"[export.files] Impossibile scrivere '{dest}': {exc}"
                )
                errors += 1

        parts = [f"{exported} file esportati"]
        if skipped:
            parts.append(f"{skipped} ignorati")
        if errors:
            parts.append(f"{errors} errori")
        logging.log(logging.CRITICAL, f"[export.files] Completato: {', '.join(parts)}.")


addons = [ExportFiles()]

from mitmproxy import http
import re

ENABLED = False
RULES = [
    (r"api\.example\.com/v1/users", 200, "[MITMPROXY] - changed"),
    (r"api\.example\.com/v1/broken", 500, "[MITMPROXY] - changed"),
    (r"/login", 403, "[MITMPROXY] - changed"),
]
METHODS = ["GET"]

def response(flow: http.HTTPFlow) -> None:
    if not ENABLED:
        return

    if flow.request.method not in METHODS:
        return

    for pattern, status_code, body in RULES:
            if re.search(pattern, flow.request.pretty_url):
                flow.response = http.Response.make(
                                status_code,
                                body.encode(),
                                {"Content-Type": "text/plain"},
                            )
                return

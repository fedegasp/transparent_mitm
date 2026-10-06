FROM python:3.13-slim-bookworm

ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    tini \
    curl \
    procps \
    dnsutils \
    iproute2 \
    tmux \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "mitmproxy==12.2.3"

COPY entrypoint.sh /entrypoint.sh
COPY mac-editor.sh /usr/local/bin/mac-editor
RUN chmod +x /entrypoint.sh /usr/local/bin/mac-editor

# Console: editing (e) and external viewer (v) with an application on the
# Mac, through ./edit (see mac-editor.sh)
ENV MITMPROXY_EDITOR=/usr/local/bin/mac-editor

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

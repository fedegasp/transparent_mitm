#!/bin/sh
set -e

# Local redirect: everything arriving on 80/443 (routed by pf via route-to,
# with the original destination intact) is diverted to the local mitmproxy.
# This step creates the conntrack entry that mitmproxy reads to recover the
# original address.
# Sources: LAN clients and the Mac (IP of its WAN, which varies): everything
# except the container network, derived from the default route interface (the
# prefix is enough, iptables clears the host bits). Non-local destination:
# direct connections to the container are left alone.
VM_NET=""
for _ in $(seq 1 20); do
  DEV=$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit }')
  [ -n "$DEV" ] && VM_NET=$(ip -4 -o addr show dev "$DEV" | awk '{ print $4; exit }')
  [ -n "$VM_NET" ] && break
  sleep 0.5
done
[ -n "$VM_NET" ] || { echo "Container network not configured" >&2; exit 1; }
echo "Container network: $VM_NET ($DEV)"
iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING ! -s "$VM_NET" -m addrtype ! --dst-type LOCAL \
  -p tcp -m multiport --dports 80,443 -j REDIRECT --to-port 7070

# Working directory: /export (./export on the Mac). Relative paths of the
# commands that write to disk (save.file, export.file, cut.save, ...) end up
# there and are immediately visible on the Mac.
mkdir -p /export
cd /export

# /edit (./edit on the Mac): copies of the files being edited on the Mac
# (mac-editor.sh). Leftovers of a previous run are removed.
mkdir -p /edit
find /edit -mindepth 1 -delete

# /mocks (./mocks on the Mac): mock definitions and uploaded contents, shared
# with the dashboard. The 'enabled' switch is removed by the dashboard at
# startup: the mocks always start off.
mkdir -p /mocks/files

# From here on, mitmproxy/mitmweb exiting must not terminate the script
set +e

# Mock dashboard (./mockui on the Mac), always started, whatever MITM_UI is:
# the mocks can be prepared with mitmproxy restarting or interception off. It
# is a separate process on purpose — a crash here, or a reload of the addon
# that serves the mocks, must not touch the proxy. Supervised like mitmproxy
# below; PID 1 is tini, so it is reaped correctly. MITM_VM_NET restricts the
# dashboard to the Mac (see mockui/server.py).
export MITM_VM_NET="$VM_NET"
(
  while true; do
    python3 /mockui/server.py
    echo "mock dashboard exited, restarting in 1s..."
    sleep 1
  done
) &

OPTS="--mode transparent --showhost --listen-host 0.0.0.0 --listen-port 7070 --set block_global=false"

# MITM_UI=console (default): mitmproxy (text interface) in a tmux session
# "mitm", to attach with
#   container exec -it mitmproxy.test tmux attach -t mitm
# The inner loop restarts mitmproxy after it exits (q) without closing the
# session; the outer one recreates the session if it is closed (kill-session),
# and keeps the container alive.
if [ "${MITM_UI:-console}" = console ]; then
  while true; do
    if ! tmux has-session -t mitm 2> /dev/null; then
      echo "Starting mitmproxy in tmux session mitm"
      tmux new-session -d -s mitm -x 200 -y 50 \
        "while true; do mitmproxy $OPTS; echo 'mitmproxy exited, restarting in 1s...'; sleep 1; done"
    fi
    sleep 2
  done
fi

# MITM_UI=web: mitmweb, web UI on :8081.
# Web UI password from an environment variable (./mitm start always passes it,
# default 'password'); if missing, mitmweb generates a random token, shown in
# `container logs mitmproxy.test`
while true; do
  mitmweb $OPTS \
    --web-host 0.0.0.0 \
    --web-port 8081 \
    ${MITM_WEB_PASSWORD:+--set web_password="$MITM_WEB_PASSWORD"}
  echo "mitmweb exited, restarting in 1s..."
  sleep 1
done

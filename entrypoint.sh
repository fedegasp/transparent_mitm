#!/bin/sh
set -e

# Redirect locale: tutto ciò che arriva su 80/443 (instradato da pf via route-to,
# con destinazione originale intatta) viene deviato verso mitmproxy in locale.
# Questo passaggio è quello che crea la voce di conntrack che mitmproxy legge
# per recuperare l'indirizzo originale.
# Sorgenti: client LAN e Mac (IP della sua WAN, variabile): tutto tranne la
# rete dei container, ricavata dall'interfaccia della rotta di default (il
# prefisso basta, iptables azzera i bit dell'host). Destinazione non locale:
# non tocca le connessioni dirette al container.
VM_NET=""
for _ in $(seq 1 20); do
  DEV=$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit }')
  [ -n "$DEV" ] && VM_NET=$(ip -4 -o addr show dev "$DEV" | awk '{ print $4; exit }')
  [ -n "$VM_NET" ] && break
  sleep 0.5
done
[ -n "$VM_NET" ] || { echo "Rete del container non configurata" >&2; exit 1; }
echo "Rete dei container: $VM_NET ($DEV)"
iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING ! -s "$VM_NET" -m addrtype ! --dst-type LOCAL \
  -p tcp -m multiport --dports 80,443 -j REDIRECT --to-port 7070

# Directory corrente: /export (./export sul Mac). I percorsi relativi dei
# comandi che scrivono su disco (save.file, export.file, cut.save, ...) finiscono
# lì e sono subito visibili sul Mac.
mkdir -p /export
cd /export

# Da qui in poi un'uscita di mitmproxy/mitmweb non deve terminare lo script
set +e

OPTS="--mode transparent --showhost --listen-host 0.0.0.0 --listen-port 7070 --set block_global=false"

# MITM_UI=console (default): mitmproxy (interfaccia testuale) in una sessione
# tmux "mitm", da collegare con
#   container exec -it mitmproxy.test tmux attach -t mitm
# Il ciclo interno riavvia mitmproxy dopo un'uscita (q) senza chiudere la
# sessione; quello esterno ricrea la sessione se viene chiusa (kill-session),
# e tiene in vita il container.
if [ "${MITM_UI:-console}" = console ]; then
  while true; do
    if ! tmux has-session -t mitm 2> /dev/null; then
      echo "Avvio mitmproxy nella sessione tmux mitm"
      tmux new-session -d -s mitm -x 200 -y 50 \
        "while true; do mitmproxy $OPTS; echo 'mitmproxy terminato, riavvio tra 1s...'; sleep 1; done"
    fi
    sleep 2
  done
fi

# MITM_UI=web: mitmweb, web UI su :8081.
# Password della web UI da variabile d'ambiente (./mitm start la passa sempre,
# default 'password'); se assente mitmweb genera un token casuale, visibile in
# `container logs mitmproxy.test`
while true; do
  mitmweb $OPTS \
    --web-host 0.0.0.0 \
    --web-port 8081 \
    ${MITM_WEB_PASSWORD:+--set web_password="$MITM_WEB_PASSWORD"}
  echo "mitmweb terminato, riavvio tra 1s..."
  sleep 1
done

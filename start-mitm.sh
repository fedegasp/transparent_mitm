#!/bin/bash
set -euo pipefail

# Avvia mitmproxy (container mitmproxy.test) e la regola pf che gli instrada
# l'HTTP/HTTPS dei client LAN. Dipende dal DHCP (che assegna il Mac come
# gateway ai client): lo avvia prima con start-dhcp.sh, idempotente.
#
# Nessun sudo: lo script scrive bridge e IP del container in
# /usr/local/var/mitm-pf/route e il LaunchDaemon di root com.mitm.pf rigenera
# l'anchor com.mitm.route.
#
# Uso: ./start-mitm.sh
#      MITM_UI=web MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
# MITM_UI: console (default, mitmproxy in tmux:
#   container exec -it mitmproxy.test tmux attach -t mitm)
# oppure web (mitmweb, http://mitmproxy.test:8081).
# Password della web UI: default 'password'.
# MITM_UI e MITM_WEB_PASSWORD servono solo alla creazione del container; nei
# rilanci successivi (container già esistente) vengono ignorate.

# I volumi usano percorsi relativi alla directory del progetto
cd "$(dirname "$0")"

# Dipendenza: DHCP attivo
./start-dhcp.sh

# Dominio DNS locale di container (creato una volta con
# `sudo container system dns create test`). Il DNS integrato risolve solo i
# container il cui nome è <nome>.<dominio>: sul Mac la web UI è raggiungibile
# come http://mitmproxy.test:8081, qualunque sia l'IP corrente.
DNS_DOMAIN=test
NAME="mitmproxy.$DNS_DOMAIN"
IMAGE=mitm-transparent
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.route

# Avvia un container esistente se è fermo. Ritorna 1 se il container non esiste.
start_existing() {
  container inspect "$1" > /dev/null 2>&1 || return 1
  if [ "$(container inspect "$1" | jq -r '.[0].status.state')" != "running" ]; then
    echo "Avvio il container $1"
    container start "$1" > /dev/null
  fi
}

# Stampa "IP GATEWAY" del container. L'IP viene assegnato poco dopo l'avvio:
# attende fino a ~10s.
container_net() {
  local info ip gw
  for _ in $(seq 1 20); do
    info=$(container inspect "$1")
    ip=$(jq -r '.[0].status.networks[0].ipv4Address // empty' <<<"$info" | cut -d'/' -f1)
    gw=$(jq -r '.[0].status.networks[0].ipv4Gateway // empty' <<<"$info")
    if [ -n "$ip" ] && [ -n "$gw" ]; then
      echo "$ip $gw"
      return 0
    fi
    sleep 0.5
  done
  echo "Impossibile determinare IP/gateway del container $1" >&2
  return 1
}

# Scrive il file di stato per il daemon (rename atomico: il daemon, attivato
# da WatchPaths sulla directory, non legge mai un file scritto a metà)
write_state() {
  printf '%s\n' "$2" > "$STATE/.$1.tmp"
  mv "$STATE/.$1.tmp" "$STATE/$1"
}

# Attende che il daemon abbia applicato la regola: anchor che contiene $2,
# o vuoto se $2 è vuoto. Fino a ~10s.
wait_anchor() {
  for _ in $(seq 1 20); do
    if [ -z "$2" ]; then
      [ ! -s "$1" ] && return 0
    else
      grep -qF -- "$2" "$1" 2> /dev/null && return 0
    fi
    sleep 0.5
  done
  echo "Il daemon com.mitm.pf non ha aggiornato $1: vedi /var/log/mitm-pf.log" >&2
  return 1
}

# mitmproxy: crea il container se non esiste, lo avvia se è fermo
if ! start_existing "$NAME"; then
  echo "Creo il container $NAME"
  # ./export: directory corrente di mitmproxy, i file salvati dai suoi comandi
  # compaiono qui sul Mac (deve esistere, altrimenti container run fallisce)
  mkdir -p export
  container run -d --name "$NAME" \
    --cap-add NET_ADMIN \
    --dns-domain "$DNS_DOMAIN" \
    --volume ./mitmproxy:/root/.mitmproxy \
    --volume ./export:/export \
    -e "MITM_UI=${MITM_UI:-console}" \
    -e "MITM_WEB_PASSWORD=${MITM_WEB_PASSWORD:-password}" \
    "$IMAGE" > /dev/null
fi

NET=$(container_net "$NAME")
read -r CONTAINER_IP GATEWAY <<<"$NET"

# Bridge vmnet = interfaccia del Mac che ha l'IP del gateway (es. bridge100)
BRIDGE=$(ifconfig | awk -v gw="$GATEWAY" '
  /^[a-z0-9]+:/ { iface = substr($1, 1, length($1) - 1) }
  $1 == "inet" && $2 == gw { print iface; exit }')

if [ -z "$BRIDGE" ]; then
  echo "Nessuna interfaccia con IP $GATEWAY"
  exit 1
fi

echo "IP mitmproxy: $CONTAINER_IP  bridge: $BRIDGE"

# Domini del traffico del Mac da intercettare: il daemon li risolve e li
# carica nella tabella pf <mitm_local>
write_state domains "$(cat domini-mac.txt 2> /dev/null)"

# HTTP/HTTPS dei client LAN, e del Mac verso <mitm_local> → mitmproxy
# (instradato, destinazione invariata; regole route-to generate dal daemon)
write_state route "$BRIDGE $CONTAINER_IP"
wait_anchor "$ANCHOR" "route-to ($BRIDGE $CONTAINER_IP)"
echo "Regola pf mitmproxy applicata"

# Come raggiungere l'interfaccia: dipende da MITM_UI con cui è stato creato
# il container (default console)
if container inspect "$NAME" \
  | jq -e '.[0].configuration.initProcess.environment | index("MITM_UI=web")' > /dev/null; then
  echo "Web UI: http://$NAME:8081"
else
  echo "Console: container exec -it $NAME tmux attach -t mitm   (Ctrl-b d per staccarsi)"
fi

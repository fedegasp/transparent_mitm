#!/bin/bash
set -euo pipefail

# Da eseguire SENZA sudo: container run/inspect richiedono la sessione utente.
# Solo la scrittura degli anchor e il reload di pf sono elevati.
#
# Uso: ./start-mitm.sh
#      MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
# Password della web UI: default 'password'. Serve solo alla creazione del
# container; nei rilanci successivi (container già esistente) viene ignorata.

# I volumi usano percorsi relativi alla directory del progetto
cd "$(dirname "$0")"

# Dominio DNS locale di container (creato una volta con
# `sudo container system dns create test`). Il DNS integrato risolve solo i
# container il cui nome è <nome>.<dominio>: sul Mac la web UI è raggiungibile
# come http://mitmproxy.test:8081, qualunque sia l'IP corrente.
DNS_DOMAIN=test
NAME="mitmproxy.$DNS_DOMAIN"
IMAGE=mitm-transparent
DHCP_NAME=mitm-dhcp
DHCP_IMAGE=mitm-dhcp
ROUTER=192.168.3.1        # router/AP con DHCP relay verso il Mac
MAC_LAN_IP=192.168.3.2    # IP del Mac su en7, destinazione del relay

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

# mitmproxy: crea il container se non esiste, lo avvia se è fermo
if ! start_existing "$NAME"; then
  echo "Creo il container $NAME"
  container run -d --name "$NAME" \
    --cap-add NET_ADMIN \
    --dns-domain "$DNS_DOMAIN" \
    --volume ./mitmproxy:/root/.mitmproxy \
    -e "MITM_WEB_PASSWORD=${MITM_WEB_PASSWORD:-password}" \
    "$IMAGE" > /dev/null
fi

# DHCP (dnsmasq): stesso schema, configurazione e lease in ./dhcp.
# NET_ADMIN è richiesta da dnsmasq per il DHCP (altrimenti esce all'avvio).
if ! start_existing "$DHCP_NAME"; then
  echo "Creo il container $DHCP_NAME"
  container run -d --name "$DHCP_NAME" \
    --cap-add NET_ADMIN \
    --volume ./dhcp:/data \
    "$DHCP_IMAGE" > /dev/null
fi

NET=$(container_net "$NAME")
read -r CONTAINER_IP GATEWAY <<<"$NET"
NET=$(container_net "$DHCP_NAME")
read -r DHCP_IP _ <<<"$NET"

# Bridge vmnet = interfaccia del Mac che ha l'IP del gateway (es. bridge100)
BRIDGE=$(ifconfig | awk -v gw="$GATEWAY" '
  /^[a-z0-9]+:/ { iface = substr($1, 1, length($1) - 1) }
  $1 == "inet" && $2 == gw { print iface; exit }')

if [ -z "$BRIDGE" ]; then
  echo "Nessuna interfaccia con IP $GATEWAY"
  exit 1
fi

echo "IP mitmproxy: $CONTAINER_IP  IP DHCP: $DHCP_IP  bridge: $BRIDGE"

# HTTP/HTTPS dei client LAN → mitmproxy (instradato, destinazione invariata)
sudo tee /etc/pf.anchors/com.mitm.route > /dev/null <<EOF
pass in quick on en7 route-to ($BRIDGE $CONTAINER_IP) inet proto tcp from 192.168.3.0/24 to any port { 80, 443 } keep state
EOF

# Richieste del relay DHCP del router → dnsmasq (qui basta rdr: dnsmasq non
# ha bisogno della destinazione originale)
sudo tee /etc/pf.anchors/com.mitm.dhcp > /dev/null <<EOF
rdr on en7 inet proto udp from $ROUTER to $MAC_LAN_IP port 67 -> $DHCP_IP port 67
EOF

sudo pfctl -a com.mitm.route -f /etc/pf.anchors/com.mitm.route
sudo pfctl -a com.mitm.dhcp -f /etc/pf.anchors/com.mitm.dhcp
sudo pfctl -s info | grep -q 'Status: Enabled' || sudo pfctl -E
echo "Regole pf aggiornate e ricaricate"

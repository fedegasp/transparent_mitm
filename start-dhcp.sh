#!/bin/bash
set -euo pipefail

# Avvia DHCP e DNS della LAN (dnsmasq nel container mitm-dhcp) e le regole pf
# che gli inoltrano le richieste del relay del router e le query DNS dei client
# verso il Mac. Autonomo: non dipende da mitmproxy, e i client navigano via NAT
# del Mac anche senza intercettazione.
#
# Nessun sudo: lo script scrive l'IP del container in /usr/local/var/mitm-pf/dhcp
# e il LaunchDaemon di root com.mitm.pf rigenera l'anchor com.apple/100.mitm.dhcp.
#
# Uso: ./start-dhcp.sh

# Il volume usa un percorso relativo alla directory del progetto
cd "$(dirname "$0")"

DHCP_NAME=mitm-dhcp
DHCP_IMAGE=mitm-dhcp
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/mitm.dhcp

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

# dnsmasq: crea il container se non esiste, lo avvia se è fermo.
# Configurazione e lease in ./dhcp. NET_ADMIN è richiesta da dnsmasq per il
# DHCP (altrimenti esce all'avvio).
if ! start_existing "$DHCP_NAME"; then
  echo "Creo il container $DHCP_NAME"
  container run -d --name "$DHCP_NAME" \
    --cap-add NET_ADMIN \
    --volume ./dhcp:/data \
    "$DHCP_IMAGE" > /dev/null
fi

NET=$(container_net "$DHCP_NAME")
read -r DHCP_IP _ <<<"$NET"

echo "IP DHCP: $DHCP_IP"

# Relay DHCP del router e query DNS dei client → dnsmasq (regole rdr generate
# dal daemon, scritte insieme: basta attendere quella del DNS)
write_state dhcp "$DHCP_IP"
wait_anchor "$ANCHOR" "-> $DHCP_IP port 53"
echo "Regole pf DHCP/DNS applicate"

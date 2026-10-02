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
# I parametri della LAN vengono da mitm.conf: lo script genera dhcp/lan.conf
# per dnsmasq e riavvia il container se è cambiato.
#
# Uso: ./start-dhcp.sh

# Il volume usa un percorso relativo alla directory del progetto
cd "$(dirname "$0")"

DHCP_NAME=mitm-dhcp
DHCP_IMAGE=mitm-dhcp
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/mitm.dhcp
IP_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# Valore di KEY=valore in mitm.conf (come il daemon: il file non viene eseguito)
conf() {
  sed -nE "s/^$1=[\"']?([^\"'#[:space:]]*).*/\1/p" mitm.conf | tail -n 1
}

# Avvia un container esistente se è fermo. Ritorna 1 se il container non esiste.
start_existing() {
  container inspect "$1" > /dev/null 2>&1 || return 1
  if [ "$(container inspect "$1" | jq -r '.[0].status.state')" != "running" ]; then
    echo "Avvio il container $1"
    container start "$1" > /dev/null
  fi
}

# Stampa l'IP del container. Viene assegnato poco dopo l'avvio: attende fino
# a ~10s.
container_ip() {
  local ip
  for _ in $(seq 1 20); do
    ip=$(container inspect "$1" | jq -r '.[0].status.networks[0].ipv4Address // empty' | cut -d'/' -f1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
    sleep 0.5
  done
  echo "Impossibile determinare l'IP del container $1" >&2
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

LAN_IP=$(conf LAN_IP)
MAC_IP=${LAN_IP%/*}
PREFIX=${LAN_IP#*/}
ROUTER_IP=$(conf ROUTER_IP)
DHCP_FIRST=$(conf DHCP_FIRST)
DHCP_LAST=$(conf DHCP_LAST)
DHCP_LEASE=$(conf DHCP_LEASE)
for v in MAC_IP ROUTER_IP DHCP_FIRST DHCP_LAST; do
  [[ ${!v} =~ $IP_RE ]] || { echo "mitm.conf: valore non valido per $v: '${!v}'" >&2; exit 1; }
done
[[ $PREFIX =~ ^[0-9]+$ ]] && [ "$PREFIX" -ge 8 ] && [ "$PREFIX" -le 30 ] ||
  { echo "mitm.conf: LAN_IP deve avere un prefisso (es. 192.168.3.2/24)" >&2; exit 1; }
[[ $DHCP_LEASE =~ ^[0-9]+[mhd]?$ ]] || { echo "mitm.conf: DHCP_LEASE non valido: '$DHCP_LEASE'" >&2; exit 1; }

# Il daemon usa la propria copia di mitm.conf
if ! cmp -s mitm.conf /usr/local/etc/mitm.conf; then
  echo "Attenzione: mitm.conf diverso dalla copia del daemon, rilanciare: sudo ./daemon/install.sh" >&2
fi

# Parametri della LAN per dnsmasq (incluso da dhcp/dnsmasq.conf)
MASK=$(((0xffffffff << (32 - PREFIX)) & 0xffffffff))
NETMASK="$((MASK >> 24 & 255)).$((MASK >> 16 & 255)).$((MASK >> 8 & 255)).$((MASK & 255))"
LAN_CONF="# Generato da start-dhcp.sh da mitm.conf: non modificare
dhcp-range=$DHCP_FIRST,$DHCP_LAST,$NETMASK,$DHCP_LEASE
dhcp-option=option:router,$MAC_IP
dhcp-option=option:dns-server,$MAC_IP
dhcp-proxy=$ROUTER_IP"
LAN_CONF_CHANGED=false
if [ "$(cat dhcp/lan.conf 2> /dev/null)" != "$LAN_CONF" ]; then
  printf '%s\n' "$LAN_CONF" > dhcp/lan.conf
  LAN_CONF_CHANGED=true
fi

# dnsmasq: crea il container se non esiste, lo avvia se è fermo.
# Configurazione e lease in ./dhcp. NET_ADMIN è richiesta da dnsmasq per il
# DHCP (altrimenti esce all'avvio).
if start_existing "$DHCP_NAME"; then
  # dnsmasq legge la configurazione solo all'avvio
  if [ "$LAN_CONF_CHANGED" = true ]; then
    echo "Configurazione LAN cambiata, riavvio il container $DHCP_NAME"
    container stop "$DHCP_NAME" > /dev/null
    container start "$DHCP_NAME" > /dev/null
  fi
else
  echo "Creo il container $DHCP_NAME"
  container run -d --name "$DHCP_NAME" \
    --cap-add NET_ADMIN \
    --volume ./dhcp:/data \
    "$DHCP_IMAGE" > /dev/null
fi

DHCP_IP=$(container_ip "$DHCP_NAME")
echo "IP DHCP: $DHCP_IP"

# Relay DHCP del router e query DNS dei client → dnsmasq (regole rdr generate
# dal daemon, scritte insieme: basta attendere quella del DNS)
write_state dhcp "$DHCP_IP"

# Senza l'interfaccia LAN (cavo scollegato, IP non ancora assegnato) il daemon
# non genera le regole: le aggiunge entro 60s da quando l'IP compare
if ! ifconfig | grep -qE "^[[:space:]]inet $MAC_IP "; then
  echo "Nessuna interfaccia con IP $MAC_IP: regole DHCP/DNS applicate quando la LAN sarà collegata"
  exit 0
fi
wait_anchor "$ANCHOR" "-> $DHCP_IP port 53"
echo "Regole pf DHCP/DNS applicate"

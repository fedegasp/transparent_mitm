#!/bin/bash
set -euo pipefail

# Ferma il DHCP della LAN e rimuove la regola pf del relay. Autonomo: non
# tocca mitmproxy. Senza DHCP i client non ottengono né rinnovano il lease:
# se il Mac smette di fare da gateway, rimettere il router in modalità DHCP server.
#
# Nessun sudo: lo script svuota /usr/local/var/mitm-pf/dhcp e il LaunchDaemon
# di root com.mitm.pf svuota l'anchor com.mitm.dhcp e chiude gli stati relay → Mac.
#
# Uso: ./stop-dhcp.sh         ferma il container e rimuove la regola rdr
#      ./stop-dhcp.sh --rm    rimuove anche il container (es. dopo un rebuild)

DHCP_NAME=mitm-dhcp
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.dhcp

REMOVE=false
for arg in "$@"; do
  case "$arg" in
    --rm) REMOVE=true ;;
    *)    echo "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

# Scrive il file di stato per il daemon (rename atomico)
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

if container inspect "$DHCP_NAME" > /dev/null 2>&1; then
  if [ "$(container inspect "$DHCP_NAME" | jq -r '.[0].status.state')" = "running" ]; then
    echo "Fermo il container $DHCP_NAME"
    container stop "$DHCP_NAME" > /dev/null
  fi
  if [ "$REMOVE" = true ]; then
    echo "Rimuovo il container $DHCP_NAME"
    container rm "$DHCP_NAME" > /dev/null
  fi
else
  echo "Container $DHCP_NAME non presente"
fi

# Regola pf rimossa dal daemon (anche dal file, così un reload di
# /etc/pf.conf non la ripristina)
write_state dhcp ""
wait_anchor "$ANCHOR" ""

echo "DHCP fermo: i client non rinnovano il lease (ripristinare il DHCP server sul router se serve)"

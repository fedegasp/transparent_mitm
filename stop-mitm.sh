#!/bin/bash
set -euo pipefail

# Ferma mitmproxy e rimuove la regola pf route-to. Il DHCP resta attivo: i
# client mantengono il Mac come gateway e navigano via NAT, senza
# intercettazione. Per fermare anche il DHCP: ./stop-dhcp.sh
#
# Nessun sudo: lo script svuota /usr/local/var/mitm-pf/route e il LaunchDaemon
# di root com.mitm.pf svuota l'anchor com.mitm.route e chiude gli stati dei client.
#
# Uso: ./stop-mitm.sh         ferma il container e rimuove la regola route-to
#      ./stop-mitm.sh --rm    rimuove anche il container
#                             (necessario per cambiare password o immagine)

NAME=mitmproxy.test   # deve coincidere con NAME di start-mitm.sh
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.route

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

if container inspect "$NAME" > /dev/null 2>&1; then
  if [ "$(container inspect "$NAME" | jq -r '.[0].status.state')" = "running" ]; then
    echo "Fermo il container $NAME"
    container stop "$NAME" > /dev/null
  fi
  if [ "$REMOVE" = true ]; then
    echo "Rimuovo il container $NAME"
    container rm "$NAME" > /dev/null
  fi
else
  echo "Container $NAME non presente"
fi

# Regola pf rimossa dal daemon (anche dal file, così un reload di
# /etc/pf.conf non la ripristina). Senza questo, il traffico 80/443 dei
# client LAN resterebbe instradato verso un IP non più attivo.
write_state route ""
wait_anchor "$ANCHOR" ""

echo "Intercettazione disattivata: i client LAN escono su Internet via NAT su en0"

#!/bin/bash
set -euo pipefail

# Da eseguire SENZA sudo: container stop/rm richiedono la sessione utente.
# Solo lo svuotamento degli anchor e la pulizia degli stati pf sono elevati.
#
# Uso: ./stop-mitm.sh              ferma mitmproxy e rimuove la regola route-to;
#                                  il DHCP resta attivo (i client navigano via NAT)
#      ./stop-mitm.sh --all        ferma anche il DHCP e rimuove la regola rdr
#      ./stop-mitm.sh --rm [...]   rimuove anche i container fermati
#                                  (necessario per cambiare password o immagine)

NAME=mitmproxy.test   # deve coincidere con NAME di start-mitm.sh
DHCP_NAME=mitm-dhcp

REMOVE=false
ALL=false
for arg in "$@"; do
  case "$arg" in
    --rm)  REMOVE=true ;;
    --all) ALL=true ;;
    *)     echo "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

# Ferma il container se in esecuzione, lo rimuove solo con --rm
stop_container() {
  if container inspect "$1" > /dev/null 2>&1; then
    if [ "$(container inspect "$1" | jq -r '.[0].status.state')" = "running" ]; then
      echo "Fermo il container $1"
      container stop "$1" > /dev/null
    fi
    if [ "$REMOVE" = true ]; then
      echo "Rimuovo il container $1"
      container rm "$1" > /dev/null
    fi
  else
    echo "Container $1 non presente"
  fi
}

stop_container "$NAME"

# Regola pf: file vuoto (così un reload di /etc/pf.conf non la ripristina)
# e anchor svuotato subito. Senza questo, il traffico 80/443 dei client LAN
# resterebbe instradato verso un IP non più attivo.
sudo tee /etc/pf.anchors/com.mitm.route < /dev/null > /dev/null
sudo pfctl -a com.mitm.route -F rules 2> /dev/null

if [ "$ALL" = true ]; then
  stop_container "$DHCP_NAME"
  sudo tee /etc/pf.anchors/com.mitm.dhcp < /dev/null > /dev/null
  sudo pfctl -a com.mitm.dhcp -F nat 2> /dev/null   # rdr = regole di traduzione
fi

# Chiude le connessioni dei client LAN ancora legate alle vecchie regole
sudo pfctl -k 192.168.3.0/24 2> /dev/null

echo "Intercettazione disattivata: i client LAN escono su Internet via NAT su en0"
if [ "$ALL" = true ]; then
  echo "DHCP fermo: i client non rinnovano il lease (ripristinare il DHCP server sul router se serve)"
fi

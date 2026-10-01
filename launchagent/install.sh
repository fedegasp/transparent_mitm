#!/bin/bash
# Installa il LaunchAgent com.mitm.dhcp (DHCP avviato a ogni login).
# Nessun privilegio: va lanciato come utente normale, SENZA sudo.
#   ./launchagent/install.sh             installa e avvia subito
#   ./launchagent/install.sh --remove    disinstalla
set -euo pipefail

cd "$(dirname "$0")"

PLIST=~/Library/LaunchAgents/com.mitm.dhcp.plist
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/com.mitm.dhcp" 2> /dev/null || true

if [ "${1:-}" = "--remove" ]; then
  rm -f "$PLIST"
  echo "LaunchAgent com.mitm.dhcp rimosso"
  exit 0
fi

PROJECT_DIR="$(cd .. && pwd -P)"

# I percorsi finiscono in XML e in un'espressione sed: niente caratteri speciali
for p in "$PROJECT_DIR" "$HOME"; do
  case "$p" in
    *[\&\<\>\|\\]*) echo "Percorso non supportato: $p" >&2; exit 1 ;;
  esac
done

mkdir -p ~/Library/LaunchAgents
sed -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" -e "s|__HOME__|$HOME|g" \
  com.mitm.dhcp.plist > "$PLIST.tmp"
plutil -lint -s "$PLIST.tmp"
mv "$PLIST.tmp" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "LaunchAgent com.mitm.dhcp installato. Log: ~/Library/Logs/mitm-dhcp.log"

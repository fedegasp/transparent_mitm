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

mkdir -p ~/Library/LaunchAgents
cp com.mitm.dhcp.plist "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "LaunchAgent com.mitm.dhcp installato. Log: ~/Library/Logs/mitm-dhcp.log"

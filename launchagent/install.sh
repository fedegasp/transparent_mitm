#!/bin/bash
# Installa i LaunchAgent del progetto (un plist per agente in questa directory):
#   com.mitm.dhcp     DHCP avviato a ogni login
#   com.mitm.domains  applica subito le modifiche di domini-mac.txt
# Nessun privilegio: va lanciato come utente normale, SENZA sudo.
#   ./launchagent/install.sh             installa e avvia subito
#   ./launchagent/install.sh --remove    disinstalla
set -euo pipefail

cd "$(dirname "$0")"

DOMAIN="gui/$(id -u)"
PROJECT_DIR="$(cd .. && pwd -P)"

# I percorsi finiscono in XML e in un'espressione sed: niente caratteri speciali
for p in "$PROJECT_DIR" "$HOME"; do
  case "$p" in
    *[\&\<\>\|\\]*) echo "Percorso non supportato: $p" >&2; exit 1 ;;
  esac
done

mkdir -p ~/Library/LaunchAgents

for src in com.mitm.*.plist; do
  LABEL="${src%.plist}"
  PLIST=~/Library/LaunchAgents/"$src"

  launchctl bootout "$DOMAIN/$LABEL" 2> /dev/null || true

  if [ "${1:-}" = "--remove" ]; then
    rm -f "$PLIST"
    echo "LaunchAgent $LABEL rimosso"
    continue
  fi

  sed -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" -e "s|__HOME__|$HOME|g" \
    "$src" > "$PLIST.tmp"
  plutil -lint -s "$PLIST.tmp"
  mv "$PLIST.tmp" "$PLIST"
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "LaunchAgent $LABEL installato. Log: $(plutil -extract StandardOutPath raw "$PLIST")"
done

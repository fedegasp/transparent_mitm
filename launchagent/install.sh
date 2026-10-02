#!/bin/bash
# Installs the project's LaunchAgents (one plist per agent in this directory):
#   com.mitm.dhcp     DHCP started at every login
#   com.mitm.domains  applies changes to mac-domains.txt immediately
# No privileges: run as a normal user, WITHOUT sudo.
#   ./launchagent/install.sh             install and start now
#   ./launchagent/install.sh --remove    uninstall
set -euo pipefail

cd "$(dirname "$0")"

DOMAIN="gui/$(id -u)"
PROJECT_DIR="$(cd .. && pwd -P)"

# The paths end up in XML and in a sed expression: no special characters
for p in "$PROJECT_DIR" "$HOME"; do
  case "$p" in
    *[\&\<\>\|\\]*) echo "Unsupported path: $p" >&2; exit 1 ;;
  esac
done

mkdir -p ~/Library/LaunchAgents

for src in com.mitm.*.plist; do
  LABEL="${src%.plist}"
  PLIST=~/Library/LaunchAgents/"$src"

  launchctl bootout "$DOMAIN/$LABEL" 2> /dev/null || true

  if [ "${1:-}" = "--remove" ]; then
    rm -f "$PLIST"
    echo "LaunchAgent $LABEL removed"
    continue
  fi

  sed -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" -e "s|__HOME__|$HOME|g" \
    "$src" > "$PLIST.tmp"
  plutil -lint -s "$PLIST.tmp"
  mv "$PLIST.tmp" "$PLIST"
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "LaunchAgent $LABEL installed. Log: $(plutil -extract StandardOutPath raw "$PLIST")"
done

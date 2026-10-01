#!/bin/bash
# Installazione una tantum del LaunchDaemon com.mitm.pf (richiede admin):
#   sudo ./daemon/install.sh
set -euo pipefail

cd "$(dirname "$0")"

USER_NAME="${SUDO_USER:?Lanciare con sudo da utente normale}"

# Script eseguito da root: in una directory di root, non modificabile dall'utente
install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 755 mitm-pf-apply /usr/local/libexec/mitm-pf-apply

# Directory dei file di stato: scrivibile dall'utente, letta dal daemon
install -d -o "$USER_NAME" -g staff -m 755 /usr/local/var/mitm-pf

install -o root -g wheel -m 644 com.mitm.pf.plist /Library/LaunchDaemons/com.mitm.pf.plist

launchctl bootout system/com.mitm.pf 2> /dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.mitm.pf.plist

echo "LaunchDaemon com.mitm.pf installato. Log: /var/log/mitm-pf.log"

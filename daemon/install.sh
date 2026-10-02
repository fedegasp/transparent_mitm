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

# Regole attuali negli anchor com.apple/100.mitm.*, prima di togliere quelle
# della versione precedente: nessuna interruzione di NAT e DHCP
/usr/local/libexec/mitm-pf-apply >> /var/log/mitm-pf.log 2>&1

# Versione precedente: anchor com.mitm.* dichiarati in /etc/pf.conf. Toglie le
# righe (il file torna quello di sistema) e svuota gli anchor senza ricaricare
# /etc/pf.conf: un reload completo rimuoverebbe gli anchor di InternetSharing.
# I riferimenti ormai vuoti nel ruleset principale spariscono al reboot.
if grep -q '"com\.mitm\.' /etc/pf.conf; then
  cp /etc/pf.conf /etc/pf.conf.mitm-bak
  sed -i '' '/"com\.mitm\./d' /etc/pf.conf
  if ! pfctl -nf /etc/pf.conf 2> /dev/null; then
    cp /etc/pf.conf.mitm-bak /etc/pf.conf
    echo "/etc/pf.conf senza com.mitm.* non valido: ripristinato" >&2
    exit 1
  fi
  echo "Tolti gli anchor com.mitm.* da /etc/pf.conf (copia in /etc/pf.conf.mitm-bak)"
fi
for a in com.mitm.nat com.mitm.dhcp com.mitm.route; do
  pfctl -q -a "$a" -F nat 2> /dev/null || true
  pfctl -q -a "$a" -F rules 2> /dev/null || true
  pfctl -q -a "$a" -F Tables 2> /dev/null || true
done
rm -f /etc/pf.anchors/com.mitm.*

launchctl bootstrap system /Library/LaunchDaemons/com.mitm.pf.plist

echo "LaunchDaemon com.mitm.pf installato. Log: /var/log/mitm-pf.log"

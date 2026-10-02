#!/bin/bash
# Parte di root dell'installazione, lanciata da ./mitm install (o uninstall)
# con un solo sudo:
#   - LaunchDaemon com.mitm.pf, che applica le regole pf
#   - copia di root di mitm.conf, letta dal daemon
#   - IP forwarding (il Mac fa da gateway ai client LAN)
#   - dominio DNS locale di container (.test), per http://mitmproxy.test:8081
# Idempotente. Uso diretto: sudo ./daemon/install.sh [--remove]
set -euo pipefail

cd "$(dirname "$0")"

USER_NAME="${SUDO_USER:?Lanciare con sudo da utente normale}"
# Deve coincidere con DNS_DOMAIN di ./mitm
DNS_DOMAIN=test
# Sotto sudo il PATH può non includere /usr/local/bin
CONTAINER=$(command -v container || echo /usr/local/bin/container)

# Svuota gli anchor pf $@ (traduzioni, filtro e tabelle)
flush_anchors() {
  local a
  for a in "$@"; do
    pfctl -q -a "$a" -F nat 2> /dev/null || true
    pfctl -q -a "$a" -F rules 2> /dev/null || true
    pfctl -q -a "$a" -F Tables 2> /dev/null || true
  done
}

if [ "${1:-}" = --remove ]; then
  launchctl bootout system/com.mitm.pf 2> /dev/null || true
  flush_anchors com.apple/100.mitm.nat com.apple/100.mitm.dhcp com.apple/100.mitm.route
  rm -f /Library/LaunchDaemons/com.mitm.pf.plist /usr/local/libexec/mitm-pf-apply \
    /usr/local/etc/mitm.conf /etc/pf.anchors/mitm.*
  rm -rf /usr/local/var/mitm-pf
  echo "LaunchDaemon com.mitm.pf e regole pf rimossi."
  # Impostazioni di sistema che possono servire anche ad altro: restano
  echo "Restano attivi, da togliere a mano se non servono:"
  echo "  - IP forwarding: riga net.inet.ip.forwarding=1 in /etc/sysctl.conf, e sudo sysctl -w net.inet.ip.forwarding=0"
  echo "  - dominio .$DNS_DOMAIN di container: sudo container system dns delete $DNS_DOMAIN"
  exit 0
fi

# Script eseguito da root: in una directory di root, non modificabile dall'utente
install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 755 mitm-pf-apply /usr/local/libexec/mitm-pf-apply

# Directory dei file di stato: scrivibile dall'utente, letta dal daemon
install -d -o "$USER_NAME" -g staff -m 755 /usr/local/var/mitm-pf

install -o root -g wheel -m 644 com.mitm.pf.plist /Library/LaunchDaemons/com.mitm.pf.plist

# Configurazione della LAN: copia di root, il daemon non legge file
# modificabili dall'utente come configurazione
for key in LAN_IP ROUTER_IP; do
  grep -qE "^$key=" ../mitm.conf || { echo "mitm.conf: manca $key" >&2; exit 1; }
done
install -d -o root -g wheel -m 755 /usr/local/etc
install -o root -g wheel -m 644 ../mitm.conf /usr/local/etc/mitm.conf

# IP forwarding, subito e ai riavvii
sysctl -w net.inet.ip.forwarding=1 > /dev/null
if ! grep -qx 'net.inet.ip.forwarding=1' /etc/sysctl.conf 2> /dev/null; then
  echo 'net.inet.ip.forwarding=1' >> /etc/sysctl.conf
  echo "IP forwarding attivato in /etc/sysctl.conf"
fi

# Dominio DNS locale: crea /etc/resolver/containerization.$DNS_DOMAIN
if [ ! -f "/etc/resolver/containerization.$DNS_DOMAIN" ]; then
  "$CONTAINER" system dns create "$DNS_DOMAIN" ||
    echo "Attenzione: dominio .$DNS_DOMAIN non creato, lanciare sudo container system dns create $DNS_DOMAIN" >&2
fi

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
flush_anchors com.mitm.nat com.mitm.dhcp com.mitm.route
rm -f /etc/pf.anchors/com.mitm.*

launchctl bootstrap system /Library/LaunchDaemons/com.mitm.pf.plist

echo "LaunchDaemon com.mitm.pf installato. Log: /var/log/mitm-pf.log"

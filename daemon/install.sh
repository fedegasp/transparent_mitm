#!/bin/bash
# Root part of the installation, run by ./mitm install (or uninstall) with a
# single sudo:
#   - LaunchDaemon com.mitm.pf, which applies the pf rules
#   - root copy of mitm.conf, read by the daemon
#   - IP forwarding (the Mac acts as gateway for the LAN clients)
#   - local DNS domain of container (.test), for http://mitmproxy.test:8081
# Idempotent. Direct use: sudo ./daemon/install.sh [--remove]
set -euo pipefail

cd "$(dirname "$0")"

USER_NAME="${SUDO_USER:?Run with sudo as a normal user}"
# Must match DNS_DOMAIN in ./mitm
DNS_DOMAIN=test
# Under sudo the PATH may not include /usr/local/bin
CONTAINER=$(command -v container || echo /usr/local/bin/container)

# Flushes the pf anchors $@ (translation, filter and tables)
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
  echo "LaunchDaemon com.mitm.pf and pf rules removed."
  # System settings that may be useful for other things too: left in place
  echo "Still active, remove them by hand if not needed:"
  echo "  - IP forwarding: line net.inet.ip.forwarding=1 in /etc/sysctl.conf, and sudo sysctl -w net.inet.ip.forwarding=0"
  echo "  - container domain .$DNS_DOMAIN: sudo container system dns delete $DNS_DOMAIN"
  exit 0
fi

# Script run by root: in a root-owned directory, not modifiable by the user
install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 755 mitm-pf-apply /usr/local/libexec/mitm-pf-apply

# State file directory: writable by the user, read by the daemon
install -d -o "$USER_NAME" -g staff -m 755 /usr/local/var/mitm-pf

install -o root -g wheel -m 644 com.mitm.pf.plist /Library/LaunchDaemons/com.mitm.pf.plist

# LAN configuration: root copy, the daemon does not read user-modifiable
# files as configuration
for key in LAN_IP ROUTER_IP; do
  grep -qE "^$key=" ../mitm.conf || { echo "mitm.conf: $key missing" >&2; exit 1; }
done
install -d -o root -g wheel -m 755 /usr/local/etc
install -o root -g wheel -m 644 ../mitm.conf /usr/local/etc/mitm.conf

# IP forwarding, now and across reboots
sysctl -w net.inet.ip.forwarding=1 > /dev/null
if ! grep -qx 'net.inet.ip.forwarding=1' /etc/sysctl.conf 2> /dev/null; then
  echo 'net.inet.ip.forwarding=1' >> /etc/sysctl.conf
  echo "IP forwarding enabled in /etc/sysctl.conf"
fi

# Local DNS domain: creates /etc/resolver/containerization.$DNS_DOMAIN
if [ ! -f "/etc/resolver/containerization.$DNS_DOMAIN" ]; then
  "$CONTAINER" system dns create "$DNS_DOMAIN" ||
    echo "Warning: domain .$DNS_DOMAIN not created, run sudo container system dns create $DNS_DOMAIN" >&2
fi

launchctl bootout system/com.mitm.pf 2> /dev/null || true

# Current rules in the com.apple/100.mitm.* anchors, before removing those of
# the previous version: no interruption of NAT and DHCP
/usr/local/libexec/mitm-pf-apply >> /var/log/mitm-pf.log 2>&1

# Previous version: com.mitm.* anchors declared in /etc/pf.conf. Removes the
# lines (the file goes back to the system one) and flushes the anchors without
# reloading /etc/pf.conf: a full reload would remove the InternetSharing
# anchors. The now-empty references in the main ruleset disappear at reboot.
if grep -q '"com\.mitm\.' /etc/pf.conf; then
  cp /etc/pf.conf /etc/pf.conf.mitm-bak
  sed -i '' '/"com\.mitm\./d' /etc/pf.conf
  if ! pfctl -nf /etc/pf.conf 2> /dev/null; then
    cp /etc/pf.conf.mitm-bak /etc/pf.conf
    echo "/etc/pf.conf without com.mitm.* is invalid: restored" >&2
    exit 1
  fi
  echo "Removed the com.mitm.* anchors from /etc/pf.conf (copy in /etc/pf.conf.mitm-bak)"
fi
flush_anchors com.mitm.nat com.mitm.dhcp com.mitm.route
rm -f /etc/pf.anchors/com.mitm.*

launchctl bootstrap system /Library/LaunchDaemons/com.mitm.pf.plist

echo "LaunchDaemon com.mitm.pf installed. Log: /var/log/mitm-pf.log"

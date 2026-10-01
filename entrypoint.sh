#!/bin/sh
set -e

# Redirect locale: tutto ciò che arriva su 80/443 (instradato da pf via route-to,
# con destinazione originale intatta) viene deviato verso mitmproxy in locale.
# Questo passaggio è quello che crea la voce di conntrack che mitmproxy legge
# per recuperare l'indirizzo originale.
iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING -s 192.168.3.0/24 -p tcp --dport 80  -j REDIRECT --to-port 7070
iptables -t nat -A PREROUTING -s 192.168.3.0/24 -p tcp --dport 443 -j REDIRECT --to-port 7070

# Da qui in poi un'uscita di mitmweb non deve terminare lo script
set +e

# Password della web UI da variabile d'ambiente (start-mitm.sh la passa sempre,
# default 'password'); se assente mitmweb genera un token casuale, visibile in
# `container logs mitmproxy.test`
while true; do
  mitmweb \
    --mode transparent \
    --showhost \
    --listen-host 0.0.0.0 \
    --listen-port 7070 \
    --web-host 0.0.0.0 \
    --web-port 8081 \
    --set block_global=false \
    ${MITM_WEB_PASSWORD:+--set web_password="$MITM_WEB_PASSWORD"}
  echo "mitmweb terminato, riavvio tra 1s..."
  sleep 1
done

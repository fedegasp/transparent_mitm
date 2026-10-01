# Architettura: Proxy trasparente LAN → mitmproxy in container (macOS)

## Obiettivo

Intercettare il traffico HTTP/HTTPS di dispositivi collegati alla LAN fisica del Mac, instradandolo verso `mitmproxy` in esecuzione dentro una VM Linux gestita da Apple `container`, aggirando le restrizioni del profilo MDM enterprise che impediscono l'uso diretto di `pf`/`sysctl`/Application Firewall per processi host.

## Perché questo approccio

- Il Mac è gestito da MDM con **Digital Guardian** (`com.digitalguardian.webproxy`, Network Extension) e **BeyondTrust** (Endpoint Security + Privilege Management), oltre a **Microsoft Defender**.
- L'**Application Firewall di macOS** è gestito centralmente ("Firewall settings cannot be modified from command line on managed Mac computers") e blocca silenziosamente le connessioni in ingresso verso processi non in whitelist (mitmproxy in ascolto sul Mac veniva droppato: SYN inviato, mai risposto).
- Il traffico **forwardato/instradato** dal kernel (non generato da un processo host) non passa dagli stessi filtri per-processo — da qui l'idea di spostare mitmproxy dentro una VM Linux (`container`), che dal punto di vista del Mac è "un altro host" di rete, non un processo locale sorvegliato.
- Il bridging diretto di `container` verso un'interfaccia fisica (es. `en7`) **non è disponibile** nella release stabile (PR Apple `#1622` ancora aperta) — quindi il container resta sulla rete `default` di `container` (NAT vmnet, `192.168.64.0/24`), raggiunta dal Mac tramite instradamento esplicito via `pf`.

## Interfacce di rete

| Interfaccia | Ruolo | Subnet |
|---|---|---|
| `en0` | WiFi, verso Internet | dinamica (`192.168.1.0/24` casa, `10.0.0.0/24` ufficio) |
| `en7` | LAN fisica, client di test | `192.168.3.0/24`, Mac = `192.168.3.2`, router/AP = `192.168.3.1` |
| `bridge100` | Bridge vmnet della rete `default` di `container` | `192.168.64.0/24`, gateway (Mac) `192.168.64.1` |

Router e access point della LAN sono **lo stesso dispositivo** (Zyxel brandizzato Wind, `192.168.3.1`). Il suo DHCP server non permette di impostare un gateway diverso da sé stesso, quindi è configurato in **DHCP relay** verso il Mac: il DHCP vero lo fa `dnsmasq` in un container (punto 6), che assegna ai client il Mac (`192.168.3.2`) come gateway.

I container usano la rete `default`: **non serve creare una rete dedicata**. Subnet e gateway si verificano con:
```bash
container network inspect default | jq '.[0].status'
```
Il nome del bridge (`bridge100`) non è garantito stabile: `start-mitm.sh` (punto 3) lo ricava a runtime dall'interfaccia che ha l'IP del gateway.

## Flusso del traffico

```
client LAN (192.168.3.x) ──en7──▶ Mac pf: route-to (bridge100 <IP_CONTAINER>)   [dst IP invariato]
                                       │
                                       ▼
                     container: iptables PREROUTING REDIRECT → :7070 (mitmweb transparent)
                                       │  SO_ORIGINAL_DST → destinazione originale
                                       ▼
                     mitmweb ──▶ gateway 192.168.64.1 ──▶ NAT vmnet ──en0──▶ Internet

altro traffico LAN (DNS, non-HTTP/S) ──en7──▶ Mac: nat on en0 (anchor com.mitm.nat) ──▶ Internet

DHCP:
client ──broadcast──▶ router 192.168.3.1 (relay, giaddr=192.168.3.1)
                          │ unicast UDP → 192.168.3.2:67
                          ▼
                     Mac pf: rdr (anchor com.mitm.dhcp) → <IP_DHCP>:67
                          ▼
                     container mitm-dhcp (dnsmasq) ──risposta──▶ Mac (src riscritto in 192.168.3.2) ──▶ router ──▶ client
                     offre: IP 192.168.3.100–199, gateway 192.168.3.2, DNS 1.1.1.1/1.0.0.1/192.168.3.2, server-id 192.168.3.1
```

Le risposte del container verso `192.168.3.x` tornano al Mac via il gateway `192.168.64.1` e vengono inoltrate su `en7`: gli stati pf su macOS sono *floating*, quindi lo stato creato su `en7` copre anche il ritorno su `bridge100`.

Per il DHCP basta un `rdr` (a differenza di mitmproxy, `dnsmasq` non ha bisogno della destinazione originale). Il pacchetto è inoltrato dal kernel verso il container, non consegnato a un processo del Mac, quindi l'Application Firewall non interviene (stesso principio del `route-to`). La regola è ristretta a `on en7 from 192.168.3.1`: il DHCP interno di vmnet su `bridge100` non viene toccato.

## Componenti

### 1. macOS — IP forwarding

```bash
sudo sysctl -w net.inet.ip.forwarding=1
```
Per renderlo persistente va aggiunto a `/etc/sysctl.conf` (oggi il file **non** lo contiene):
```bash
echo 'net.inet.ip.forwarding=1' | sudo tee -a /etc/sysctl.conf
```

### 2. macOS — `pf`: instradamento (non NAT) verso il container

Il punto chiave dell'architettura: il traffico verso porta 80/443 **non viene tradotto** (niente `rdr`) ma solo **instradato** (`route-to`) verso l'IP del container, mantenendo intatto l'indirizzo di destinazione originale. Questo è necessario perché mitmproxy in modalità transparent su Linux recupera la destinazione originale via `getsockopt(SO_ORIGINAL_DST)`, che richiede che il NAT/redirect avvenga **nello stesso kernel** in cui gira mitmproxy (quindi dentro il container, non su macOS).

`/etc/pf.conf` (anchor rilevanti; copia di riferimento completa in [pf.conf](pf.conf)). Ordine importante: `com.mitm.route` prima di `com.apple/*` per garantire priorità con `quick`, e `com.mitm.dhcp` prima di `rdr-anchor "com.apple/*"` (per le traduzioni vince la prima regola che corrisponde):
```
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
nat-anchor "com.mitm.nat"
rdr-anchor "com.mitm.dhcp"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.mitm.route"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
load anchor "com.mitm.nat" from "/etc/pf.anchors/com.mitm.nat"
load anchor "com.mitm.route" from "/etc/pf.anchors/com.mitm.route"
load anchor "com.mitm.dhcp" from "/etc/pf.anchors/com.mitm.dhcp"
```
Il DHCP ha un **anchor separato** (`com.mitm.dhcp`, dichiarato come `rdr-anchor`: le regole `rdr` in un anchor dichiarato solo con `anchor` verrebbero ignorate). Così DHCP e mitmproxy hanno ciascuno il proprio anchor e i propri script (punti 3 e 8): `stop-mitm.sh` rimuove l'intercettazione senza interrompere il DHCP.

`/etc/pf.anchors/com.mitm.nat` (NAT verso Internet per il resto del traffico LAN, non HTTP/S, e per l'egress dei container):
```
nat on en0 inet from 192.168.3.0/24 to any -> (en0)
nat on en0 inet from 192.168.64.0/24 to any -> (en0)
```
La seconda riga **è necessaria**: il NAT della rete dei container lo fa normalmente `InternetSharing` (avviato da `container-network-vmnet`), inserendo i propri anchor pf nel ruleset principale a runtime. Un reload completo (`pfctl -f /etc/pf.conf`) li rimuove, e da quel momento i container non escono più su Internet (mitmproxy riceve le connessioni dei client ma va in timeout verso i server). Con la regola nel nostro anchor l'egress non dipende più da quegli anchor; se sono presenti, vale la prima regola che corrisponde, niente doppio NAT.

`/etc/pf.anchors/com.mitm.route` (rigenerato da `start-mitm.sh`, svuotato da `stop-mitm.sh` — l'IP del container non è fisso):
```
pass in quick on en7 route-to (bridge100 <IP_CONTAINER>) inet proto tcp from 192.168.3.0/24 to any port { 80, 443 } keep state
```
> Nota: l'interfaccia nel `route-to` è quella **bridge di vmnet** (`bridge100`), non `en7`.

`/etc/pf.anchors/com.mitm.dhcp` (rigenerato da `start-dhcp.sh`, svuotato da `stop-dhcp.sh` — anche l'IP del container DHCP non è fisso):
```
rdr on en7 inet proto udp from 192.168.3.1 to 192.168.3.2 port 67 -> <IP_DHCP> port 67
```

**pf su macOS non è abilitato di default**: `pfctl -f` carica le regole ma non le attiva. Setup una tantum dopo aver modificato `/etc/pf.conf` (il file dell'anchor DHCP deve esistere, altrimenti il caricamento fallisce):
```bash
sudo cp /etc/pf.conf /etc/pf.conf.bak
sudo cp pf.conf /etc/pf.conf
sudo touch /etc/pf.anchors/com.mitm.dhcp
sudo pfctl -f /etc/pf.conf
sudo pfctl -E
```
Il reload completo rimuove gli anchor di `InternetSharing` (vedi sopra): va fatto **solo dopo** aver aggiornato `com.mitm.nat` con la riga per `192.168.64.0/24`.

Dopo il setup iniziale gli anchor `com.mitm.route` e `com.mitm.dhcp` li gestisce il LaunchDaemon `com.mitm.pf` (punto 9), che ricarica **solo il singolo anchor** (`pfctl -a <anchor> -f ...`) e non l'intero `/etc/pf.conf`: ricaricare il ruleset principale può rimuovere gli anchor inseriti dinamicamente dai servizi di sistema (vedi commento in testa a `/etc/pf.conf`).

### 3. Script di avvio (`start-dhcp.sh`, `start-mitm.sh`)

L'IP dei container cambia a ogni riavvio (non esiste un flag per fissarlo — `container run --network` supporta solo `mac`/`mtu`, non `ip`): gli script leggono l'IP corrente e rigenerano l'anchor pf corrispondente.

DHCP e mitmproxy hanno **script separati**, con una dipendenza a senso unico:
- `start-dhcp.sh` è **autonomo**: gestisce solo `mitm-dhcp` e l'anchor `com.mitm.dhcp`, non sa nulla di mitmproxy. Con il solo DHCP attivo i client hanno il Mac come gateway e navigano via NAT, senza intercettazione.
- `start-mitm.sh` **dipende dal DHCP**: come primo passo lancia `./start-dhcp.sh`, poi gestisce `mitmproxy.test` e l'anchor `com.mitm.route`.

Entrambi sono **idempotenti** e si possono rilanciare in qualsiasi momento:
- container **inesistente** → lo crea con `container run` (per mitmproxy è l'unico momento in cui viene letta `MITM_WEB_PASSWORD`, default `password`);
- container **fermo** → `container start`;
- container **in esecuzione** → nessuna azione sul container.

Poi attendono che l'IP sia assegnato (fino a ~10s), e rigenerano e ricaricano il proprio anchor; `start-mitm.sh` ricava anche il bridge.

Vanno eseguiti **senza sudo** (`container run/inspect` richiedono la sessione utente) e non chiedono privilegi: invece di scrivere gli anchor, scrivono l'IP corrente in un file di stato in `/usr/local/var/mitm-pf/` (`dhcp` / `route`) e attendono (fino a ~10s) che il LaunchDaemon di root `com.mitm.pf` abbia applicato la regola (punto 9). Si portano nella propria directory (`cd "$(dirname "$0")"`), quindi i volumi relativi (`./mitmproxy`, `./dhcp`) funzionano da qualunque directory li si lanci.

Le funzioni comuni (`start_existing`, `container_net`, `write_state`, `wait_anchor`) sono **duplicate** nei due script invece che in un file condiviso: così `start-dhcp.sh` non dipende da nient'altro del progetto.

`start-dhcp.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Avvia il DHCP della LAN (dnsmasq nel container mitm-dhcp) e la regola pf che
# gli inoltra le richieste del relay del router. Autonomo: non dipende da
# mitmproxy, e i client navigano via NAT del Mac anche senza intercettazione.
#
# Nessun sudo: lo script scrive l'IP del container in /usr/local/var/mitm-pf/dhcp
# e il LaunchDaemon di root com.mitm.pf rigenera l'anchor com.mitm.dhcp.
#
# Uso: ./start-dhcp.sh

# Il volume usa un percorso relativo alla directory del progetto
cd "$(dirname "$0")"

DHCP_NAME=mitm-dhcp
DHCP_IMAGE=mitm-dhcp
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.dhcp

# Avvia un container esistente se è fermo. Ritorna 1 se il container non esiste.
start_existing() {
  container inspect "$1" > /dev/null 2>&1 || return 1
  if [ "$(container inspect "$1" | jq -r '.[0].status.state')" != "running" ]; then
    echo "Avvio il container $1"
    container start "$1" > /dev/null
  fi
}

# Stampa "IP GATEWAY" del container. L'IP viene assegnato poco dopo l'avvio:
# attende fino a ~10s.
container_net() {
  local info ip gw
  for _ in $(seq 1 20); do
    info=$(container inspect "$1")
    ip=$(jq -r '.[0].status.networks[0].ipv4Address // empty' <<<"$info" | cut -d'/' -f1)
    gw=$(jq -r '.[0].status.networks[0].ipv4Gateway // empty' <<<"$info")
    if [ -n "$ip" ] && [ -n "$gw" ]; then
      echo "$ip $gw"
      return 0
    fi
    sleep 0.5
  done
  echo "Impossibile determinare IP/gateway del container $1" >&2
  return 1
}

# Scrive il file di stato per il daemon (rename atomico: il daemon, attivato
# da WatchPaths sulla directory, non legge mai un file scritto a metà)
write_state() {
  printf '%s\n' "$2" > "$STATE/.$1.tmp"
  mv "$STATE/.$1.tmp" "$STATE/$1"
}

# Attende che il daemon abbia applicato la regola: anchor che contiene $2,
# o vuoto se $2 è vuoto. Fino a ~10s.
wait_anchor() {
  for _ in $(seq 1 20); do
    if [ -z "$2" ]; then
      [ ! -s "$1" ] && return 0
    else
      grep -qF -- "$2" "$1" 2> /dev/null && return 0
    fi
    sleep 0.5
  done
  echo "Il daemon com.mitm.pf non ha aggiornato $1: vedi /var/log/mitm-pf.log" >&2
  return 1
}

# dnsmasq: crea il container se non esiste, lo avvia se è fermo.
# Configurazione e lease in ./dhcp. NET_ADMIN è richiesta da dnsmasq per il
# DHCP (altrimenti esce all'avvio).
if ! start_existing "$DHCP_NAME"; then
  echo "Creo il container $DHCP_NAME"
  container run -d --name "$DHCP_NAME" \
    --cap-add NET_ADMIN \
    --volume ./dhcp:/data \
    "$DHCP_IMAGE" > /dev/null
fi

NET=$(container_net "$DHCP_NAME")
read -r DHCP_IP _ <<<"$NET"

echo "IP DHCP: $DHCP_IP"

# Richieste del relay DHCP del router → dnsmasq (regola rdr generata dal daemon)
write_state dhcp "$DHCP_IP"
wait_anchor "$ANCHOR" "-> $DHCP_IP port 67"
echo "Regola pf DHCP applicata"
```

`start-mitm.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Avvia mitmproxy (container mitmproxy.test) e la regola pf che gli instrada
# l'HTTP/HTTPS dei client LAN. Dipende dal DHCP (che assegna il Mac come
# gateway ai client): lo avvia prima con start-dhcp.sh, idempotente.
#
# Nessun sudo: lo script scrive bridge e IP del container in
# /usr/local/var/mitm-pf/route e il LaunchDaemon di root com.mitm.pf rigenera
# l'anchor com.mitm.route.
#
# Uso: ./start-mitm.sh
#      MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
# Password della web UI: default 'password'. Serve solo alla creazione del
# container; nei rilanci successivi (container già esistente) viene ignorata.

# Il volume usa un percorso relativo alla directory del progetto
cd "$(dirname "$0")"

# Dipendenza: DHCP attivo
./start-dhcp.sh

# Dominio DNS locale di container (creato una volta con
# `sudo container system dns create test`). Il DNS integrato risolve solo i
# container il cui nome è <nome>.<dominio>: sul Mac la web UI è raggiungibile
# come http://mitmproxy.test:8081, qualunque sia l'IP corrente.
DNS_DOMAIN=test
NAME="mitmproxy.$DNS_DOMAIN"
IMAGE=mitm-transparent
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.route

# Avvia un container esistente se è fermo. Ritorna 1 se il container non esiste.
start_existing() {
  container inspect "$1" > /dev/null 2>&1 || return 1
  if [ "$(container inspect "$1" | jq -r '.[0].status.state')" != "running" ]; then
    echo "Avvio il container $1"
    container start "$1" > /dev/null
  fi
}

# Stampa "IP GATEWAY" del container. L'IP viene assegnato poco dopo l'avvio:
# attende fino a ~10s.
container_net() {
  local info ip gw
  for _ in $(seq 1 20); do
    info=$(container inspect "$1")
    ip=$(jq -r '.[0].status.networks[0].ipv4Address // empty' <<<"$info" | cut -d'/' -f1)
    gw=$(jq -r '.[0].status.networks[0].ipv4Gateway // empty' <<<"$info")
    if [ -n "$ip" ] && [ -n "$gw" ]; then
      echo "$ip $gw"
      return 0
    fi
    sleep 0.5
  done
  echo "Impossibile determinare IP/gateway del container $1" >&2
  return 1
}

# Scrive il file di stato per il daemon (rename atomico: il daemon, attivato
# da WatchPaths sulla directory, non legge mai un file scritto a metà)
write_state() {
  printf '%s\n' "$2" > "$STATE/.$1.tmp"
  mv "$STATE/.$1.tmp" "$STATE/$1"
}

# Attende che il daemon abbia applicato la regola: anchor che contiene $2,
# o vuoto se $2 è vuoto. Fino a ~10s.
wait_anchor() {
  for _ in $(seq 1 20); do
    if [ -z "$2" ]; then
      [ ! -s "$1" ] && return 0
    else
      grep -qF -- "$2" "$1" 2> /dev/null && return 0
    fi
    sleep 0.5
  done
  echo "Il daemon com.mitm.pf non ha aggiornato $1: vedi /var/log/mitm-pf.log" >&2
  return 1
}

# mitmproxy: crea il container se non esiste, lo avvia se è fermo
if ! start_existing "$NAME"; then
  echo "Creo il container $NAME"
  container run -d --name "$NAME" \
    --cap-add NET_ADMIN \
    --dns-domain "$DNS_DOMAIN" \
    --volume ./mitmproxy:/root/.mitmproxy \
    -e "MITM_WEB_PASSWORD=${MITM_WEB_PASSWORD:-password}" \
    "$IMAGE" > /dev/null
fi

NET=$(container_net "$NAME")
read -r CONTAINER_IP GATEWAY <<<"$NET"

# Bridge vmnet = interfaccia del Mac che ha l'IP del gateway (es. bridge100)
BRIDGE=$(ifconfig | awk -v gw="$GATEWAY" '
  /^[a-z0-9]+:/ { iface = substr($1, 1, length($1) - 1) }
  $1 == "inet" && $2 == gw { print iface; exit }')

if [ -z "$BRIDGE" ]; then
  echo "Nessuna interfaccia con IP $GATEWAY"
  exit 1
fi

echo "IP mitmproxy: $CONTAINER_IP  bridge: $BRIDGE"

# HTTP/HTTPS dei client LAN → mitmproxy (instradato, destinazione invariata;
# regola route-to generata dal daemon)
write_state route "$BRIDGE $CONTAINER_IP"
wait_anchor "$ANCHOR" "route-to ($BRIDGE $CONTAINER_IP)"
echo "Regola pf mitmproxy applicata"
```

### 4. Container — immagine (`Containerfile`)

Base `python:3.13-slim-bookworm` e **non** `debian:bookworm-slim`: Debian bookworm ha Python 3.11, e le versioni recenti di mitmproxy richiedono Python ≥ 3.12 (dalla 11.1). Con `pip install mitmproxy` su bookworm si ottiene in silenzio la **11.0.2**, che non ha l'opzione `web_password` (mitmweb esce con errore) e manca della protezione della web UI introdotta nelle versioni successive. La versione è fissata per build riproducibili.

```dockerfile
FROM python:3.13-slim-bookworm

ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    tini \
    curl \
    procps \
    dnsutils \
    iproute2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "mitmproxy==12.2.3"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
```

`container build` trova il `Containerfile` automaticamente (altrimenti `-f Containerfile`).

### 5. Container — entrypoint (`entrypoint.sh`)

Punti critici:
- **`iptables -t nat -F PREROUTING` prima di ri-aggiungere le regole**, per evitare duplicati a ogni riavvio.
- **Match ristretto a `-s 192.168.3.0/24`**: limita il REDIRECT al solo traffico dei client LAN. Senza questo filtro si era osservato un timeout totale dell'egress del container verso Internet (vedi cronologia, punto 9).
- **`tini` come PID 1** (via `ENTRYPOINT`) e **mitmweb in un ciclo `while`**: mitmweb è un processo figlio che può essere killato/riavviato senza fermare il container. Senza il ciclo, all'uscita di mitmweb termina l'entrypoint e con esso il container.
- **`block_global=false`**: `block_global` blocca le connessioni da **client** con IP pubblico (non riguarda la destinazione). I client LAN `192.168.3.x` sono privati, quindi non è strettamente necessario; lo si tiene per non avere sorprese se un client arriva con IP non privato.
- **Password della web UI da variabile d'ambiente** (`MITM_WEB_PASSWORD`, passata con `container run -e`), non scritta nell'immagine. `start-mitm.sh` la passa sempre, con default `password` se non impostata. Se la variabile mancasse del tutto (container avviato a mano), mitmweb genera un token casuale stampato nei log (`container logs mitmproxy.test`). La web UI è raggiungibile anche dai client LAN (il Mac inoltra `192.168.3.0/24` → `192.168.64.0/24`): con la password di default chiunque sulla LAN può accedervi.

```bash
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
```

### 6. Container DHCP (`dhcp/`)

Container separato `mitm-dhcp` con `dnsmasq`, raggiunto dal relay del router tramite l'`rdr` di pf (vedi *Flusso del traffico*). È separato da `mitmproxy.test` perché ha un ciclo di vita diverso, con script propri (`start-dhcp.sh` / `stop-dhcp.sh`) che non dipendono da mitmproxy: `stop-mitm.sh` ferma l'intercettazione ma lascia attivo il DHCP, così i client continuano a ricevere/rinnovare il lease e navigano via NAT del Mac.

Alternative scartate:
- **DHCP server su macOS** (`dnsmasq`/`kea` da brew): processo in ascolto sul Mac, bloccato dall'Application Firewall come mitmproxy (cronologia, punto 2).
- **`bootpd` di macOS** (`/etc/bootpd.plist`): lo stesso file è usato da Condivisione Internet/vmnet, rischio di interferire con la rete dei container.
- **Relay puntato direttamente all'IP del container**: l'IP cambia a ogni riavvio, e il router invierebbe le richieste al proprio gateway, non al Mac.

`dhcp/Containerfile`:
```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq-base \
    tini \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Configurazione e lease stanno nel volume /data (./dhcp sul Mac).
# --user=root: dnsmasq non deve cedere i privilegi, altrimenti non può scrivere
# il file dei lease nel volume montato.
ENTRYPOINT ["/usr/bin/tini", "--", "dnsmasq", \
    "--keep-in-foreground", \
    "--log-facility=-", \
    "--user=root", \
    "--conf-file=/data/dnsmasq.conf", \
    "--dhcp-leasefile=/data/dnsmasq.leases"]
```

`dhcp/dnsmasq.conf` (qui senza commenti; letto dal volume: una modifica richiede solo `container stop/start mitm-dhcp`, non un rebuild):
```
port=0
dhcp-authoritative
dhcp-range=192.168.3.100,192.168.3.199,255.255.255.0,1h
dhcp-option=option:router,192.168.3.2
dhcp-option=option:dns-server,1.1.1.1,1.0.0.1,192.168.3.2
dhcp-proxy=192.168.3.1
# dhcp-host=aa:bb:cc:dd:ee:ff,192.168.3.50
log-dhcp
```

Punti critici:
- **Netmask esplicita nel `dhcp-range`**: per le reti servite via relay `dnsmasq` non può ricavarla dalle interfacce locali.
- **`dhcp-proxy=192.168.3.1`**: normalmente, dopo il primo lease, il client rinnova in **unicast verso il server-ID** (option 54), che sarebbe l'IP del container — raggiungibile solo finché non cambia. Con `dhcp-proxy` il server-ID è l'indirizzo del relay, e anche i rinnovi passano dal router → Mac → container.
- **`dhcp-authoritative`**: `dnsmasq` è l'unico server DHCP della LAN; risponde subito anche a client che hanno ancora un lease del vecchio DHCP del router, invece di ignorarli.
- **Lease di 1h**: una modifica di gateway/DNS arriva ai client entro ~30 min (T1).
- **Range `.100–.199`**: fuori da `.1` (router), `.2` (Mac) e dagli IP statici già in uso (es. `.249`).
- **`--cap-add NET_ADMIN`** è obbligatorio anche qui: senza, `dnsmasq` esce all'avvio con `process is missing required capability NET_ADMIN`.
- **Lease persistenti** in `./dhcp/dnsmasq.leases`: dopo un riavvio del container `dnsmasq` non riassegna IP già in uso.

Configurazione del router (Zyxel): DHCP in modalità **Relay**, server `192.168.3.2`. Nessun altro server DHCP deve restare attivo sulla LAN.

Log DHCP: `container logs mitm-dhcp`.

### 7. Avvio

Setup una tantum del dominio DNS locale di `container` (vedi *Web UI dal Mac*):
```bash
sudo container system dns create test
```

I container vengono creati/avviati dagli script del punto 3, sulla rete `default` (nessun `--network`):
```bash
container build -t mitm-transparent .
container build -t mitm-dhcp dhcp/
./start-mitm.sh          # avvia anche il DHCP
```
Solo DHCP (i client navigano via NAT, senza intercettazione): `./start-dhcp.sh`.

Password della web UI: `password`, oppure `MITM_WEB_PASSWORD='<password>' ./start-mitm.sh`.

Dopo un riavvio (`container stop`, reboot del Mac) basta rieseguire `./start-mitm.sh`: riavvia i container fermi e aggiorna le regole pf. Dopo un **reboot del Mac** i servizi di `container` non ripartono da soli (`apiserver is not running and not registered with launchd`): prima va lanciato `container system start` (vedi *Limiti noti*).

Per cambiare password o immagine (dopo un nuovo `container build`) il container va ricreato, perché gli script non toccano un container esistente:
```bash
./stop-mitm.sh --rm
MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
```
Per il container DHCP: `./stop-dhcp.sh --rm && ./start-dhcp.sh`.

#### Web UI dal Mac: `http://mitmproxy.test:8081`

`container` include un DNS locale (`container-apiserver`, in ascolto su `127.0.0.1:2053`). `sudo container system dns create test` crea `/etc/resolver/containerization.test`, che dice a macOS di risolvere i nomi `*.test` tramite quel server. Il nome segue da solo l'IP del container: niente da aggiornare dopo un riavvio.

Il DNS integrato risolve **solo i container il cui nome è `<nome>.<dominio>`**: per questo il container di mitmproxy si chiama `mitmproxy.test` (`NAME="mitmproxy.$DNS_DOMAIN"` in `start-mitm.sh`). Un container chiamato `mitm-proxy` non viene risolto, né come `mitm-proxy` né come `mitm-proxy.test`, anche se creato con `--dns-domain test` (vedi [Mcrich23/Container-Compose#81](https://github.com/Mcrich23/Container-Compose/issues/81)).

`--dns-domain test` imposta solo il DNS *dentro* il container (`/etc/resolv.conf` → `nameserver 192.168.64.1`, `domain test`); la risoluzione dei nomi esterni resta funzionante. Per il nome sul Mac conta solo il nome del container.

Il nome vale **solo sul Mac**: il server DNS di `container` risponde su `127.0.0.1`, i client LAN non possono usarlo.

Per verificare la risoluzione (da terminale `curl` verso i container va in timeout per il filtro di Digital Guardian sui processi del Mac, cronologia punto 1: la web UI va provata dal browser):
```bash
dscacheutil -q host -a name mitmproxy.test
```

Per fermare: `./stop-mitm.sh` (punto 8).

Note:
- `--cap-add NET_ADMIN` è **obbligatorio**: senza questa capability, `iptables` fallisce con `Permission denied (you must be root)` anche se il processo gira come root a livello di utente Linux (il container di default ha un set di capability ridotto).
- `--volume ./mitmproxy:/root/.mitmproxy` rende persistente la configurazione di mitmproxy del container, CA inclusa. Il percorso è relativo alla directory del progetto, e `./mitmproxy` deve esistere (altrimenti `container run` fallisce con `path './mitmproxy' does not exist`). Per riusare la CA già installata sui dispositivi, copiarla da `~/.mitmproxy` (`mitmproxy-ca.pem`, `mitmproxy-ca-cert.*`, `mitmproxy-dhparam.pem`); se la directory è vuota mitmproxy genera una **nuova** CA da reinstallare sui dispositivi. Se emergono errori di permessi, `chmod -R 777 ./mitmproxy` sul Mac.
- Una directory dedicata evita che il container carichi `~/.mitmproxy/config.yaml` dell'uso sul Mac (con i suoi `ignore_hosts`, `ssl_insecure`, …). Un eventuale `config.yaml` in `./mitmproxy` viene caricato: le opzioni da riga di comando (`mode`, `listen_port`, `web_port`, …) hanno la precedenza, tutto il resto viene applicato.
- `MITM_WEB_PASSWORD` in chiaro è visibile in `container inspect mitmproxy.test` e nella lista processi del container. Per evitarlo, `web_password` accetta anche un hash argon2 (mitmweb stesso lo suggerisce all'avvio).

### 8. Arresto (`stop-mitm.sh`, `stop-dhcp.sh`)

Come per l'avvio, due script separati. `stop-mitm.sh` **non ferma il DHCP**: i client mantengono il Mac come gateway e navigano via NAT, senza intercettazione. Per fermare tutto:
```bash
./stop-mitm.sh && ./stop-dhcp.sh
```

Fermare solo il container **non basta**: la regola pf resterebbe attiva verso un IP non più in ascolto (con `route-to`, HTTP/HTTPS bloccati per tutta la LAN). Ogni script:
- ferma il proprio container se è in esecuzione (con `--rm` lo rimuove anche — necessario per cambiare password o immagine);
- svuota il proprio file di stato; il daemon `com.mitm.pf` (punto 9) allora:
  - **svuota il file** dell'anchor (`/etc/pf.anchors/com.mitm.route` o `com.mitm.dhcp`), così un reload di `/etc/pf.conf` (es. al riavvio del Mac) non ripristina la vecchia regola;
  - svuota subito l'anchor in pf (`-F rules` per il `route-to`, `-F nat` per l'`rdr`: le `rdr` sono regole di traduzione, `-F rules` non le toccherebbe);
  - chiude gli stati pf legati alla vecchia regola: per mitmproxy quelli dei client LAN (`pfctl -k 192.168.3.0/24`, include anche gli stati del relay DHCP, che si ricreano al pacchetto successivo), per il DHCP solo quelli relay → Mac (`pfctl -k 192.168.3.1 -k 192.168.3.2`).

Dopo `stop-dhcp.sh` i client non possono rinnovare il lease: se il Mac smette di fare da gateway, va rimesso il router in modalità DHCP server.

Come gli script di avvio, vanno eseguiti **senza sudo** e non chiedono privilegi. Si possono rilanciare anche se i container sono già fermi o non esistono.

`stop-mitm.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Ferma mitmproxy e rimuove la regola pf route-to. Il DHCP resta attivo: i
# client mantengono il Mac come gateway e navigano via NAT, senza
# intercettazione. Per fermare anche il DHCP: ./stop-dhcp.sh
#
# Nessun sudo: lo script svuota /usr/local/var/mitm-pf/route e il LaunchDaemon
# di root com.mitm.pf svuota l'anchor com.mitm.route e chiude gli stati dei client.
#
# Uso: ./stop-mitm.sh         ferma il container e rimuove la regola route-to
#      ./stop-mitm.sh --rm    rimuove anche il container
#                             (necessario per cambiare password o immagine)

NAME=mitmproxy.test   # deve coincidere con NAME di start-mitm.sh
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.route

REMOVE=false
for arg in "$@"; do
  case "$arg" in
    --rm) REMOVE=true ;;
    *)    echo "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

# Scrive il file di stato per il daemon (rename atomico)
write_state() {
  printf '%s\n' "$2" > "$STATE/.$1.tmp"
  mv "$STATE/.$1.tmp" "$STATE/$1"
}

# Attende che il daemon abbia applicato la regola: anchor che contiene $2,
# o vuoto se $2 è vuoto. Fino a ~10s.
wait_anchor() {
  for _ in $(seq 1 20); do
    if [ -z "$2" ]; then
      [ ! -s "$1" ] && return 0
    else
      grep -qF -- "$2" "$1" 2> /dev/null && return 0
    fi
    sleep 0.5
  done
  echo "Il daemon com.mitm.pf non ha aggiornato $1: vedi /var/log/mitm-pf.log" >&2
  return 1
}

if container inspect "$NAME" > /dev/null 2>&1; then
  if [ "$(container inspect "$NAME" | jq -r '.[0].status.state')" = "running" ]; then
    echo "Fermo il container $NAME"
    container stop "$NAME" > /dev/null
  fi
  if [ "$REMOVE" = true ]; then
    echo "Rimuovo il container $NAME"
    container rm "$NAME" > /dev/null
  fi
else
  echo "Container $NAME non presente"
fi

# Regola pf rimossa dal daemon (anche dal file, così un reload di
# /etc/pf.conf non la ripristina). Senza questo, il traffico 80/443 dei
# client LAN resterebbe instradato verso un IP non più attivo.
write_state route ""
wait_anchor "$ANCHOR" ""

echo "Intercettazione disattivata: i client LAN escono su Internet via NAT su en0"
```

`stop-dhcp.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Ferma il DHCP della LAN e rimuove la regola pf del relay. Autonomo: non
# tocca mitmproxy. Senza DHCP i client non ottengono né rinnovano il lease:
# se il Mac smette di fare da gateway, rimettere il router in modalità DHCP server.
#
# Nessun sudo: lo script svuota /usr/local/var/mitm-pf/dhcp e il LaunchDaemon
# di root com.mitm.pf svuota l'anchor com.mitm.dhcp e chiude gli stati relay → Mac.
#
# Uso: ./stop-dhcp.sh         ferma il container e rimuove la regola rdr
#      ./stop-dhcp.sh --rm    rimuove anche il container (es. dopo un rebuild)

DHCP_NAME=mitm-dhcp
STATE=/usr/local/var/mitm-pf
ANCHOR=/etc/pf.anchors/com.mitm.dhcp

REMOVE=false
for arg in "$@"; do
  case "$arg" in
    --rm) REMOVE=true ;;
    *)    echo "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

# Scrive il file di stato per il daemon (rename atomico)
write_state() {
  printf '%s\n' "$2" > "$STATE/.$1.tmp"
  mv "$STATE/.$1.tmp" "$STATE/$1"
}

# Attende che il daemon abbia applicato la regola: anchor che contiene $2,
# o vuoto se $2 è vuoto. Fino a ~10s.
wait_anchor() {
  for _ in $(seq 1 20); do
    if [ -z "$2" ]; then
      [ ! -s "$1" ] && return 0
    else
      grep -qF -- "$2" "$1" 2> /dev/null && return 0
    fi
    sleep 0.5
  done
  echo "Il daemon com.mitm.pf non ha aggiornato $1: vedi /var/log/mitm-pf.log" >&2
  return 1
}

if container inspect "$DHCP_NAME" > /dev/null 2>&1; then
  if [ "$(container inspect "$DHCP_NAME" | jq -r '.[0].status.state')" = "running" ]; then
    echo "Fermo il container $DHCP_NAME"
    container stop "$DHCP_NAME" > /dev/null
  fi
  if [ "$REMOVE" = true ]; then
    echo "Rimuovo il container $DHCP_NAME"
    container rm "$DHCP_NAME" > /dev/null
  fi
else
  echo "Container $DHCP_NAME non presente"
fi

# Regola pf rimossa dal daemon (anche dal file, così un reload di
# /etc/pf.conf non la ripristina)
write_state dhcp ""
wait_anchor "$ANCHOR" ""

echo "DHCP fermo: i client non rinnovano il lease (ripristinare il DHCP server sul router se serve)"
```

Per riprendere: `./start-mitm.sh` (riavvia anche il DHCP se serve), oppure `./start-dhcp.sh` per il solo DHCP.

Gli script lasciano volutamente attivi:
- **pf**: non si usa `pfctl -d`, che lo disabiliterebbe per tutto il sistema (inclusi servizi macOS/MDM che lo usano); con gli anchor vuoti pf non ha effetti sul traffico LAN;
- **IP forwarding**: spegnerlo (`sudo sysctl -w net.inet.ip.forwarding=0`, e rimuovere la riga da `/etc/sysctl.conf` per renderlo permanente) toglie Internet ai client LAN.

### 9. Regole pf senza sudo e avvio al login (`daemon/`, `launchagent/`)

Gli script utente non possono aggiornare pf da soli (serve root, con prompt BeyondTrust a ogni `sudo`), e al login non c'è nessuno a confermare un prompt. La parte privilegiata è quindi separata in un **LaunchDaemon di root**, installato una volta sola:

```
script utente ──scrive IP──▶ /usr/local/var/mitm-pf/{route,dhcp}   (utente)
                                   │ launchd WatchPaths
                                   ▼
                     com.mitm.pf (root): valida, rigenera /etc/pf.anchors/com.mitm.{route,dhcp},
                                         pfctl -a <anchor> -f|-F, pfctl -k, pfctl -E se serve
```

- **File di stato** (scritti con rename atomico, così il daemon non legge mai un file a metà):
  - `route` → `<bridge> <IP mitmproxy>` (vuoto = nessuna intercettazione);
  - `dhcp` → `<IP dnsmasq>` (vuoto = nessun DHCP).
- **Validazione**: il contenuto è scrivibile dall'utente, quindi non viene mai eseguito né copiato così com'è; il daemon accetta solo `bridge<N>` e indirizzi IPv4 (regex) e genera la regola da un modello fisso. Qualsiasi altro contenuto svuota la regola.
- **Script di root in `/usr/local/libexec/mitm-pf-apply`** (root:wheel, 755), non nella directory del progetto: altrimenti chi può scrivere nel progetto potrebbe far eseguire codice a root.
- **Nessun reload inutile**: l'anchor viene ricaricato (e gli stati chiusi) solo se la regola cambia.
- **Al boot** (`RunAtLoad`): i file di stato **precedenti all'ultimo boot** (`kern.boottime`) sono ignorati, quindi le regole della sessione precedente vengono svuotate. Risolve il `route-to` verso un IP inesistente rimasto dopo un riavvio con mitmproxy attivo.
- Log: `/var/log/mitm-pf.log`.

`daemon/mitm-pf-apply`:
```bash
#!/bin/bash
# Eseguito da root via LaunchDaemon com.mitm.pf (installato in
# /usr/local/libexec). Legge gli IP scritti dagli script utente in
# /usr/local/var/mitm-pf/ e rigenera gli anchor pf. I file di stato sono
# scrivibili dall'utente: il contenuto viene validato, mai eseguito.
#
#   route  →  "<bridge> <IP mitmproxy>"   (vuoto/assente = nessuna intercettazione)
#   dhcp   →  "<IP dnsmasq>"              (vuoto/assente = nessun DHCP)
#
# File più vecchi dell'ultimo boot sono ignorati: dopo un riavvio i container
# sono fermi e le regole della sessione precedente vanno svuotate.
set -u

STATE=/usr/local/var/mitm-pf
ANCHORS=/etc/pf.anchors
ROUTER=192.168.3.1
MAC_LAN_IP=192.168.3.2
IP_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
IF_RE='^bridge[0-9]{1,3}$'

# "{ sec = 1790839610, usec = 680084 } ..." → 1790839610
BOOT=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')

# Contenuto del file di stato, vuoto se assente o precedente al boot
read_state() {
  local f="$STATE/$1"
  [ -f "$f" ] || return 0
  [ "$(stat -f %m "$f")" -ge "$BOOT" ] || return 0
  head -c 64 "$f" | head -n 1
}

# Scrive l'anchor solo se cambia; ritorna 0 se è cambiato
write_anchor() {
  local file="$ANCHORS/$1" new="$2"
  [ -f "$file" ] && [ "$(cat "$file")" = "$new" ] && return 1
  printf '%s' "$new" > "$file"
  [ -n "$new" ] && printf '\n' >> "$file"
  return 0
}

# --- mitmproxy: route-to ---
read -r BRIDGE MITM_IP _ <<<"$(read_state route)"
RULE=""
if [[ ${BRIDGE:-} =~ $IF_RE ]] && [[ ${MITM_IP:-} =~ $IP_RE ]]; then
  RULE="pass in quick on en7 route-to ($BRIDGE $MITM_IP) inet proto tcp from 192.168.3.0/24 to any port { 80, 443 } keep state"
fi
if write_anchor com.mitm.route "$RULE"; then
  if [ -n "$RULE" ]; then
    pfctl -a com.mitm.route -f "$ANCHORS/com.mitm.route"
  else
    pfctl -a com.mitm.route -F rules
  fi
  # Connessioni dei client ancora legate alla regola precedente
  pfctl -k 192.168.3.0/24
fi

# --- DHCP: rdr del relay ---
read -r DHCP_IP _ <<<"$(read_state dhcp)"
RULE=""
if [[ ${DHCP_IP:-} =~ $IP_RE ]]; then
  RULE="rdr on en7 inet proto udp from $ROUTER to $MAC_LAN_IP port 67 -> $DHCP_IP port 67"
fi
if write_anchor com.mitm.dhcp "$RULE"; then
  if [ -n "$RULE" ]; then
    pfctl -a com.mitm.dhcp -f "$ANCHORS/com.mitm.dhcp"
  else
    pfctl -a com.mitm.dhcp -F nat
  fi
  pfctl -k "$ROUTER" -k "$MAC_LAN_IP"
fi

pfctl -s info | grep -q 'Status: Enabled' || pfctl -E
exit 0
```

`daemon/com.mitm.pf.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mitm.pf</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/mitm-pf-apply</string>
    </array>
    <!-- Al boot: svuota le regole della sessione precedente -->
    <key>RunAtLoad</key>
    <true/>
    <!-- A ogni modifica dei file di stato scritti dagli script utente -->
    <key>WatchPaths</key>
    <array>
        <string>/usr/local/var/mitm-pf</string>
    </array>
    <key>StandardOutPath</key>
    <string>/var/log/mitm-pf.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/mitm-pf.log</string>
</dict>
</plist>
```

Installazione (una volta, da amministratore):
```bash
sudo ./daemon/install.sh
```
`daemon/install.sh`:
```bash
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
```

Verifica: `sudo launchctl print system/com.mitm.pf | grep -E 'state|last exit'`.

#### Avvio del DHCP al login (LaunchAgent `com.mitm.dhcp`)

I servizi di `container` sono job launchd della **sessione utente**: dopo un reboot non sono registrati (`apiserver is not running and not registered with launchd`) e prima del login non possono girare. Il LaunchAgent, a ogni login, lancia `container system start` (idempotente: con i servizi già attivi termina con successo) e poi `start-dhcp.sh`. mitmproxy **non** parte al login: si avvia a mano con `./start-mitm.sh`.

`launchagent/com.mitm.dhcp.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Avvio del DHCP al login (LaunchAgent utente, nessun privilegio).
  Dopo un reboot i servizi di container non sono registrati: prima
  container system start (idempotente), poi start-dhcp.sh.
  Installazione: ./launchagent/install.sh
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mitm.dhcp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>container system start &amp;&amp; exec /Users/f.gasperini/test/start-dhcp.sh</string>
    </array>
    <!-- container è in /usr/local/bin, assente dal PATH di default di launchd -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/f.gasperini/Library/Logs/mitm-dhcp.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/f.gasperini/Library/Logs/mitm-dhcp.log</string>
</dict>
</plist>
```

Installazione (utente normale, senza sudo) e rimozione:
```bash
./launchagent/install.sh
./launchagent/install.sh --remove
```

Log: `~/Library/Logs/mitm-dhcp.log`. Stato: `launchctl print gui/$(id -u)/com.mitm.dhcp | grep -E 'state|last exit'`.

## Problemi diagnosticati durante la costruzione (cronologia)

1. **pf/sysctl "nessun errore, nessun effetto"** → causa: Network Extension di Digital Guardian (`DGWebProxy`) intercetta a livello NECP le connessioni **generate da processi sul Mac stesso**, bypassando `pf`. Confermato non essere la causa dei problemi successivi con traffico di solo transito (che passa senza toccare NECP).
2. **Application Firewall di macOS blocca mitmproxy in ascolto sul Mac** → SYN mai risposto, gestione centralizzata da MDM, non modificabile via CLI. Root cause della decisione di spostare mitmproxy in un container.
3. **`rdr` verso `127.0.0.1` non funzionava** → sospetto anti-spoofing su loopback da sorgente esterna; risolto (poi superato) instradando verso l'IP reale/il container invece che verso loopback.
4. **`FileNotFoundError` in mitmproxy transparent mode dentro il container** → causato dal fare NAT su macOS (`rdr`) invece che dentro il container: mitmproxy su Linux recupera la destinazione originale via `getsockopt(SO_ORIGINAL_DST)`, che richiede che il redirect avvenga nello stesso kernel. Risolto passando a `route-to` (pf instrada senza tradurre) + `iptables REDIRECT` locale al container.
5. **Container non restava in esecuzione** → `iptables` falliva per mancanza della capability `NET_ADMIN`. Risolto con `--cap-add NET_ADMIN`.
6. **IP del container non fissabile** → `--network` supporta solo `mac`/`mtu`, non `ip`. Risolto con script che legge l'IP a runtime (`container inspect`) e rigenera la regola pf.
7. **`container inspect` falliva se l'intero script girava con `sudo`** → il servizio `container` è legato alla sessione utente, non root. Risolto elevando solo i comandi che scrivono su `/etc` e ricaricano `pf`, non l'intero script.
8. **Traffico non visibile / connessioni appese** → `route-to` puntava all'interfaccia sbagliata (`en7` invece del bridge vmnet `bridge100`) — il container non è raggiungibile da `en7`. Ora lo script ricava il bridge dal gateway del container.
9. **Egress del container in timeout totale dopo aver attivato il REDIRECT** → risolto aggiungendo `-s 192.168.3.0/24` al match. La causa esatta non è chiarita: in netfilter `PREROUTING` non vede il traffico generato localmente e le risposte in ingresso hanno porta *sorgente* 80/443, non di destinazione; il filtro resta comunque corretto perché limita il REDIRECT ai soli client LAN.
10. **Rete dedicata `mitm-net` non necessaria** → una rete creata con `container network create --subnet 192.168.70.0/24` ottiene un proprio bridge (non `bridge100`) e rende incoerenti subnet/gateway/interfaccia del `route-to`. Si usa la rete `default`.
11. **mitmproxy vecchio su Debian bookworm** → Python 3.11 ⇒ pip installa mitmproxy 11.0.2, senza `web_password`. Risolto con immagine base `python:3.13-slim-bookworm` e versione fissata.
12. **Configurazione di rete manuale sui device** → il DHCP del router non permette un gateway diverso da sé stesso. Risolto con DHCP relay del router verso il Mac + `rdr` pf + `dnsmasq` in container (punto 6), che assegna il Mac come gateway.
13. **Container DHCP che si ferma subito dopo l'avvio** → `dnsmasq` richiede `NET_ADMIN` per il DHCP. Risolto con `--cap-add NET_ADMIN` anche su `mitm-dhcp`.
14. **DHCP ok ma il telefono non naviga** → mitmweb riceveva le connessioni (`192.168.3.168`) ma andava in timeout verso tutti i server (`Connect call failed … Errno 110`); dal container falliva anche `curl https://example.com`. Causa: il reload completo di `/etc/pf.conf` (fatto per aggiungere `com.mitm.dhcp`) aveva rimosso gli anchor NAT inseriti a runtime da `InternetSharing` per `192.168.64.0/24`. Risolto aggiungendo `nat on en0 inet from 192.168.64.0/24 to any -> (en0)` a `com.mitm.nat` e ricaricando solo quell'anchor (`pfctl -a com.mitm.nat -f …`). Alternativa senza pf: `container system stop` / `container system start` (poi `./start-mitm.sh`), ma il problema si ripresenterebbe al successivo reload completo.
15. **Web UI raggiungibile solo digitando l'IP del container** (che cambia a ogni riavvio) → risolto con il DNS integrato di `container` (`container system dns create test`). Il primo tentativo non risolveva nulla (NXDOMAIN) neanche per container creati con `--dns-domain test`: il DNS registra solo i container il cui nome è già `<nome>.<dominio>`. Rinominato il container da `mitm-proxy` a `mitmproxy.test`.
16. **Dopo un reboot il telefono non navigava e nulla ripartiva** → i servizi di `container` non si registrano da soli dopo il reboot, e `com.mitm.route` conteneva ancora il `route-to` verso l'IP del container della sessione precedente (ricaricato da `pf.conf` all'avvio). Risolto con il LaunchDaemon `com.mitm.pf` (svuota al boot le regole con file di stato precedenti al boot) e il LaunchAgent `com.mitm.dhcp` (avvia `container` e il DHCP al login). Il daemon elimina anche i prompt `sudo` degli script.

## Limiti noti / cose da verificare ancora

- **QUIC/HTTP3 su UDP 443** non viene intercettato (`route-to`/`REDIRECT` sono solo TCP) e, non essendoci una regola che lo blocchi, esce via NAT su `en0`. Client come Safari/Chrome su iOS possono usarlo di default per molti siti, con traffico che bypassa mitmproxy senza errori visibili. Per forzare il fallback su TCP si può aggiungere nell'heredoc dello script (l'anchor `com.mitm.route` viene rigenerato a ogni esecuzione): `block in quick on en7 inet proto udp from 192.168.3.0/24 to any port 443`.
- **Tra boot e login niente DHCP**: i servizi di `container` girano solo nella sessione utente, quindi il DHCP parte al login (LaunchAgent, punto 9), non al boot. Prima del login i client non ottengono/rinnovano il lease. Il daemon pf invece parte al boot e svuota le regole della sessione precedente.
- **Avvio al login provato solo con `launchctl bootstrap`**, non ancora con un vero logout/login o reboot.
- **Il Mac è un punto singolo di guasto per la LAN**: con il DHCP in relay, a Mac spento o scollegato i client non ottengono/rinnovano il lease e non hanno gateway. Per tornare alla situazione standard: router in modalità DHCP server (i client riprendono gateway `192.168.3.1` al rinnovo successivo o riconnettendosi).
- **Rinnovi DHCP via relay da verificare nel tempo**: il primo lease tramite il relay Zyxel funziona (iPhone → `192.168.3.168`). Non è ancora verificato che il router inoltri anche i rinnovi unicast indirizzati a `192.168.3.1`; se non lo facesse, i client rinnovano comunque in broadcast alla scadenza di T2 (~52 min con lease di 1h). Da controllare in `container logs mitm-dhcp` dopo ~30 min (T1).
- **DNS `192.168.3.2` offerto ai client senza un servizio DNS dietro**: `dnsmasq.conf` include `192.168.3.2` come terzo DNS, ma sul Mac nessuno risponde sulla porta 53 (e il DNS di `container` ascolta solo su `127.0.0.1`). Se un client sceglie quel server, le sue query vanno in timeout finché non ripiega sugli altri.
- **IPv6 non funzionante** nella rete del container (timeout puri) — non bloccante per l'uso attuale (traffico IPv4), ma da tenere presente se in futuro serve intercettare anche IPv6.
- **Stati pf dopo un cambio IP**: le connessioni già aperte restano legate al vecchio IP del container fino alla scadenza dello stato; le nuove usano la regola aggiornata.
- Le regole duplicate in `iptables -t nat` a ogni riavvio dell'entrypoint sono gestite con `-F` preventivo, ma vale la pena verificare nel tempo che non si accumulino residui in altri punti (es. se in futuro si aggiungono altre catene).

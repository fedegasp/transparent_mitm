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
Il nome del bridge (`bridge100`) non è garantito stabile: lo script al punto 3 lo ricava a runtime dall'interfaccia che ha l'IP del gateway.

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
Il DHCP ha un **anchor separato** (`com.mitm.dhcp`, dichiarato come `rdr-anchor`: le regole `rdr` in un anchor dichiarato solo con `anchor` verrebbero ignorate). Così `stop-mitm.sh` può rimuovere l'intercettazione senza interrompere il DHCP.

`/etc/pf.anchors/com.mitm.nat` (NAT verso Internet per il resto del traffico LAN, non HTTP/S, e per l'egress dei container):
```
nat on en0 inet from 192.168.3.0/24 to any -> (en0)
nat on en0 inet from 192.168.64.0/24 to any -> (en0)
```
La seconda riga **è necessaria**: il NAT della rete dei container lo fa normalmente `InternetSharing` (avviato da `container-network-vmnet`), inserendo i propri anchor pf nel ruleset principale a runtime. Un reload completo (`pfctl -f /etc/pf.conf`) li rimuove, e da quel momento i container non escono più su Internet (mitmproxy riceve le connessioni dei client ma va in timeout verso i server). Con la regola nel nostro anchor l'egress non dipende più da quegli anchor; se sono presenti, vale la prima regola che corrisponde, niente doppio NAT.

`/etc/pf.anchors/com.mitm.route` (rigenerato dinamicamente dallo script al punto 3 — l'IP del container non è fisso):
```
pass in quick on en7 route-to (bridge100 <IP_CONTAINER>) inet proto tcp from 192.168.3.0/24 to any port { 80, 443 } keep state
```
> Nota: l'interfaccia nel `route-to` è quella **bridge di vmnet** (`bridge100`), non `en7`.

`/etc/pf.anchors/com.mitm.dhcp` (rigenerato dallo script — anche l'IP del container DHCP non è fisso):
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

Dopo il setup iniziale, lo script ricarica **solo gli anchor** `com.mitm.route` e `com.mitm.dhcp` (`pfctl -a <anchor> -f ...`) e non l'intero `/etc/pf.conf`: ricaricare il ruleset principale può rimuovere gli anchor inseriti dinamicamente dai servizi di sistema (vedi commento in testa a `/etc/pf.conf`).

### 3. Script di avvio (`start-mitm.sh`)

L'IP dei container cambia a ogni riavvio (non esiste un flag per fissarlo — `container run --network` supporta solo `mac`/`mtu`, non `ip`). Lo script gestisce entrambi i container (`mitmproxy.test` e `mitm-dhcp`) ed è **idempotente**, si può rilanciare in qualsiasi momento:
- container **inesistente** → lo crea con `container run` (è l'unico momento in cui viene letta `MITM_WEB_PASSWORD`, default `password`);
- container **fermo** → `container start`;
- container **in esecuzione** → nessuna azione sul container.

Poi attende che gli IP siano assegnati (fino a ~10s ciascuno), ricava il bridge e rigenera i due anchor pf (`com.mitm.route` e `com.mitm.dhcp`).

Va eseguito **senza sudo davanti a tutto**: `container run/inspect` richiedono la sessione utente; solo la scrittura dei file e il reload pf sono elevati. Lo script si porta nella propria directory (`cd "$(dirname "$0")"`), quindi i volumi relativi (`./mitmproxy`, `./dhcp`) funzionano da qualunque directory lo si lanci.

```bash
#!/bin/bash
set -euo pipefail

# Da eseguire SENZA sudo: container run/inspect richiedono la sessione utente.
# Solo la scrittura degli anchor e il reload di pf sono elevati.
#
# Uso: ./start-mitm.sh
#      MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
# Password della web UI: default 'password'. Serve solo alla creazione del
# container; nei rilanci successivi (container già esistente) viene ignorata.

# I volumi usano percorsi relativi alla directory del progetto
cd "$(dirname "$0")"

# Dominio DNS locale di container (creato una volta con
# `sudo container system dns create test`). Il DNS integrato risolve solo i
# container il cui nome è <nome>.<dominio>: sul Mac la web UI è raggiungibile
# come http://mitmproxy.test:8081, qualunque sia l'IP corrente.
DNS_DOMAIN=test
NAME="mitmproxy.$DNS_DOMAIN"
IMAGE=mitm-transparent
DHCP_NAME=mitm-dhcp
DHCP_IMAGE=mitm-dhcp
ROUTER=192.168.3.1        # router/AP con DHCP relay verso il Mac
MAC_LAN_IP=192.168.3.2    # IP del Mac su en7, destinazione del relay

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

# DHCP (dnsmasq): stesso schema, configurazione e lease in ./dhcp.
# NET_ADMIN è richiesta da dnsmasq per il DHCP (altrimenti esce all'avvio).
if ! start_existing "$DHCP_NAME"; then
  echo "Creo il container $DHCP_NAME"
  container run -d --name "$DHCP_NAME" \
    --cap-add NET_ADMIN \
    --volume ./dhcp:/data \
    "$DHCP_IMAGE" > /dev/null
fi

NET=$(container_net "$NAME")
read -r CONTAINER_IP GATEWAY <<<"$NET"
NET=$(container_net "$DHCP_NAME")
read -r DHCP_IP _ <<<"$NET"

# Bridge vmnet = interfaccia del Mac che ha l'IP del gateway (es. bridge100)
BRIDGE=$(ifconfig | awk -v gw="$GATEWAY" '
  /^[a-z0-9]+:/ { iface = substr($1, 1, length($1) - 1) }
  $1 == "inet" && $2 == gw { print iface; exit }')

if [ -z "$BRIDGE" ]; then
  echo "Nessuna interfaccia con IP $GATEWAY"
  exit 1
fi

echo "IP mitmproxy: $CONTAINER_IP  IP DHCP: $DHCP_IP  bridge: $BRIDGE"

# HTTP/HTTPS dei client LAN → mitmproxy (instradato, destinazione invariata)
sudo tee /etc/pf.anchors/com.mitm.route > /dev/null <<EOF
pass in quick on en7 route-to ($BRIDGE $CONTAINER_IP) inet proto tcp from 192.168.3.0/24 to any port { 80, 443 } keep state
EOF

# Richieste del relay DHCP del router → dnsmasq (qui basta rdr: dnsmasq non
# ha bisogno della destinazione originale)
sudo tee /etc/pf.anchors/com.mitm.dhcp > /dev/null <<EOF
rdr on en7 inet proto udp from $ROUTER to $MAC_LAN_IP port 67 -> $DHCP_IP port 67
EOF

sudo pfctl -a com.mitm.route -f /etc/pf.anchors/com.mitm.route
sudo pfctl -a com.mitm.dhcp -f /etc/pf.anchors/com.mitm.dhcp
sudo pfctl -s info | grep -q 'Status: Enabled' || sudo pfctl -E
echo "Regole pf aggiornate e ricaricate"
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

Container separato `mitm-dhcp` con `dnsmasq`, raggiunto dal relay del router tramite l'`rdr` di pf (vedi *Flusso del traffico*). È separato da `mitmproxy.test` perché ha un ciclo di vita diverso: `stop-mitm.sh` ferma l'intercettazione ma lascia attivo il DHCP, così i client continuano a ricevere/rinnovare il lease e navigano via NAT del Mac.

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

I container vengono creati/avviati da `start-mitm.sh` (punto 3), sulla rete `default` (nessun `--network`):
```bash
container build -t mitm-transparent .
container build -t mitm-dhcp dhcp/
./start-mitm.sh
```
Password della web UI: `password`, oppure `MITM_WEB_PASSWORD='<password>' ./start-mitm.sh`.

Dopo un riavvio (`container stop`, reboot del Mac) basta rieseguire `./start-mitm.sh`: riavvia i container fermi e aggiorna le regole pf.

Per cambiare password o immagine (dopo un nuovo `container build`) il container va ricreato, perché lo script non tocca un container esistente:
```bash
./stop-mitm.sh --rm
MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
```
(`--rm --all` per ricreare anche il container DHCP.)

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

### 8. Arresto (`stop-mitm.sh`)

Fermare solo il container **non basta**: la regola `route-to` resterebbe attiva e il traffico 80/443 dei client su `en7` verrebbe instradato verso un IP non più in ascolto (HTTP/HTTPS bloccati per tutta la LAN). Lo script:
- ferma `mitmproxy.test` se è in esecuzione;
- **svuota il file** `/etc/pf.anchors/com.mitm.route`, così un reload di `/etc/pf.conf` (es. al riavvio del Mac) non ripristina la vecchia regola;
- svuota subito l'anchor in pf (`pfctl -a com.mitm.route -F rules`);
- chiude gli stati pf dei client LAN (`pfctl -k 192.168.3.0/24`), altrimenti le connessioni già aperte resterebbero instradate verso il container fino alla scadenza.

Il **DHCP resta attivo** per default: i client mantengono il Mac come gateway e navigano via NAT, senza intercettazione.

Opzioni (combinabili):
- `--all`: ferma anche `mitm-dhcp` e svuota l'anchor `com.mitm.dhcp` (con `-F nat`: le `rdr` sono regole di traduzione, `-F rules` non le toccherebbe). Da usare quando si smette di usare il Mac come gateway: i client non potranno rinnovare il lease, quindi va rimesso il router in modalità DHCP server.
- `--rm`: rimuove anche i container fermati (necessario per cambiare password o immagine).

Come `start-mitm.sh`, va eseguito **senza sudo davanti a tutto**. Si può rilanciare anche se i container sono già fermi o non esistono.

```bash
#!/bin/bash
set -euo pipefail

# Da eseguire SENZA sudo: container stop/rm richiedono la sessione utente.
# Solo lo svuotamento degli anchor e la pulizia degli stati pf sono elevati.
#
# Uso: ./stop-mitm.sh              ferma mitmproxy e rimuove la regola route-to;
#                                  il DHCP resta attivo (i client navigano via NAT)
#      ./stop-mitm.sh --all        ferma anche il DHCP e rimuove la regola rdr
#      ./stop-mitm.sh --rm [...]   rimuove anche i container fermati
#                                  (necessario per cambiare password o immagine)

NAME=mitmproxy.test   # deve coincidere con NAME di start-mitm.sh
DHCP_NAME=mitm-dhcp

REMOVE=false
ALL=false
for arg in "$@"; do
  case "$arg" in
    --rm)  REMOVE=true ;;
    --all) ALL=true ;;
    *)     echo "Opzione sconosciuta: $arg"; exit 1 ;;
  esac
done

# Ferma il container se in esecuzione, lo rimuove solo con --rm
stop_container() {
  if container inspect "$1" > /dev/null 2>&1; then
    if [ "$(container inspect "$1" | jq -r '.[0].status.state')" = "running" ]; then
      echo "Fermo il container $1"
      container stop "$1" > /dev/null
    fi
    if [ "$REMOVE" = true ]; then
      echo "Rimuovo il container $1"
      container rm "$1" > /dev/null
    fi
  else
    echo "Container $1 non presente"
  fi
}

stop_container "$NAME"

# Regola pf: file vuoto (così un reload di /etc/pf.conf non la ripristina)
# e anchor svuotato subito. Senza questo, il traffico 80/443 dei client LAN
# resterebbe instradato verso un IP non più attivo.
sudo tee /etc/pf.anchors/com.mitm.route < /dev/null > /dev/null
sudo pfctl -a com.mitm.route -F rules 2> /dev/null

if [ "$ALL" = true ]; then
  stop_container "$DHCP_NAME"
  sudo tee /etc/pf.anchors/com.mitm.dhcp < /dev/null > /dev/null
  sudo pfctl -a com.mitm.dhcp -F nat 2> /dev/null   # rdr = regole di traduzione
fi

# Chiude le connessioni dei client LAN ancora legate alle vecchie regole
sudo pfctl -k 192.168.3.0/24 2> /dev/null

echo "Intercettazione disattivata: i client LAN escono su Internet via NAT su en0"
if [ "$ALL" = true ]; then
  echo "DHCP fermo: i client non rinnovano il lease (ripristinare il DHCP server sul router se serve)"
fi
```

Dopo l'arresto i client LAN continuano a navigare direttamente (NAT su `en0`, anchor `com.mitm.nat`), senza mitmproxy. Per riprendere: `./start-mitm.sh`.

Lo script lascia volutamente attivi:
- **pf**: non si usa `pfctl -d`, che lo disabiliterebbe per tutto il sistema (inclusi servizi macOS/MDM che lo usano); con gli anchor vuoti pf non ha effetti sul traffico LAN;
- **IP forwarding**: spegnerlo (`sudo sysctl -w net.inet.ip.forwarding=0`, e rimuovere la riga da `/etc/sysctl.conf` per renderlo permanente) toglie Internet ai client LAN.

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

## Limiti noti / cose da verificare ancora

- **QUIC/HTTP3 su UDP 443** non viene intercettato (`route-to`/`REDIRECT` sono solo TCP) e, non essendoci una regola che lo blocchi, esce via NAT su `en0`. Client come Safari/Chrome su iOS possono usarlo di default per molti siti, con traffico che bypassa mitmproxy senza errori visibili. Per forzare il fallback su TCP si può aggiungere nell'heredoc dello script (l'anchor `com.mitm.route` viene rigenerato a ogni esecuzione): `block in quick on en7 inet proto udp from 192.168.3.0/24 to any port 443`.
- **Il Mac è un punto singolo di guasto per la LAN**: con il DHCP in relay, a Mac spento o scollegato i client non ottengono/rinnovano il lease e non hanno gateway. Per tornare alla situazione standard: router in modalità DHCP server (i client riprendono gateway `192.168.3.1` al rinnovo successivo o riconnettendosi).
- **Rinnovi DHCP via relay da verificare nel tempo**: il primo lease tramite il relay Zyxel funziona (iPhone → `192.168.3.168`). Non è ancora verificato che il router inoltri anche i rinnovi unicast indirizzati a `192.168.3.1`; se non lo facesse, i client rinnovano comunque in broadcast alla scadenza di T2 (~52 min con lease di 1h). Da controllare in `container logs mitm-dhcp` dopo ~30 min (T1).
- **DNS `192.168.3.2` offerto ai client senza un servizio DNS dietro**: `dnsmasq.conf` include `192.168.3.2` come terzo DNS, ma sul Mac nessuno risponde sulla porta 53 (e il DNS di `container` ascolta solo su `127.0.0.1`). Se un client sceglie quel server, le sue query vanno in timeout finché non ripiega sugli altri.
- **IPv6 non funzionante** nella rete del container (timeout puri) — non bloccante per l'uso attuale (traffico IPv4), ma da tenere presente se in futuro serve intercettare anche IPv6.
- **Stati pf dopo un cambio IP**: le connessioni già aperte restano legate al vecchio IP del container fino alla scadenza dello stato; le nuove usano la regola aggiornata.
- Le regole duplicate in `iptables -t nat` a ogni riavvio dell'entrypoint sono gestite con `-F` preventivo, ma vale la pena verificare nel tempo che non si accumulino residui in altri punti (es. se in futuro si aggiungono altre catene).

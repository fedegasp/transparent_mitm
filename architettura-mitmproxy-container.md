# Architettura: Proxy trasparente LAN → mitmproxy in container (macOS)

## Obiettivo

Intercettare il traffico HTTP/HTTPS di dispositivi collegati alla LAN fisica del Mac, instradandolo verso `mitmproxy` in esecuzione dentro una VM Linux gestita da Apple `container`. Questa architettura permette il transparent proxying della rete LAN.

Lo stesso container intercetta anche il traffico **del Mac stesso**, solo verso un elenco di domini scelti ([domini-mac.txt](domini-mac.txt)), anche quando il Mac non è collegato alla LAN (`en7`): punto 10.

## Perché questo approccio

- Il Mac è gestito da MDM con **Digital Guardian** (`com.digitalguardian.webproxy`, Network Extension) e **BeyondTrust** (Endpoint Security + Privilege Management), oltre a **Microsoft Defender**.
- L'**Application Firewall di macOS** è gestito centralmente ("Firewall settings cannot be modified from command line on managed Mac computers").
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
                     container: iptables PREROUTING REDIRECT → :7070 (mitmproxy/mitmweb transparent)
                                       │  SO_ORIGINAL_DST → destinazione originale
                                       ▼
                     mitmproxy ──▶ gateway 192.168.64.1 ──▶ NAT vmnet ──en0──▶ Internet

altro traffico LAN (non-HTTP/S) ──en7──▶ Mac: nat on en0 (anchor com.mitm.nat) ──▶ Internet

traffico del Mac (browser) verso <mitm_local> (IP dei domini scelti), TCP 80/443:
  Mac ──out en0──▶ pf: route-to (bridge100 <IP_CONTAINER>)   [src IP di en0, dst invariato]
                                       ▼
                     container: iptables REDIRECT → :7070 ──▶ mitmproxy ──▶ 192.168.64.1
                                       ▼
                     Mac: in bridge100, tag MITM_VM ──▶ nat on en0 ──▶ out en0 (tagged: niente route-to) ──▶ Internet

DNS:
client ──UDP/TCP 53 → 192.168.3.2──en7──▶ Mac pf: rdr (anchor com.mitm.dhcp) → <IP_DHCP>:53
                                              ▼
                     container mitm-dhcp (dnsmasq, cache) ──▶ 192.168.64.1 (resolver del Mac via vmnet)
                                              ──▶ DNS correnti del Mac (quelli di en0)

DHCP:
client ──broadcast──▶ router 192.168.3.1 (relay, giaddr=192.168.3.1)
                          │ unicast UDP → 192.168.3.2:67
                          ▼
                     Mac pf: rdr (anchor com.mitm.dhcp) → <IP_DHCP>:67
                          ▼
                     container mitm-dhcp (dnsmasq) ──risposta──▶ Mac (src riscritto in 192.168.3.2) ──▶ router ──▶ client
                     offre: IP 192.168.3.100–199, gateway 192.168.3.2, DNS 192.168.3.2, server-id 192.168.3.1
```

Le risposte del container verso `192.168.3.x` tornano al Mac via il gateway `192.168.64.1` e vengono inoltrate su `en7`: gli stati pf su macOS sono *floating*, quindi lo stato creato su `en7` copre anche il ritorno su `bridge100`.

Per il DHCP basta un `rdr` (a differenza di mitmproxy, `dnsmasq` non ha bisogno della destinazione originale). Il pacchetto è inoltrato dal kernel verso il container, non consegnato a un processo del Mac, quindi l'Application Firewall non interviene (stesso principio del `route-to`). La regola è ristretta a `on en7 from 192.168.3.1`: il DHCP interno di vmnet su `bridge100` non viene toccato.

Il DNS segue lo stesso schema: i client interrogano il Mac (`192.168.3.2:53`), pf fa `rdr` verso la **stessa istanza di `dnsmasq`** del DHCP. Un `dnsmasq` installato con brew sul Mac non riceverebbe nulla sulla porta 53 (Application Firewall, come mitmproxy). `dnsmasq` inoltra le query al resolver del proprio `/etc/resolv.conf` (`192.168.64.1`, il proxy DNS del Mac esposto da vmnet), che usa i DNS correnti del Mac, cioè quelli ricevuti su `en0`: niente server pubblici (`1.1.1.1` non è raggiungibile su tutte le reti) e niente da riconfigurare passando da casa all'ufficio.

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

`/etc/pf.conf`: copia di riferimento in [pf.conf](pf.conf). Ordine importante: `com.mitm.route` prima di `com.apple/*` per garantire priorità con `quick`, e `rdr-anchor "com.mitm.dhcp"` prima di `rdr-anchor "com.apple/*"` (per le traduzioni vince la prima regola che corrisponde).

Il DHCP (e il DNS, servito dallo stesso container) ha un **anchor separato** (`com.mitm.dhcp`, dichiarato come `rdr-anchor`: le regole `rdr` in un anchor dichiarato solo con `anchor` verrebbero ignorate). Così DHCP e mitmproxy hanno ciascuno il proprio anchor e i propri script (punti 3 e 8): `stop-mitm.sh` rimuove l'intercettazione senza interrompere il DHCP.

`/etc/pf.anchors/com.mitm.nat` (NAT verso Internet per il resto del traffico LAN, non HTTP/S, e per l'egress dei container):
```
nat on en0 inet from 192.168.3.0/24 to any -> (en0)
nat on en0 inet from 192.168.64.0/24 to any -> (en0)
```
La seconda riga **è necessaria**: il NAT della rete dei container lo fa normalmente `InternetSharing` (avviato da `container-network-vmnet`), inserendo i propri anchor pf nel ruleset principale a runtime. Un reload completo (`pfctl -f /etc/pf.conf`) li rimuove, e da quel momento i container non escono più su Internet (mitmproxy riceve le connessioni dei client ma va in timeout verso i server). Con la regola nel nostro anchor l'egress non dipende più da quegli anchor; se sono presenti, vale la prima regola che corrisponde, niente doppio NAT.

`/etc/pf.anchors/com.mitm.route` e `/etc/pf.anchors/com.mitm.dhcp` sono generati dal daemon `com.mitm.pf` (punto 9) con l'IP corrente dei container, che non è fisso; i modelli delle regole sono in [daemon/mitm-pf-apply](daemon/mitm-pf-apply):
- `com.mitm.route`: `route-to (bridge100 <IP_CONTAINER>)` del TCP 80/443 in ingresso su `en7` dalla LAN. L'interfaccia nel `route-to` è quella **bridge di vmnet** (`bridge100`), non `en7`. Contiene anche le regole per il traffico del Mac verso la tabella `<mitm_local>` (punto 10).
- `com.mitm.dhcp`: `rdr` verso `<IP_DHCP>` del relay DHCP (UDP 67 da `192.168.3.1` a `192.168.3.2`) e delle query DNS (UDP/TCP 53 dalla LAN a `192.168.3.2`). Il DNS è ristretto alle query **verso il Mac**: un client con DNS configurato a mano (es. `8.8.8.8`) esce via NAT come prima.

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
- container **inesistente** → lo crea con `container run` (per mitmproxy è l'unico momento in cui vengono lette `MITM_UI`, default `console`, e `MITM_WEB_PASSWORD`, default `password`);
- container **fermo** → `container start`;
- container **in esecuzione** → nessuna azione sul container.

Poi attendono che l'IP sia assegnato (fino a ~10s), e rigenerano e ricaricano il proprio anchor; `start-mitm.sh` ricava anche il bridge.

Vanno eseguiti **senza sudo** (`container run/inspect` richiedono la sessione utente) e non chiedono privilegi: invece di scrivere gli anchor, scrivono l'IP corrente in un file di stato in `/usr/local/var/mitm-pf/` (`dhcp` / `route`) e attendono (fino a ~10s) che il LaunchDaemon di root `com.mitm.pf` abbia applicato la regola (punto 9). Si portano nella propria directory (`cd "$(dirname "$0")"`), quindi i volumi relativi (`./mitmproxy`, `./export`, `./dhcp`) funzionano da qualunque directory li si lanci.

Le funzioni comuni (`start_existing`, `container_net`, `write_state`, `wait_anchor`) sono **duplicate** nei due script invece che in un file condiviso: così `start-dhcp.sh` non dipende da nient'altro del progetto.

File: [start-dhcp.sh](start-dhcp.sh), [start-mitm.sh](start-mitm.sh).

### 4. Container — immagine (`Containerfile`)

Base `python:3.13-slim-bookworm` e **non** `debian:bookworm-slim`: Debian bookworm ha Python 3.11, e le versioni recenti di mitmproxy richiedono Python ≥ 3.12 (dalla 11.1). Con `pip install mitmproxy` su bookworm si ottiene in silenzio la **11.0.2**, che non ha l'opzione `web_password` (mitmweb esce con errore) e manca della protezione della web UI introdotta nelle versioni successive. La versione è fissata per build riproducibili.

File: [Containerfile](Containerfile). `container build` lo trova automaticamente (altrimenti `-f Containerfile`).

### 5. Container — entrypoint (`entrypoint.sh`)

File: [entrypoint.sh](entrypoint.sh): imposta il REDIRECT `iptables` (80/443 → 7070) e lancia mitmproxy in modalità transparent, con l'interfaccia scelta da `MITM_UI` (punto 7):
- `console` (default): `mitmproxy` (interfaccia testuale) in una sessione `tmux` chiamata `mitm`;
- `web`: `mitmweb`, web UI su `:8081`.

Le due modalità sono alternative: un solo processo può ascoltare su `7070`, e mitmproxy non ha console e web UI insieme.

Punti critici:
- **`iptables -t nat -F PREROUTING` prima di ri-aggiungere le regole**, per evitare duplicati a ogni riavvio.
- **Match `! -s 192.168.64.0/24 -m addrtype ! --dst-type LOCAL`**: il REDIRECT vale per i client LAN (`192.168.3.0/24`) e per il Mac (IP di `en0`, che cambia tra casa e ufficio: punto 10), non per la rete dei container né per le connessioni dirette al container. Prima il match era `-s 192.168.3.0/24`: senza filtro sulla sorgente si era osservato un timeout totale dell'egress del container verso Internet (cronologia, punto 8), probabilmente dovuto in realtà agli anchor NAT rimossi (punto 13). **Da verificare** che il nuovo match non riproduca il problema. Una modifica di `entrypoint.sh` richiede `container build` e la ricreazione del container (`./stop-mitm.sh --rm && ./start-mitm.sh`).
- **`tini` come PID 1** (via `ENTRYPOINT`) e **mitmproxy/mitmweb in un ciclo `while`**: è un processo figlio che può essere killato/riavviato senza fermare il container. Senza il ciclo, all'uscita di mitmweb termina l'entrypoint e con esso il container.
- **Console: due cicli**. Quello dentro la sessione `tmux` riavvia `mitmproxy` dopo un'uscita (`q`) senza chiudere la sessione, quindi chi è collegato vede subito la nuova istanza. Quello esterno, nell'entrypoint, ricrea la sessione se viene chiusa (`tmux kill-session`) e tiene in vita il container: `tmux new-session -d` torna subito, senza il ciclo l'entrypoint terminerebbe. In modalità console `container logs mitmproxy.test` non mostra l'output di mitmproxy (è nella sessione `tmux`, eventi con `E`).
- **Directory corrente `/export`** (volume `./export`, punto 7): i percorsi relativi dei comandi che scrivono su disco finiscono lì.
- **`block_global=false`**: `block_global` blocca le connessioni da **client** con IP pubblico (non riguarda la destinazione). I client LAN `192.168.3.x` sono privati, quindi non è strettamente necessario; lo si tiene per non avere sorprese se un client arriva con IP non privato.
- **Password della web UI** (solo `MITM_UI=web`) **da variabile d'ambiente** (`MITM_WEB_PASSWORD`, passata con `container run -e`), non scritta nell'immagine. `start-mitm.sh` la passa sempre, con default `password` se non impostata. Se la variabile mancasse del tutto (container avviato a mano), mitmweb genera un token casuale stampato nei log (`container logs mitmproxy.test`). La web UI è raggiungibile anche dai client LAN (il Mac inoltra `192.168.3.0/24` → `192.168.64.0/24`): con la password di default chiunque sulla LAN può accedervi.

### 6. Container DHCP e DNS (`dhcp/`)

Container separato `mitm-dhcp` con `dnsmasq`, che fa sia da DHCP sia da DNS (con cache) per la LAN: raggiunto dal relay del router e dalle query DNS dei client verso il Mac tramite gli `rdr` di pf (vedi *Flusso del traffico*). È separato da `mitmproxy.test` perché ha un ciclo di vita diverso, con script propri (`start-dhcp.sh` / `stop-dhcp.sh`) che non dipendono da mitmproxy: `stop-mitm.sh` ferma l'intercettazione ma lascia attivo il DHCP, così i client continuano a ricevere/rinnovare il lease e navigano via NAT del Mac.

Alternative scartate:
- **DHCP/DNS server su macOS** (`dnsmasq`/`kea` da brew): processo in ascolto sul Mac, bloccato dall'Application Firewall come mitmproxy (cronologia, punto 1). Provato anche per il DNS: la porta 53 non riceve nulla.
- **DNS pubblici fissi** (`1.1.1.1`, `1.0.0.1`): non raggiungibili su tutte le reti (es. reti aziendali che consentono solo i propri DNS).
- **Upstream DNS letti da `en0`** (`ipconfig getoption en0 domain_name_server`) e scritti in un `resolv-file` per `dnsmasq`: richiede un job che segua i cambi di rete. Il resolver di vmnet (`192.168.64.1`) li segue già da solo, e rispetta anche la configurazione DNS completa del Mac (resolver per dominio, VPN).
- **`bootpd` di macOS** (`/etc/bootpd.plist`): lo stesso file è usato da Condivisione Internet/vmnet, rischio di interferire con la rete dei container.
- **Relay puntato direttamente all'IP del container**: l'IP cambia a ogni riavvio, e il router invierebbe le richieste al proprio gateway, non al Mac.

File: [dhcp/Containerfile](dhcp/Containerfile) e [dhcp/dnsmasq.conf](dhcp/dnsmasq.conf). La configurazione e i lease stanno nel volume `/data` (`./dhcp` sul Mac): una modifica a `dnsmasq.conf` richiede solo `container stop/start mitm-dhcp`, non un rebuild. `dnsmasq` gira con `--user=root`, altrimenti cede i privilegi e non può scrivere il file dei lease nel volume.

Punti critici:
- **Netmask esplicita nel `dhcp-range`**: per le reti servite via relay `dnsmasq` non può ricavarla dalle interfacce locali.
- **`dhcp-proxy=192.168.3.1`**: normalmente, dopo il primo lease, il client rinnova in **unicast verso il server-ID** (option 54), che sarebbe l'IP del container — raggiungibile solo finché non cambia. Con `dhcp-proxy` il server-ID è l'indirizzo del relay, e anche i rinnovi passano dal router → Mac → container.
- **`dhcp-authoritative`**: `dnsmasq` è l'unico server DHCP della LAN; risponde subito anche a client che hanno ancora un lease del vecchio DHCP del router, invece di ignorarli.
- **Lease di 1h**: una modifica di gateway/DNS arriva ai client entro ~30 min (T1).
- **Range `.100–.199`**: fuori da `.1` (router), `.2` (Mac) e dagli IP statici già in uso (es. `.249`).
- **`--cap-add NET_ADMIN`** è obbligatorio anche qui: senza, `dnsmasq` esce all'avvio con `process is missing required capability NET_ADMIN`.
- **Lease persistenti** in `./dhcp/dnsmasq.leases`: dopo un riavvio del container `dnsmasq` non riassegna IP già in uso.
- **DNS senza `port=0`**: la porta 53 è attiva. Nessuna direttiva `server=`: `dnsmasq` usa il `nameserver` di `/etc/resolv.conf` del container (`192.168.64.1`, impostato da `container`), quindi anche un cambio di subnet della rete `default` non richiede modifiche. All'avvio il log mostra `using nameserver 192.168.64.1#53`.
- **`dns-server=192.168.3.2` esplicito**: senza, `dnsmasq` offrirebbe come DNS il proprio IP (quello del container, non raggiungibile dai client e variabile).
- **Query da subnet non locali accettate**: le query arrivano da `192.168.3.x`, che non è una subnet del container. `dnsmasq` 2.90 lanciato direttamente (senza lo script init di Debian) non applica `--local-service`; se lo facesse, il log all'avvio riporterebbe `DNS service limited to local subnets`.

Configurazione del router (Zyxel): DHCP in modalità **Relay**, server `192.168.3.2`. Nessun altro server DHCP deve restare attivo sulla LAN.

Log DHCP: `container logs mitm-dhcp` (per vedere anche le query DNS, aggiungere `log-queries` a `dnsmasq.conf`).

Verifica del DNS, direttamente dal Mac (UDP; con `+tcp` per il TCP):
```bash
dig @$(container inspect mitm-dhcp | jq -r '.[0].status.networks[0].ipv4Address' | cut -d/ -f1) example.com
```
Così si prova `dnsmasq` e il suo upstream, non l'`rdr` di `192.168.3.2:53`: quello va verificato da un client LAN.

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

Interfaccia (variabile `MITM_UI`, letta solo alla creazione del container):
- `console` (default): `mitmproxy` in `tmux`. Ci si collega dal Mac con `container exec` (niente ssh: non serve, ed esporrebbe una porta in più anche alla LAN):
  ```bash
  container exec -it mitmproxy.test tmux attach -t mitm
  ```
  `Ctrl-b d` stacca il terminale lasciando mitmproxy in esecuzione; `q` dentro mitmproxy lo riavvia (flussi persi), non ferma il container.
- `web`: `mitmweb`, `http://mitmproxy.test:8081`. Password della web UI: `password`, oppure `MITM_UI=web MITM_WEB_PASSWORD='<password>' ./start-mitm.sh`.

`start-mitm.sh` stampa alla fine il comando o l'URL giusto per il container esistente.

Dopo un riavvio (`container stop`, reboot del Mac) basta rieseguire `./start-mitm.sh`: riavvia i container fermi e aggiorna le regole pf. Dopo un **reboot del Mac** i servizi di `container` non ripartono da soli (`apiserver is not running and not registered with launchd`): prima va lanciato `container system start` (vedi *Limiti noti*).

Per cambiare interfaccia, password o immagine (dopo un nuovo `container build`) il container va ricreato, perché gli script non toccano un container esistente:
```bash
./stop-mitm.sh --rm
MITM_UI=web MITM_WEB_PASSWORD='<password>' ./start-mitm.sh
```
Per il container DHCP: `./stop-dhcp.sh --rm && ./start-dhcp.sh`.

#### Web UI dal Mac (`MITM_UI=web`): `http://mitmproxy.test:8081`

`container` include un DNS locale (`container-apiserver`, in ascolto su `127.0.0.1:2053`). `sudo container system dns create test` crea `/etc/resolver/containerization.test`, che dice a macOS di risolvere i nomi `*.test` tramite quel server. Il nome segue da solo l'IP del container: niente da aggiornare dopo un riavvio.

Il DNS integrato risolve **solo i container il cui nome è `<nome>.<dominio>`**: per questo il container di mitmproxy si chiama `mitmproxy.test` (`NAME="mitmproxy.$DNS_DOMAIN"` in `start-mitm.sh`). Un container chiamato `mitm-proxy` non viene risolto, né come `mitm-proxy` né come `mitm-proxy.test`, anche se creato con `--dns-domain test` (vedi [Mcrich23/Container-Compose#81](https://github.com/Mcrich23/Container-Compose/issues/81)).

`--dns-domain test` imposta solo il DNS *dentro* il container (`/etc/resolv.conf` → `nameserver 192.168.64.1`, `domain test`); la risoluzione dei nomi esterni resta funzionante. Per il nome sul Mac conta solo il nome del container.

Il nome vale **solo sul Mac**: il server DNS di `container` risponde su `127.0.0.1`, i client LAN non possono usarlo.

Per verificare la risoluzione e la web UI da terminale (senza password mitmweb risponde `403` con la pagina di login, con `?token=<password>` risponde `200`):
```bash
dscacheutil -q host -a name mitmproxy.test
curl -s -o /dev/null -w '%{http_code} %{remote_ip}\n' http://mitmproxy.test:8081/
```

Per fermare: `./stop-mitm.sh` (punto 8).

Note:
- `--cap-add NET_ADMIN` è **obbligatorio**: senza questa capability, `iptables` fallisce con `Permission denied (you must be root)` anche se il processo gira come root a livello di utente Linux (il container di default ha un set di capability ridotto).
- `--volume ./mitmproxy:/root/.mitmproxy` rende persistente la configurazione di mitmproxy del container, CA inclusa. Il percorso è relativo alla directory del progetto, e `./mitmproxy` deve esistere (altrimenti `container run` fallisce con `path './mitmproxy' does not exist`). Per riusare la CA già installata sui dispositivi, copiarla da `~/.mitmproxy` (`mitmproxy-ca.pem`, `mitmproxy-ca-cert.*`, `mitmproxy-dhparam.pem`); se la directory è vuota mitmproxy genera una **nuova** CA da reinstallare sui dispositivi. Se emergono errori di permessi, `chmod -R 777 ./mitmproxy` sul Mac.
- Una directory dedicata evita che il container carichi `~/.mitmproxy/config.yaml` dell'uso sul Mac (con i suoi `ignore_hosts`, `ssl_insecure`, …). Un eventuale `config.yaml` in `./mitmproxy` viene caricato: le opzioni da riga di comando (`mode`, `listen_port`, `web_port`, …) hanno la precedenza, tutto il resto viene applicato.
- `--volume ./export:/export`: directory di lavoro di mitmproxy, per avere sul Mac i file salvati dai suoi comandi, ad esempio `:save.file @shown flussi.mitm` (o `w`), `:export.file curl @focus richiesta.sh`, `:cut.save @focus response.content corpo.bin`. I percorsi relativi finiscono in `./export`; quelli assoluti (es. `/tmp/x`) restano nel container. Come `./mitmproxy`, la directory deve esistere: `start-mitm.sh` la crea. I file compaiono sul Mac con l'utente corrente come proprietario. È ignorata da git.
  Si monta una cartella del progetto e non la Scrivania: `~/Desktop` è protetta da TCC (l'accesso lo farebbe il processo di virtualizzazione di `container`, e su un Mac gestito l'autorizzazione può essere negata da policy), e non serve dare a un processo root che elabora traffico non fidato l'accesso in scrittura a tutta la Scrivania. Per averla a portata di mano: `ln -s "$PWD/export" ~/Desktop/mitm-export`.
- `MITM_WEB_PASSWORD` in chiaro è visibile in `container inspect mitmproxy.test` e nella lista processi del container. Per evitarlo, `web_password` accetta anche un hash argon2 (mitmweb stesso lo suggerisce all'avvio).

### 8. Arresto (`stop-mitm.sh`, `stop-dhcp.sh`)

Come per l'avvio, due script separati. `stop-mitm.sh` **non ferma il DHCP**: i client mantengono il Mac come gateway e navigano via NAT, senza intercettazione. Per fermare tutto:
```bash
./stop-mitm.sh && ./stop-dhcp.sh
```

Fermare solo il container **non basta**: la regola pf resterebbe attiva verso un IP non più in ascolto (con `route-to`, HTTP/HTTPS bloccati per tutta la LAN). Ogni script:
- ferma il proprio container se è in esecuzione (con `--rm` lo rimuove anche — necessario per cambiare interfaccia, password o immagine);
- svuota il proprio file di stato; il daemon `com.mitm.pf` (punto 9) allora:
  - **svuota il file** dell'anchor (`/etc/pf.anchors/com.mitm.route` o `com.mitm.dhcp`), così un reload di `/etc/pf.conf` (es. al riavvio del Mac) non ripristina la vecchia regola;
  - svuota subito l'anchor in pf (`-F rules` per il `route-to`, `-F nat` per l'`rdr`: le `rdr` sono regole di traduzione, `-F rules` non le toccherebbe);
  - chiude gli stati pf legati alla vecchia regola: per mitmproxy quelli dei client LAN (`pfctl -k 192.168.3.0/24`, include anche gli stati del relay DHCP, che si ricreano al pacchetto successivo), per DHCP/DNS quelli LAN → Mac (`pfctl -k 192.168.3.0/24 -k 192.168.3.2`: relay del router e query DNS dei client).

Dopo `stop-dhcp.sh` i client non possono rinnovare il lease: se il Mac smette di fare da gateway, va rimesso il router in modalità DHCP server.

Come gli script di avvio, vanno eseguiti **senza sudo** e non chiedono privilegi. Si possono rilanciare anche se i container sono già fermi o non esistono.

File: [stop-mitm.sh](stop-mitm.sh), [stop-dhcp.sh](stop-dhcp.sh).

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
  - `dhcp` → `<IP dnsmasq>` (vuoto = nessun DHCP/DNS);
  - `domains` → copia di [domini-mac.txt](domini-mac.txt), scritta da `start-mitm.sh` e dal LaunchAgent `com.mitm.domains` a ogni modifica del file (punto 10).
- **Validazione**: il contenuto è scrivibile dall'utente, quindi non viene mai eseguito né copiato così com'è; il daemon accetta solo `bridge<N>`, indirizzi IPv4 e nomi di dominio (regex, al massimo 64) e genera la regola da un modello fisso. Qualsiasi altro contenuto svuota la regola (o, per i domini, viene ignorato).
- **Ogni 60s** (`StartInterval`): con l'intercettazione attiva il daemon ririsolve i domini e aggiorna la tabella `<mitm_local>`; se non cambia nulla non tocca pf.
- **Script di root in `/usr/local/libexec/mitm-pf-apply`** (root:wheel, 755), non nella directory del progetto: altrimenti chi può scrivere nel progetto potrebbe far eseguire codice a root.
- **Nessun reload inutile**: l'anchor viene ricaricato (e gli stati chiusi) solo se la regola cambia.
- **Al boot** (`RunAtLoad`): i file di stato **precedenti all'ultimo boot** (`kern.boottime`) sono ignorati, quindi le regole della sessione precedente vengono svuotate. Risolve il `route-to` verso un IP inesistente rimasto dopo un riavvio con mitmproxy attivo.
- Log: `/var/log/mitm-pf.log`.

File: [daemon/mitm-pf-apply](daemon/mitm-pf-apply) (script di root, contiene i modelli delle regole) e [daemon/com.mitm.pf.plist](daemon/com.mitm.pf.plist) (LaunchDaemon con `RunAtLoad` e `WatchPaths` sulla directory di stato).

Installazione (una volta, da amministratore) con [daemon/install.sh](daemon/install.sh), che copia lo script in `/usr/local/libexec`, crea la directory di stato (di proprietà dell'utente) e carica il daemon:
```bash
sudo ./daemon/install.sh
```
Va rilanciato a ogni modifica di `daemon/mitm-pf-apply`: il daemon esegue la copia installata, non il file del progetto.

Verifica: `sudo launchctl print system/com.mitm.pf | grep -E 'state|last exit'`.

#### Avvio del DHCP al login (LaunchAgent `com.mitm.dhcp`)

I servizi di `container` sono job launchd della **sessione utente**: dopo un reboot non sono registrati (`apiserver is not running and not registered with launchd`) e prima del login non possono girare. Il LaunchAgent, a ogni login, lancia `container system start` (idempotente: con i servizi già attivi termina con successo) e poi `start-dhcp.sh`. mitmproxy **non** parte al login: si avvia a mano con `./start-mitm.sh`.

Definizione in [launchagent/com.mitm.dhcp.plist](launchagent/com.mitm.dhcp.plist) (`container` è in `/usr/local/bin`, quindi il plist imposta `PATH`, assente da quello di default di launchd). Il plist del progetto non contiene percorsi assoluti: launchd non espande `~` né `$HOME`, quindi `install.sh` sostituisce i segnaposto `__PROJECT_DIR__` e `__HOME__` con la directory del progetto e la home dell'utente. Se il progetto viene spostato, va rilanciato `./launchagent/install.sh`, e i container vanno ricreati (`./stop-mitm.sh --rm`, `./stop-dhcp.sh --rm`, poi `./start-mitm.sh`): i volumi (`./mitmproxy`, `./dhcp`) sono registrati con il percorso assoluto al momento del `container run`, e `container start` fallisce con `mount source path '...' does not exist`.

#### Modifiche di `domini-mac.txt` applicate al salvataggio (LaunchAgent `com.mitm.domains`)

Il LaunchAgent ha `WatchPaths` su [domini-mac.txt](domini-mac.txt): a ogni salvataggio copia il file nello stato `domains` (rename atomico), e il daemon `com.mitm.pf`, attivato dalla modifica della directory di stato, aggiorna la tabella `<mitm_local>` (punto 10). Il watch scatta sia con la scrittura sul posto sia con il salvataggio atomico degli editor (file nuovo + rename). launchd lo esegue al massimo ogni 10s (`ThrottleInterval` di default): una modifica ravvicinata viene applicata con qualche secondo di ritardo. Con l'intercettazione spenta il daemon ignora l'elenco; `start-mitm.sh` lo copia comunque all'avvio.

Il watch è nella sessione utente e non nel daemon di root: così il daemon non deve conoscere la directory del progetto.

Definizione in [launchagent/com.mitm.domains.plist](launchagent/com.mitm.domains.plist).

#### Installazione dei LaunchAgent

`install.sh` installa (o rimuove) tutti i plist `com.mitm.*.plist` di `launchagent/`. Si usa da utente normale, senza sudo:
```bash
./launchagent/install.sh
./launchagent/install.sh --remove
```

Log: `~/Library/Logs/mitm-dhcp.log` e `~/Library/Logs/mitm-domains.log`. Stato: `launchctl print gui/$(id -u)/com.mitm.dhcp | grep -E 'state|last exit'` (idem per `com.mitm.domains`).

### 10. Traffico del Mac verso domini scelti (`domini-mac.txt`)

Il browser del Mac passa da mitmproxy solo per i domini elencati in [domini-mac.txt](domini-mac.txt), con o senza `en7`: servono solo il container ed `en0`. Si attiva e si disattiva insieme all'intercettazione LAN (`start-mitm.sh` / `stop-mitm.sh`). Le modifiche dell'elenco si applicano al salvataggio del file, entro pochi secondi (LaunchAgent `com.mitm.domains`, punto 9); senza il LaunchAgent basta rilanciare `./start-mitm.sh`.

Perché non basta una rotta (`route add -host repubblica.it -interface bridge100`):
1. `-interface` tratta la destinazione come diretta su `bridge100`: ARP per l'IP del sito, nessuno risponde. Servirebbe il container come gateway.
2. Anche con il gateway si crea un loop: la connessione di mitmproxy verso lo stesso IP passa dal Mac, trova la stessa rotta e torna al container. La tabella di routing decide solo sulla destinazione.
3. Il REDIRECT nel container valeva solo per `-s 192.168.3.0/24`.
4. Una rotta vale per un IP, non per un dominio, e le CDN usano più IP che cambiano.

Regole pf (in `com.mitm.route`, generate dal daemon, modello in [daemon/mitm-pf-apply](daemon/mitm-pf-apply)):
```
table <mitm_local> persist
pass in on bridge100 inet proto tcp from <IP_CONTAINER> to any port { 80, 443 } tag MITM_VM keep state
pass out quick on en0 route-to (bridge100 <IP_CONTAINER>) inet proto tcp from (en0) to <mitm_local> port { 80, 443 } ! tagged MITM_VM keep state
block return out quick on en0 inet6 proto tcp from any to <mitm_local> port { 80, 443 }
block return out quick on en0 proto udp from any to <mitm_local> port 443
```
- **`route-to` in uscita** su `en0`: come per la LAN il pacchetto non viene tradotto, il REDIRECT avviene nel container (`SO_ORIGINAL_DST`). La sorgente resta l'IP di `en0`: il container risponde via `192.168.64.1` e lo stato pf (floating) copre il ritorno su `bridge100`.
- **Tag anti-loop**: le regole di filtro in uscita vedono gli indirizzi **dopo il NAT**, quindi le connessioni di mitmproxy verso Internet hanno anch'esse sorgente `(en0)` su `en0`. Vengono marcate `MITM_VM` entrando da `bridge100` ed escluse dal `route-to` con `! tagged`. Il tag è *sticky* (resta anche se una regola successiva decide): la regola che lo applica non è `quick` e non scavalca le regole `com.apple/*` su `bridge100`. È ristretta all'IP di mitmproxy e alle porte 80/443.
- **IPv6 e QUIC respinti** verso `<mitm_local>` (RST / ICMP unreachable): il container non gestisce IPv6 e il `route-to` è solo TCP. Il browser ripiega subito su TCP IPv4, che viene intercettato. Anche i client LAN, verso questi IP, perdono QUIC (escono via NAT su `en0`).
- **Tabella `<mitm_local>`**: il daemon risolve i domini con `dscacheutil` (resolver e cache di sistema, gli stessi del browser) e tiene gli IP visti negli **ultimi 15 minuti**: CloudFront (repubblica.it) cambia insieme di IP a ogni scadenza del TTL (60s), e il browser può usarne uno ottenuto prima dell'ultima risoluzione. File generati: `/etc/pf.anchors/com.mitm.local` (IP correnti) e `com.mitm.local.seen` (`<ora dell'ultima risoluzione> <IP> <dominio>`). Grazie al dominio annotato, gli IP di un dominio **tolto dall'elenco** escono subito dalla tabella invece che dopo 15 minuti, e il daemon ne chiude gli stati: le connessioni già aperte del browser cadono e si riaprono senza intercettazione. Gli IP semplicemente scaduti, invece, non chiudono gli stati. La tabella **non** è caricata da `pf.conf`: i nomi non vengono risolti al boot (rete assente = caricamento fallito).
- **Stop o cambio IP del container**: il daemon chiude anche gli stati verso gli IP della tabella (`pfctl -k 0.0.0.0/0 -k <IP>`), così le connessioni del browser verso il vecchio container cadono subito invece di restare appese.

Ogni nome usato dal sito va elencato (`repubblica.it` e `www.repubblica.it` sono distinti, niente wildcard); risorse su altri domini (CDN di immagini, script) non sono intercettate se non sono in elenco.

**CA di mitmproxy sul Mac**: `./mitmproxy/mitmproxy-ca-cert.pem`, da aggiungere come attendibile al portachiavi (Safari e Chrome usano quello di sistema; Firefox ha un archivio proprio, oppure `security.enterprise_roots.enabled`). Senza, il browser mostra un errore di certificato sui domini in elenco. Su un Mac gestito da MDM l'aggiunta di una root CA può essere limitata da policy.

Verifica:
```bash
sudo pfctl -a com.mitm.route -t mitm_local -T show
sudo pfctl -a com.mitm.route -vsr
curl -sv -o /dev/null https://www.repubblica.it/ 2>&1 | grep -i issuer
```
Con l'intercettazione attiva l'issuer è `mitmproxy`, e il flusso compare in mitmproxy (console o web UI) con client l'IP di `en0`. Oggi (senza intercettazione) è `Amazon RSA 2048 M04`: Digital Guardian non fa ispezione TLS su queste connessioni.

## Problemi diagnosticati durante la costruzione (cronologia)

1. **Application Firewall di macOS blocca mitmproxy in ascolto sul Mac** → SYN mai risposto, gestione centralizzata da MDM, non modificabile via CLI. Root cause della decisione di spostare mitmproxy in un container.
2. **`rdr` verso `127.0.0.1` non funzionava** → sospetto anti-spoofing su loopback da sorgente esterna; risolto (poi superato) instradando verso l'IP reale/il container invece che verso loopback.
3. **`FileNotFoundError` in mitmproxy transparent mode dentro il container** → causato dal fare NAT su macOS (`rdr`) invece che dentro il container: mitmproxy su Linux recupera la destinazione originale via `getsockopt(SO_ORIGINAL_DST)`, che richiede che il redirect avvenga nello stesso kernel. Risolto passando a `route-to` (pf instrada senza tradurre) + `iptables REDIRECT` locale al container.
4. **Container non restava in esecuzione** → `iptables` falliva per mancanza della capability `NET_ADMIN`. Risolto con `--cap-add NET_ADMIN`.
5. **IP del container non fissabile** → `--network` supporta solo `mac`/`mtu`, non `ip`. Risolto con script che legge l'IP a runtime (`container inspect`) e rigenera la regola pf.
6. **`container inspect` falliva se l'intero script girava con `sudo`** → il servizio `container` è legato alla sessione utente, non root. Risolto elevando solo i comandi che scrivono su `/etc` e ricaricano `pf`, non l'intero script.
7. **Traffico non visibile / connessioni appese** → `route-to` puntava all'interfaccia sbagliata (`en7` invece del bridge vmnet `bridge100`) — il container non è raggiungibile da `en7`. Ora lo script ricava il bridge dal gateway del container.
8. **Egress del container in timeout totale dopo aver attivato il REDIRECT** → risolto aggiungendo `-s 192.168.3.0/24` al match. La causa esatta non è chiarita: in netfilter `PREROUTING` non vede il traffico generato localmente e le risposte in ingresso hanno porta *sorgente* 80/443, non di destinazione; il filtro resta comunque corretto perché limita il REDIRECT ai soli client LAN.
9. **Rete dedicata `mitm-net` non necessaria** → una rete creata con `container network create --subnet 192.168.70.0/24` ottiene un proprio bridge (non `bridge100`) e rende incoerenti subnet/gateway/interfaccia del `route-to`. Si usa la rete `default`.
10. **mitmproxy vecchio su Debian bookworm** → Python 3.11 ⇒ pip installa mitmproxy 11.0.2, senza `web_password`. Risolto con immagine base `python:3.13-slim-bookworm` e versione fissata.
11. **Configurazione di rete manuale sui device** → il DHCP del router non permette un gateway diverso da sé stesso. Risolto con DHCP relay del router verso il Mac + `rdr` pf + `dnsmasq` in container (punto 6), che assegna il Mac come gateway.
12. **Container DHCP che si ferma subito dopo l'avvio** → `dnsmasq` richiede `NET_ADMIN` per il DHCP. Risolto con `--cap-add NET_ADMIN` anche su `mitm-dhcp`.
13. **DHCP ok ma il telefono non naviga** → mitmweb riceveva le connessioni (`192.168.3.168`) ma andava in timeout verso tutti i server (`Connect call failed … Errno 110`); dal container falliva anche `curl https://example.com`. Causa: il reload completo di `/etc/pf.conf` (fatto per aggiungere `com.mitm.dhcp`) aveva rimosso gli anchor NAT inseriti a runtime da `InternetSharing` per `192.168.64.0/24`. Risolto aggiungendo `nat on en0 inet from 192.168.64.0/24 to any -> (en0)` a `com.mitm.nat` e ricaricando solo quell'anchor (`pfctl -a com.mitm.nat -f …`). Alternativa senza pf: `container system stop` / `container system start` (poi `./start-mitm.sh`), ma il problema si ripresenterebbe al successivo reload completo.
14. **Web UI raggiungibile solo digitando l'IP del container** (che cambia a ogni riavvio) → risolto con il DNS integrato di `container` (`container system dns create test`). Il primo tentativo non risolveva nulla (NXDOMAIN) neanche per container creati con `--dns-domain test`: il DNS registra solo i container il cui nome è già `<nome>.<dominio>`. Rinominato il container da `mitm-proxy` a `mitmproxy.test`.
15. **Dopo un reboot il telefono non navigava e nulla ripartiva** → i servizi di `container` non si registrano da soli dopo il reboot, e `com.mitm.route` conteneva ancora il `route-to` verso l'IP del container della sessione precedente (ricaricato da `pf.conf` all'avvio). Risolto con il LaunchDaemon `com.mitm.pf` (svuota al boot le regole con file di stato precedenti al boot) e il LaunchAgent `com.mitm.dhcp` (avvia `container` e il DHCP al login). Il daemon elimina anche i prompt `sudo` degli script.
16. **DNS pubblici non raggiungibili su alcune reti** → i client ricevevano `1.1.1.1`/`1.0.0.1`, bloccati su reti che consentono solo i propri DNS; `dnsmasq` installato con brew sul Mac non riceveva nulla sulla porta 53 (Application Firewall). Risolto attivando il DNS nella stessa istanza `dnsmasq` del DHCP, con `rdr` pf `192.168.3.2:53` → container e upstream `192.168.64.1` (resolver del Mac, quindi i DNS di `en0`). Ai client viene offerto solo `192.168.3.2`.

## Limiti noti / cose da verificare ancora

- **Traffico del Mac (punto 10) provato solo con `curl`**: con `example.com` aggiunto a `domini-mac.txt`, `curl https://example.com/` dal Mac risponde con issuer `mitmproxy`, quindi `route-to`, tag anti-loop, REDIRECT nel container, egress di mitmproxy e ritorno verso l'IP di `en0` funzionano. Tolto il dominio, l'issuer torna quello originale (Cloudflare) entro ~15s. Da provare con un browser (Safari/Chrome, CA nel portachiavi) e da controllare i contatori di `pfctl -a com.mitm.route -vsr` (la regola `route-to` su `en0` deve contare solo le connessioni del browser).
- **Intercettazione del Mac per IP, non per nome**: gli IP CloudFront sono condivisi tra molti siti (il certificato di `www.repubblica.it` è quello di `www.lastampa.it`), quindi viene intercettato anche il traffico di altri siti o app che in quel momento usano gli stessi IP. Un'app con certificate pinning su uno di quegli IP fallirebbe. Rimedio possibile: un addon mitmproxy che, per i client non LAN, lascia passare senza intercettare (`ignore_connection`) le connessioni il cui SNI non è in elenco.
- **Browser con DNS proprio** (Chrome/Firefox con DNS-over-HTTPS) possono ottenere IP diversi da quelli risolti dal daemon: quelle connessioni non vengono intercettate.
- **Traffico del Mac solo su `en0`**: con una VPN (`utun*`) o un'altra interfaccia come rotta di default le regole non scattano.

- **QUIC/HTTP3 su UDP 443** non viene intercettato (`route-to`/`REDIRECT` sono solo TCP) e, non essendoci una regola che lo blocchi, esce via NAT su `en0`. Client come Safari/Chrome su iOS possono usarlo di default per molti siti, con traffico che bypassa mitmproxy senza errori visibili. Per forzare il fallback su TCP si può aggiungere alla regola `com.mitm.route` in [daemon/mitm-pf-apply](daemon/mitm-pf-apply) (poi `sudo ./daemon/install.sh`): `block in quick on en7 inet proto udp from 192.168.3.0/24 to any port 443`.
- **Tra boot e login niente DHCP**: i servizi di `container` girano solo nella sessione utente, quindi il DHCP parte al login (LaunchAgent, punto 9), non al boot. Prima del login i client non ottengono/rinnovano il lease. Il daemon pf invece parte al boot e svuota le regole della sessione precedente.
- **Avvio al login provato solo con `launchctl bootstrap`**, non ancora con un vero logout/login o reboot.
- **Il Mac è un punto singolo di guasto per la LAN**: con il DHCP in relay, a Mac spento o scollegato i client non ottengono/rinnovano il lease e non hanno gateway. Per tornare alla situazione standard: router in modalità DHCP server (i client riprendono gateway `192.168.3.1` al rinnovo successivo o riconnettendosi).
- **Rinnovi DHCP via relay da verificare nel tempo**: il primo lease tramite il relay Zyxel funziona (iPhone → `192.168.3.168`). Non è ancora verificato che il router inoltri anche i rinnovi unicast indirizzati a `192.168.3.1`; se non lo facesse, i client rinnovano comunque in broadcast alla scadenza di T2 (~52 min con lease di 1h). Da controllare in `container logs mitm-dhcp` dopo ~30 min (T1).
- **DNS dei client legato al Mac**: `192.168.3.2` è l'unico DNS offerto. Con `mitm-dhcp` fermo (`stop-dhcp.sh`, tra boot e login) i client non risolvono nomi, anche se hanno ancora un lease valido.
- **DNS LAN da provare su un client reale**: verificato `dnsmasq` → `192.168.64.1` (UDP e TCP, da `mitmproxy.test`), non ancora il percorso completo client → `192.168.3.2:53` → `rdr`. I client che hanno il lease precedente ricevono il nuovo DNS al rinnovo (entro ~30 min) o riconnettendosi.
- **IPv6 e DNS**: se il router annuncia via RA un DNS IPv6 (RDNSS), i client possono usarlo al posto di `192.168.3.2`, scavalcando `dnsmasq`.
- **IPv6 non funzionante** nella rete del container (timeout puri) — non bloccante per l'uso attuale (traffico IPv4), ma da tenere presente se in futuro serve intercettare anche IPv6.
- **Stati pf dopo un cambio IP**: le connessioni già aperte restano legate al vecchio IP del container fino alla scadenza dello stato; le nuove usano la regola aggiornata.
- Le regole duplicate in `iptables -t nat` a ogni riavvio dell'entrypoint sono gestite con `-F` preventivo, ma vale la pena verificare nel tempo che non si accumulino residui in altri punti (es. se in futuro si aggiungono altre catene).

# mitm: proxy trasparente LAN → mitmproxy in container (macOS)

Intercetta il traffico HTTP/HTTPS dei dispositivi collegati alla LAN fisica del Mac, e quello del Mac stesso verso i domini scelti in [domini-mac.txt](domini-mac.txt), con `mitmproxy` in una VM Linux gestita da Apple [`container`](https://github.com/apple/container). Il Mac fa da gateway, DHCP e DNS per la LAN; il router resta in DHCP relay verso il Mac.

- [ARCHITETTURA.md](ARCHITETTURA.md): perché e come funziona (pf, container, DHCP, daemon di root), limiti noti.
- [CRONOLOGIA.md](CRONOLOGIA.md): problemi incontrati durante la costruzione e come sono stati risolti.

## Installazione

Requisiti: [`container`](https://github.com/apple/container/releases) e `jq` (`brew install jq`).

```bash
git clone … && cd mitm
$EDITOR mitm.conf      # IP del Mac sulla LAN, router, range DHCP
./mitm install
./mitm start
./mitm status
```

`./mitm install` si lancia da utente normale e chiede sudo **una volta sola**, per daemon pf, IP forwarding e dominio DNS `.test`; il resto (immagini, LaunchAgent, avvio del DHCP) non richiede privilegi. È idempotente: va rilanciato dopo una modifica di `mitm.conf` o di `daemon/mitm-pf-apply`. Alla fine elenca quello che resta da fare a mano:
- **IP statico del Mac** sull'interfaccia collegata alla LAN (`LAN_IP` di `mitm.conf`);
- **router in DHCP relay** verso quell'IP, senza altri server DHCP sulla LAN;
- **CA di mitmproxy**: per riusare quella già installata sui dispositivi, copiarne i file (`mitmproxy-ca.pem`, `mitmproxy-ca.p12`, `mitmproxy-ca-cert.*`, `mitmproxy-dhparam.pem`) in `mitmproxy/` prima del primo avvio, altrimenti mitmproxy ne genera una nuova. Non sono in git: la chiave privata permette di intercettare il traffico di ogni dispositivo che ha la CA installata.

Disinstallazione: `./mitm uninstall` (restano container, immagini, IP forwarding e dominio `.test`; il comando stampa come toglierli).

## Configurazione

[mitm.conf](mitm.conf) è l'unico file da adattare a un altro Mac o a un'altra rete: IP del Mac sulla LAN con prefisso, IP del router, range e durata dei lease. Interfacce (WAN = rotta di default, LAN = interfaccia con l'IP indicato) e subnet dei container sono ricavate da sole e seguono i cambi di rete (WiFi/Ethernet, casa/ufficio).

Altri file:
- [domini-mac.txt](domini-mac.txt): domini del traffico **del Mac** da far passare da mitmproxy, uno per riga, senza wildcard (`repubblica.it` e `www.repubblica.it` sono distinti). Le modifiche si applicano al salvataggio.
- [mitmproxy/config.yaml](mitmproxy/config.yaml), [mitmproxy/keys.yaml](mitmproxy/keys.yaml), [mitmproxy/scripts/](mitmproxy/scripts): opzioni, tasti e addon di mitmproxy. Le opzioni impostate dall'entrypoint (modalità, porte) non vanno ripetute in `config.yaml`.
- [dhcp/dnsmasq.conf](dhcp/dnsmasq.conf): opzioni di `dnsmasq` non legate alla rete, es. assegnazioni fisse (`dhcp-host=`). I parametri della LAN li genera `./mitm start dhcp` in `dhcp/lan.conf`.

## Uso

```
./mitm start [dhcp]            avvia DHCP e mitmproxy (con dhcp: solo il DHCP)
./mitm stop [dhcp|all] [--rm]  ferma mitmproxy (dhcp: solo il DHCP; all: entrambi)
./mitm status                  stato di container, regole pf, daemon e agent
./mitm attach                  console di mitmproxy
./mitm logs [dhcp|pf] [-f]     log di mitmproxy, di dnsmasq o del daemon pf
./mitm build [proxy|dhcp]      ricostruisce le immagini
```

Nessun comando richiede sudo, tranne `install`/`uninstall`. Il DHCP parte da solo al login (LaunchAgent); mitmproxy si avvia a mano con `./mitm start`. Con il solo DHCP attivo, o dopo `./mitm stop`, i client navigano normalmente via NAT del Mac, senza intercettazione.

### Interfaccia di mitmproxy

Scelta alla creazione del container con `MITM_UI`:
- `console` (default): `./mitm attach` apre mitmproxy nella sessione `tmux` del container. `Ctrl-b d` stacca il terminale lasciando mitmproxy attivo; `q` lo riavvia (flussi persi), senza fermare il container.
- `web`: `http://mitmproxy.test:8081`, password `password` o quella scelta.

Per cambiare interfaccia o password il container va ricreato:
```bash
./mitm stop --rm
MITM_UI=web MITM_WEB_PASSWORD='<password>' ./mitm start
```

I file salvati dai comandi di mitmproxy con percorso relativo (`:save.file @shown flussi.mitm`, `:export.file curl @focus richiesta.sh`, …) finiscono in `./export`.

### CA sui dispositivi e sul Mac

I client vanno configurati per fidarsi della CA di mitmproxy (`mitmproxy/mitmproxy-ca-cert.pem`; `.cer` è lo stesso file con l'estensione richiesta da alcuni Android). Sul Mac, per i domini di `domini-mac.txt`, va aggiunta come attendibile al portachiavi (Safari e Chrome; Firefox ha un archivio proprio). Senza, il browser mostra un errore di certificato.

### Dopo una modifica

- `entrypoint.sh` o `Containerfile`: `./mitm build proxy && ./mitm stop --rm && ./mitm start`.
- `dhcp/Containerfile`: `./mitm build dhcp && ./mitm stop dhcp --rm && ./mitm start dhcp`.
- `dhcp/dnsmasq.conf`: `./mitm stop dhcp && ./mitm start dhcp`.
- `mitm.conf` o `daemon/mitm-pf-apply`: `./mitm install`.
- Progetto spostato in un'altra directory: `./mitm install`, poi `./mitm stop all --rm && ./mitm start` (i volumi dei container hanno il percorso assoluto).

## Diagnosi

`./mitm status` è il primo controllo: mostra rete rilevata, container, regole pf, daemon e LaunchAgent, e segnala le incoerenze (regola verso un container fermo, configurazione del daemon non aggiornata, agent falliti, IP forwarding spento). Poi:

```bash
./mitm logs pf                                                # daemon: rete rilevata, regole applicate
./mitm logs dhcp                                              # dnsmasq: lease assegnati
curl -sv -o /dev/null https://www.repubblica.it/ 2>&1 | grep -i issuer   # dal Mac: issuer mitmproxy se intercettato
sudo pfctl -a com.apple/100.mitm.route -vsr                   # regole route-to e contatori
sudo pfctl -a com.apple/100.mitm.route -t mitm_local -T show  # IP dei domini del Mac
```

Log dei LaunchAgent: `~/Library/Logs/mitm-dhcp.log`, `~/Library/Logs/mitm-domains.log`.

Se il Mac non fa più da gateway (spento, scollegato, `./mitm stop dhcp`), i client restano senza DHCP: rimettere il router in modalità DHCP server.

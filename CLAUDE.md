# Appunti per Claude — repo NixOS di Enrico Lovisotto

Ultimo aggiornamento: 2026-10-19 (dopo la riorganizzazione dei backup e di cal_card_downloader).
L'utente scrive in italiano; codice, commenti e messaggi di commit sono in inglese.
Il repo è **pubblico** (github.com/lobisquit/nixos): niente dettagli privati in chiaro
(nomi di calendari, URL, indirizzi): vanno nei `secrets.yaml` cifrati con sops.

## 0. Lavorare sul repo

- Clonare da GitHub (`lobisquit/nixos`, branch `main`). Le modifiche di Claude vanno su branch
  `claude/...` con PR verso `main`: mai push diretti su `main`.
- Messaggi di commit: inglese, brevi, al passato o imperativo ("Added biboumi", "Pinning slidgram version").

## 1. Verificare le modifiche nel sandbox

`nix` è installato. I tarball GitHub (`github:` input) danno 403, ma il proxy serve i
clone git anonimi: si valuta sovrascrivendo gli input con `git+https` agli stessi rev del lock.
Script (dalla radice del repo, `./eval.sh <host>`):

```sh
#!/bin/sh
set -e
lock() { nix --extra-experimental-features 'nix-command flakes' eval --raw --impure --expr "(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.$1.locked.rev"; }
G="git+https://github.com"
exec nix --extra-experimental-features 'nix-command flakes' eval --raw \
  --override-input nixpkgs_stable    "$G/nixos/nixpkgs?rev=$(lock nixpkgs_stable)&shallow=1" \
  --override-input nixpkgs_unstable  "$G/nixos/nixpkgs?rev=$(lock nixpkgs_unstable)&shallow=1" \
  --override-input home-manager      "$G/nix-community/home-manager?rev=$(lock home-manager)&shallow=1" \
  --override-input nixos-hardware    "$G/NixOS/nixos-hardware?rev=$(lock nixos-hardware)&shallow=1" \
  --override-input sops-nix_stable   "$G/Mic92/sops-nix?rev=$(lock sops-nix_stable)&shallow=1" \
  --override-input sops-nix_unstable "$G/Mic92/sops-nix?rev=$(lock sops-nix_unstable)&shallow=1" \
  "path:.#nixosConfigurations.$1.config.system.build.toplevel.drvPath"
```

- Primo giro ~2 min (download nixpkgs), poi pochi secondi per host. Cambiando l'attributo finale
  si ispezionano le unit generate, es. `…config.systemd.units."backup_local.service".text`.
- `nasus` non valuta qui solo perché l'overlay di navidrome fa `fetchurl` da raw.githubusercontent.com
  (IFD, non raggiungibile): per testarlo, in una copia impostare `services.navidrome_wrapper.enable = false`.
- Non si può buildare (cache.nixos.org non raggiungibile), né fare deploy, né decifrare i secret.
- pip funziona: per provare vdirsyncer si può usare un venv con `vdirsyncer==0.20.0` e `radicale`
  come server CalDAV/CardDAV locale (+ `python3 -m http.server` per gli ICS).
  Attenzione: `pkill -f <pattern>` nella stessa riga di comando uccide la shell stessa; usare i PID.

## 2. Struttura

```
flake.nix / flake.lock   5 nixosConfigurations + homeConfigurations.enrico
Makefile                 deploy (vedi §5)
.sops.yaml               chiavi age e regole per i secrets.yaml di ogni host
shared/                  moduli comuni: backupper.nix, backlight_off.nix, nginx_wrapper.nix, ssh_ca_key.pub
<host>/                  configuration.nix + hardware-configuration.nix + moduli specifici + secrets.yaml
```

`<host>/backupper.nix`, `<host>/backlight_off.nix` e `<host>/nginx_wrapper.nix` sono **symlink** a
`../shared/` (bacero, nasus; octoprint solo `nginx_wrapper.nix`). `monitoring.nix` e
`monitoring_prometheus_rules.yml` sono invece **copie per-host divergenti**.

## 3. Host

| Flake name | Ruolo | nixpkgs | stateVersion | SSH alias |
|---|---|---|---|---|
| `lobisquit-pc` | desktop principale, KDE Plasma 6 + home-manager | unstable | 23.11 | locale (`make switch-self`) |
| `nasus` | NAS/server di casa (portatile, lid ignorato), disco dati `/mnt/storage_drive` | 25.11 | 24.05 | `root_nasus` (porta 2222) |
| `bacero` | server bot/servizi pubblici (portatile) | 25.11 | 25.05 | `root_bacero` |
| `minipc` | (hostname `lobisquit-minipc`) mini PC LXQt per ripristino offline dei backup su LUKS | 25.11 | 25.11 | `root_minipc` |
| `octoprint` | Raspberry Pi 4 (aarch64), OctoPrint + mjpg-streamer; nei commit **"rpi"** | unstable | 25.11 | `root_octoprint` |

### lobisquit-pc
- `configuration.nix` importa locale/networking/sound/users/xserver + home-manager come modulo NixOS;
  `enrico.nix` è sia modulo HM dentro NixOS sia `homeConfigurations.enrico` standalone.
- Stampante Epson XP-2200 (socket), scanner SANE+airscan, QMK/Vial, platformio udev, binfmt aarch64.
- WireGuard `wg-home-inner` / `wg-home-full` (autostart off). Chiave sops in `/etc/age/enrico.txt`
  (gli altri host: `/root/.config/sops/age/keys.txt`).
- SSH: certificato e chiave da sops in `/run/secrets/…`, path hardcoded in `enrico.nix`.

### nasus (il più ricco)
- `sftpd_storage` (+ `sshd_wrapper`, porta 2222, `TrustedUserCAKeys`): dati in
  `/mnt/storage_drive/sftp_chroot/data`; utenti `storage` (sftp chroot) e `storage_unison`;
  ACL via `storage-set-permissions.service` (gruppo `readonly_storage` in sola lettura).
  Opzione `backup_folders` (default `Documenti Immagini Musica Video`): ognuna è una sorgente di backup.
- `backupper`: vedi §4.
- `mail_downloader` (offlineimap) → `/mnt/storage_drive/mail`, gruppo proprio, sorgente `mail`.
- `cal_card_downloader` → `/mnt/storage_drive/cal_card`, sorgente `cal_card`. Usa il modulo nixpkgs
  `services.vdirsyncer` (unit `vdirsyncer@cal_card`, **timer disattivato**: parte solo prima dei backup).
  L'intera configurazione vdirsyncer (INI, valori JSON) è il secret `cal_card_downloader_vdirsyncer`:
  collezioni, cartelle, URL e credenziali non sono nel repo. Ogni collezione = `[pair X]` +
  `[storage X_remote]` (`read_only = true`, `collections = null`, URL della singola collezione) +
  `[storage X_local]` (filesystem dentro davDir). `status_path = "/var/lib/vdirsyncer/cal_card"` obbligatorio.
  `forceDiscover` crea le cartelle mancanti. Limiti noti di vdirsyncer 0.20: un errore in una coppia
  ferma tutte le altre in quel giro; una cartella locale svuotata a mano blocca la coppia finché non
  si cancella `<coppia>.items` nello status; il `revert` delle modifiche locali avviene a giri alterni.
- `monitoring`: Prometheus + node/smartctl exporter + Alertmanager via email + healthchecks.io ogni 15'.
- `transmission_wrapper` (contiene anche utenti/share samba), `samba_wrapper`,
  `navidrome_wrapper` (overlay di fix da fork `cimm/nixpkgs`).
- Stack XMPP (ottobre 2026):
  - `xmpp_server`: Prosody per `lovisotto.it`, MUC `conference.`, upload `upload.` (100 MiB, 3 mesi),
    dati in `/mnt/storage_drive/xmpp/prosody`. Prosody 13 salva i dati di ogni host in una cartella col
    nome dell'host percent-encoded (`upload%2elovisotto%2eit` = file condivisi). Sorgenti di backup
    `prosody` (esclusi gli upload) e `prosody_uploads`.
  - `xmpp_telegram`: slidgram in podman, immagine pinnata; Prosody con community module `privilege`;
    `checkConfig = false` perché i secret non esistono a build time. Dati di slidgram non salvati
    (volume `:U`, illeggibili da backupper).
  - `xmpp_irc`: biboumi `irc.lovisotto.it`, workaround sandbox (nixpkgs issue #493443).
  - `xmpp_transcriber_bot`: slixmpp + faster-whisper; i modelli non vanno salvati.
- `telegram_reminder` disabilitato.

### bacero
- `doorman` (+`doorman.py`): sensore porta su seriale USB CH340, registra con ffmpeg e manda le
  registrazioni nella stanza XMPP `doorman@conference.lovisotto.it` (slixmpp, worker thread per la conversione).
- `beancount_bot` (aiogram + PostgreSQL locale).
- `podcasts_fetcher`: Il Post (Selenium), YouTube (yt-dlp), Spreaker → feed RSS su `podcast.lovisotto.it`.
- `miniflux_wrapper` (`news.lovisotto.it`): dump OPML + pg_dump, dichiarato come sorgente `miniflux`.
- `mensaspaziale_bot` disabilitato. Monitoring senza smartctl, healthchecks ogni 30'.

### minipc
- Script `mount_encrypted` (LUKS `/dev/sda3` → `/mnt/private_data`) e `fetch_local` (monta il repo
  restic dell'HDD `FA3D-8377` e fa rsync dell'ultimo snapshot per tag: `Documenti Immagini miniflux
  postgresql Video`; non include ancora `Musica mail cal_card prosody prosody_uploads`).

### octoprint
- nginx + ACME deSEC per `octoprint.home.lovisotto.it`, `/mjpg/` → mjpg-streamer :5050.

## 4. Backup (`shared/backupper.nix`)

- **L'host dichiara le destinazioni**, `services.backupper.repositories.<nome>`: ognuna genera la unit
  `backup_<nome>`. Opzioni: `secret` (default `restic_<nome>_configuration`, EnvironmentFile con
  `RESTIC_PASSWORD`, `RESTIC_REPOSITORY`, credenziali B2…), `localPath` (repo locale: imposta
  `RESTIC_REPOSITORY`, unico path scrivibile, niente rete; non mettere `RESTIC_REPOSITORY` nel secret
  perché EnvironmentFile vince su Environment), `startAt` (null = manuale), `requires`, `keep`.
- **I moduli dichiarano cosa salvare**, `services.backupper.sources.<nome>`: `paths`, `exclude`,
  `groups` (gruppi per leggere), `runBefore` (unit di preparazione, dipendenza debole), `tag` (= nome),
  `enable`. **`repositories` non ha default**: lo sceglie l'host in `configuration.nix`.
- Script generato: per ogni sorgente `restic backup --tag` + `forget` (7d/5w/12m/100y), poi un solo
  `prune` e `check`. Sorgenti in sequenza: un errore ferma le successive (unit fallita).
- Sandbox: root vuota read-only, solo i path delle sorgenti di quel repo in sola lettura, `exclude`
  assoluti resi inaccessibili, `%` escapato come `%%` per systemd.
- nasus: `remote` (B2, 03:00) ← Documenti, mail, cal_card, prosody; `local` (HDD exFAT
  `FA3D-8377`, mount legato alla unit, avvio manuale `systemctl start backup_local`) ← tutto.
  bacero: `remote` ← miniflux.
- Utente `backupper` uid 123; nomi unit, tag e `--host` invariati rispetto al vecchio sistema.

## 5. Deploy e manutenzione (Makefile)

- `make switch-<host>` / `test-<host>`: `nixos-rebuild … --flake .#<host> --target-host root_<host>`.
- `make switch-self` (default) / `test-self` / `clean-self` sul PC locale.
- `make auto_upgrade-<host>`: working tree pulito, `nix flake update`, commit **"Update <host>"**, switch e clean.
- I deploy partono da lobisquit-pc (dove ci sono gli alias SSH).

## 6. Convenzioni

- Ogni funzionalità è un modulo con `options.services.<nome>` e `config = mkIf cfg.enable { … }`,
  attivato in `configuration.nix`. Nomi `snake_case`, `<servizio>_wrapper` per i wrapper.
  Per codice nuovo: `lib.mkEnableOption`, opzioni con `description`, niente `with lib`.
- I moduli che dichiarano sorgenti di backup importano `./backupper.nix` (gli import sono deduplicati).
- Utente di sistema dedicato per servizio, con gruppo proprio; secret sops `mode = "0400"` con owner
  del servizio. Valori composti: `sops.templates` + `config.sops.placeholder`. Chiavi annidate:
  nome con `/` (es. `foo/bar`).
- Hardening systemd: `TemporaryFileSystem = "/"` (o `"/:ro"`) + `BindReadOnlyPaths` di `/nix/store`,
  `/etc/resolv.conf`, `/etc/ssl/certs/ca-certificates.crt` (+ `/etc/passwd` se serve) e `BindPaths`
  solo per le cartelle scritte; `PrivateNetwork` se non serve rete; `UMask = "0027"` se il backup deve leggere.
- HTTPS: `services.nginx_wrapper.enable = true` + virtualHost `enableACME`/`forceSSL`.
  `*.home.lovisotto.it` → DNS-01 deSEC (secret `desec_token`); domini pubblici di bacero → HTTP-01.
- Timer con `startAt` + spesso `RandomizedDelaySec`. Script Python con `pkgs.python3.withPackages`
  e config via env/EnvironmentFile.
- Fix temporanei a nixpkgs: commento con link all'issue GitHub sopra l'override.

## 7. Secret (sops-nix, age)

Claude non può decifrarli: per un nuovo secret, dichiararlo nel modulo e dire all'utente di
aggiungerlo con `sops <host>/secrets.yaml` **prima** del deploy (una chiave mancante fa fallire
l'attivazione). Chiavi admin: lobisquit-pc, minipc-enrico, padel1 (telefono Termux).
- **nasus**: restic_remote/local_configuration, alertmanager_credentials, healthchecks_io_environment,
  transmission_credentials, smbpasswd, offlineimap_configuration, cal_card_downloader_vdirsyncer,
  desec_token, slidgram_secret, telegram_api_id, telegram_api_hash, biboumi_secret,
  transcriber_bot_password (+ inutilizzati: telegram_reminder_environment, filebrowser_secret_environment)
- **bacero**: alertmanager_credentials, healthchecks_io_environment, podcasts_fetcher_*,
  miniflux_admin_credentials, restic_remote_configuration, doorman, beancount_bot_environment,
  mensaspaziale_bot (+ inutilizzati: miniflux_token, restic_local_configuration)
- **lobisquit-pc**: wireguard_private_key, smb_enrico (inutilizzato), ssh_self_key, ssh_self_cert
- **minipc**: restic_remote/local_configuration, wireguard_private_key
- **octoprint**: wifi_password, alertmanager_credentials, desec_token

## 8. Aperti / da proporre

1. `beancount_bot`: il DB PostgreSQL non è salvato. Servirebbe un `pg_dump` come `runBefore` e una
   sorgente nel modulo (oggi crea solo `backupFolder` con gruppo `miniflux_backup`).
2. `fetch_local` (minipc) non ripristina i tag nuovi (§3 minipc).
3. `octoprint` usa `nixpkgs_unstable` ma il modulo `sops-nix_stable`.
4. `podcasts_fetcher.nix` usa `services.nginx_wrapper` senza importarlo.
5. `shared/nginx_wrapper.nix`: opzione `env_file` di tipo `path` con default `false`, mai usata.
6. Duplicazione: locale it_IT ripetuto in nasus/bacero/lobisquit-pc; monitoring copiato per host.
7. Argomento `libs` (refuso innocuo di `lib`) ancora in `lobisquit-pc/configuration.nix`.
8. Range di rete non coerenti tra servizi (samba, transmission, WireGuard): chiedere prima di toccarli.

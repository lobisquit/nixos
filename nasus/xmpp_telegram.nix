{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_telegram;
  xmpp = config.services.xmpp_server;
  domain = xmpp.domain;
  jid = "telegram.${domain}";
  dataDir = "${xmpp.storageDir}/slidgram";
  # slidge keeps everything in a folder named after the gateway JID
  gatewayDir = "${dataDir}/${jid}";
  # User of the container: :U makes the volume belong to it
  containerUid = "10000";
  secrets = config.sops.secrets;
in
{
  imports = [ ./backupper.nix ];

  options.services.xmpp_telegram = {
    enable = lib.mkEnableOption "the Telegram gateway (slidgram) for the XMPP server";

    image = lib.mkOption {
      type = lib.types.str;
      default = "codeberg.org/slidge/slidgram:latest";
      description = ''
        Container image. Pin it by digest as well as by tag
        (e.g. codeberg.org/slidge/slidgram:v0.5.0@sha256:...), so that a
        tag moved on the registry cannot change what runs here.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Verbose gateway logs (slidge and pyrogram), e.g. to see incoming Telegram updates.";
    };

    backupFolder = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/slidgram_backup";
      description = "Where a consistent copy of the slidgram databases is written before each backup.";
    };

    backupGroup = lib.mkOption {
      type = lib.types.str;
      default = "slidgram_backup";
      description = "Group that can read the copy (backupper joins it).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = xmpp.enable;
        message = "services.xmpp_telegram needs services.xmpp_server.enable = true.";
      }
    ];

    # Secrets (sops):
    #   slidgram_secret:   random string shared by Prosody and the gateway
    #   telegram_api_id:   from https://my.telegram.org → API development tools
    #   telegram_api_hash: same page
    sops.secrets.slidgram_secret = { owner = "prosody"; };
    sops.secrets.telegram_api_id = { };
    sops.secrets.telegram_api_hash = { };

    # Env vars: SLIDGE_ for generic options, SLIDGE__SLIDGRAM_ (double underscore)
    # for slidgram-specific ones (see slidge/main.py; the docs say SLIDGRAM_)
    sops.templates."slidgram.env".content = ''
      SLIDGE_SECRET=${config.sops.placeholder.slidgram_secret}
      SLIDGE__SLIDGRAM_API_ID=${config.sops.placeholder.telegram_api_id}
      SLIDGE__SLIDGRAM_API_HASH=${config.sops.placeholder.telegram_api_hash}
    '';

    services.prosody = {
      # The config check runs at build time, where the secret file doesn't exist yet
      checkConfig = false;

      # mod_privilege (XEP-0356) is a community module: build Prosody with it included
      package = pkgs.prosody.override { withCommunityModules = [ "privilege" ]; };
      extraModules = [ "privilege" ];

      # Let the gateway manage contact lists and bookmarks of ${domain} users
      # (only affects users who register with the gateway)
      virtualHosts.${domain}.extraConfig = ''
        privileged_entities = {
          ["${jid}"] = {
            roster = "both";       -- add/remove Telegram contacts in the contact list
            message = "outgoing";  -- show messages sent from official Telegram apps
            iq = {
              ["http://jabber.org/protocol/pubsub"] = "both";      -- group chat bookmarks
              ["http://jabber.org/protocol/pubsub#owner"] = "set"; -- read-state sync
              ["urn:xmpp:http:upload:0"] = "get";                  -- uploads on behalf of users
            };
          };
        }
      '';

      extraConfig = lib.mkAfter ''
        -- Let the gateway upload Telegram attachments (in addition to local users)
        http_file_share_access = { "${domain}", "${jid}" }

        -- Telegram gateway (connects locally on port 5347)
        Component "${jid}"
          component_secret = FileLine("${secrets.slidgram_secret.path}")
          modules_enabled = { "privilege" }
      '';
    };

    virtualisation.oci-containers = {
      backend = lib.mkDefault "podman";
      containers.slidgram = {
        image = cfg.image;
        extraOptions = [
          "--network=host" # reach Prosody on localhost:5347
          # no privilege escalation and no capabilities inside the container
          "--security-opt=no-new-privileges"
          "--cap-drop=all"
        ];
        volumes = [ "${dataDir}:/var/lib/slidge:U" ];
        environmentFiles = [ config.sops.templates."slidgram.env".path ];
        environment = {
          # Download Telegram files up to the same size the upload service accepts
          SLIDGE__SLIDGRAM_ATTACHMENT_MAX_SIZE = toString config.services.prosody.httpFileShare.size_limit;
          # Contact pictures in 640x640 instead of 160x160
          SLIDGE__SLIDGRAM_BIG_AVATARS = "true";
        };
        cmd = [
          "--jid" jid
          "--upload-service" "upload.${domain}"
          # Only users of this server. slidge uses re.match, which anchors
          # only the start: without "$", user@${domain}.attacker.org would
          # pass. The optional resource is for the full JIDs in disco#items.
          "--user-jid-validator" "^[^@/]+@${lib.escapeRegex domain}(/.*)?$"
          "--admins" (builtins.head xmpp.admins)
        ] ++ lib.optional cfg.debug "--debug"; # very verbose, includes pyrogram internals
      };
    };

    systemd.services.podman-slidgram = {
      after = [ "prosody.service" ];
      wants = [ "prosody.service" ];
      unitConfig.RequiresMountsFor = [ dataDir ];
      preStart = "mkdir -p ${dataDir}";
    };

    systemd.services.podman-slidgram.serviceConfig = {
      LogRateLimitIntervalSec = 0;
    };

    # The folder contains the Telegram session of every registered user,
    # i.e. full access to their accounts: only the container user can
    # enter it (slidge creates its files world-readable).
    systemd.tmpfiles.rules = [
      "d ${dataDir} 0700 ${containerUid} ${containerUid} - -"
    ];

    # Backups. Only the databases are copied: the slidge one (registrations,
    # settings, Telegram <-> XMPP message IDs for replies and reactions), the
    # Telegram sessions (<user jid>.session, SQLite as well) and the
    # reactions. Avatars and downloads are a cache. The copies are made
    # with sqlite3 .backup, so they are consistent while the gateway runs.
    users.groups.${cfg.backupGroup} = { };
    # Readable only by root and by the backup group; the setgid bit makes
    # new files belong to the backup group.
    systemd.tmpfiles.settings.slidgram_backup = {
      "${cfg.backupFolder}".d = {
        user = "root";
        group = cfg.backupGroup;
        mode = "2750";
      };
    };

    systemd.services.slidgram_backup_db = {
      description = "Consistent copy of the slidgram databases for the backups";
      # restore: stop podman-slidgram, copy the files to ${gatewayDir},
      # chown -R ${containerUid}:${containerUid} ${dataDir}, start podman-slidgram

      unitConfig.RequiresMountsFor = [ dataDir ];
      path = [ pkgs.sqlite ];
      serviceConfig = {
        Type = "oneshot";
        UMask = "0027";

        # Only the gateway data and the backup folder are visible. The data
        # is writable because SQLite may need it to read a database in WAL
        # mode or with a journal left by a crash.
        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        PrivateTmp = true;
        BindPaths = [ dataDir cfg.backupFolder ];
        BindReadOnlyPaths = [ "/nix/store" ];
      };

      # Write each copy to a temporary file and rename it only on success,
      # so a failed copy never replaces the previous good one; copies of
      # databases that no longer exist are removed.
      script = ''
        set -o nounset -o pipefail
        shopt -s nullglob
        out="${cfg.backupFolder}"
        cd "${gatewayDir}"

        keep=()
        for db in *.sqlite *.session; do
          tmp=$(mktemp "$out/.$db.XXXXXX")
          trap 'rm -f "$tmp"' EXIT
          sqlite3 "$db" ".backup '$tmp'"
          chmod 0640 "$tmp"
          mv -f "$tmp" "$out/$db"
          trap - EXIT
          keep+=("$db")
        done

        for f in "$out"/*; do
          name=$(basename "$f")
          [[ " ''${keep[*]} " == *" $name "* ]] || rm -f "$f"
        done
      '';
    };

    # Repositories are chosen by the host.
    services.backupper.sources.slidgram = {
      paths = [ cfg.backupFolder ];
      groups = [ cfg.backupGroup ];
      runBefore = [ "slidgram_backup_db.service" ];
    };
  };
}

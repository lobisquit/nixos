{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_telegram;
  xmpp = config.services.xmpp_server;
  domain = xmpp.domain;
  jid = "telegram.${domain}";
  dataDir = "${xmpp.storageDir}/slidgram";
  secrets = config.sops.secrets;
in
{
  options.services.xmpp_telegram = {
    enable = lib.mkEnableOption "the Telegram gateway (slidgram) for the XMPP server";

    image = lib.mkOption {
      type = lib.types.str;
      default = "codeberg.org/slidge/slidgram:latest";
      description = "Container image; pin a version tag (e.g. :v0.5.0) for fewer surprises.";
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Verbose gateway logs (slidge and pyrogram), e.g. to see incoming Telegram updates.";
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
        extraOptions = [ "--network=host" ]; # reach Prosody on localhost:5347
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
          "--user-jid-validator" ".*@${lib.escapeRegex domain}"
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
  };
}

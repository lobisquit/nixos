{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_server;
  secrets = config.sops.secrets;
  domain = cfg.domain;
  certDir = config.security.acme.certs.${domain}.directory;
  prosodyDir = "${cfg.storageDir}/prosody";
  # Prosody keeps the data of each host in a folder named after it, with
  # non-alphanumeric characters percent-encoded (upload.lovisotto.it ->
  # upload%2elovisotto%2eit): for the upload component, the shared files.
  prosodyHostDir = host: "${prosodyDir}/${lib.replaceStrings [ "." "-" "_" ] [ "%2e" "%2d" "%5f" ] host}";
  uploadsDir = prosodyHostDir config.services.prosody.httpFileShare.domain;
  restrictFederation = cfg.federationWhitelist != [ ];
in
{
  imports = [ ../backupper.nix ];

  options.services.xmpp_server = {
    enable = lib.mkEnableOption "the Prosody XMPP server";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "lovisotto.it";
      description = "XMPP domain; users are user@domain.";
    };

    admins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "enrico@${cfg.domain}" ];
      description = "Server admin JIDs.";
    };

    federation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow talking to users on other XMPP servers (port 5269).";
    };

    federationWhitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "example.org" "conference.example.org" ];
      description = ''
        If non-empty, federate only with these domains (mod_s2s_whitelist);
        connections to and from any other server are refused. Subdomains
        are separate servers: list e.g. conference.example.org too to join
        rooms there. Empty means open federation. Requires federation = true.
      '';
    };

    communityModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Prosody community modules to build in and enable. Each XMPP service
        adds its own (e.g. the Telegram gateway needs "privilege"), since
        services.prosody.package can only be set once.
      '';
    };

    storageDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/storage_drive/xmpp";
      description = ''
        Base folder for XMPP-related data. Prosody stores accounts,
        archives and uploaded files in <storageDir>/prosody.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.xmpp_server.communityModules = lib.optionals restrictFederation [ "s2s_whitelist" ];

    assertions = [
      {
        assertion = restrictFederation -> cfg.federation;
        message = "services.xmpp_server.federationWhitelist requires services.xmpp_server.federation = true.";
      }
    ];

    sops.secrets.desec_token = { };

    security.acme = {
      acceptTerms = true;
      certs.${domain} = {
        domain = domain;
        extraDomainNames = [ "conference.${domain}" "upload.${domain}" ];
        group = "prosody";
        dnsProvider = "desec";
        dnsResolver = "ns1.desec.io:53";
        environmentFile = secrets.desec_token.path;
        server = "https://acme-v02.api.letsencrypt.org/directory";
        webroot = null;

        reloadServices = [ "prosody" ];
      };
    };

    services.prosody = {
      enable = true;
      dataDir = prosodyDir;
      admins = cfg.admins;
      allowRegistration = false; # accounts are created with prosodyctl

      s2sSecureAuth = true;

      # Build Prosody with the community modules requested by the XMPP
      # services; the NixOS module enables them automatically.
      package = pkgs.prosody.override { withCommunityModules = lib.unique cfg.communityModules; };

      ssl.cert = "${certDir}/fullchain.pem";
      ssl.key = "${certDir}/key.pem";

      virtualHosts.${domain} = {
        enabled = true;
        domain = domain;
        ssl.cert = "${certDir}/fullchain.pem";
        ssl.key = "${certDir}/key.pem";
      };

      # Group chats (rooms are created by local users only)
      muc = [ { domain = "conference.${domain}"; } ];

      # File/image sharing.
      # Recent NixOS: httpFileShare. On older channels this option is `uploadHttp`.
      httpFileShare = {
        domain = "upload.${domain}";
        size_limit = 100 * 1024 * 1024;        # 100 MiB per file
        daily_quota = 1024 * 1024 * 1024;      # 1 GiB per user per day
        expires_after = "3 months";
      };

      extraConfig = ''
        -- Certificate for the HTTPS listener (file uploads on port 5281)
        https_ssl = {
          certificate = "${certDir}/fullchain.pem";
          key = "${certDir}/key.pem";
        }
      '' + lib.optionalString (!cfg.federation) ''

        -- No federation: don't talk to other XMPP servers
        modules_disabled = { "s2s" }
      '' + lib.optionalString (cfg.federation && restrictFederation) ''

        -- Federation only with these servers
        s2s_whitelist = { ${lib.concatMapStringsSep ", " (d: ''"${d}"'') cfg.federationWhitelist} }
      '';
    };

    # <storageDir>          root-owned, traversable (other services can live here later)
    # <storageDir>/prosody  only Prosody can read it
    systemd.tmpfiles.rules = [
      "d ${cfg.storageDir} 0755 root root - -"
      "d ${prosodyDir} 0750 prosody prosody - -"
    ];

    # Backups, split in two sources so that the host can send the
    # uploaded media (up to 1 GiB per user per day, expiring after
    # 3 months) only to some repositories. Repositories are chosen by
    # the host.
    services.backupper.sources = {
      # accounts, rosters, message archives, group chats
      prosody = {
        paths = [ prosodyDir ];
        exclude = [ uploadsDir ];
        groups = [ "prosody" ];
      };

      # files and images shared in chats
      prosody_uploads = {
        paths = [ uploadsDir ];
        groups = [ "prosody" ];
      };
    };

    # Wait for the drive to be mounted, and allow writing there even if
    # the service is sandboxed.
    systemd.services.prosody = {
      unitConfig.RequiresMountsFor = [ prosodyDir ];
      serviceConfig.ReadWritePaths = [ prosodyDir ];
    };

    # Make prosodyctl available (same version as the running server)
    environment.systemPackages = [ config.services.prosody.package ];

    networking.firewall.allowedTCPPorts =
      [
        5222 # client connections
        5281 # HTTPS file uploads
      ]
      ++ lib.optionals cfg.federation [ 5269 ]; # federation
  };
}

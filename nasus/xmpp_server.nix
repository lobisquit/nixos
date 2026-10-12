{ config, lib, ... }:

let
  cfg = config.services.xmpp_server;
  domain = cfg.domain;
  certDir = config.security.acme.certs.${domain}.directory;
  prosodyDir = "${cfg.storageDir}/prosody";
in
{
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

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "enrico@${cfg.domain}";
      description = "Email for ACME (Let's Encrypt) notices.";
    };

    federation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow talking to users on other XMPP servers (port 5269).";
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
    sops.secrets.desec_token = { };

    # DNS-01 challenge, works although the domain itself is hosted elsewhere
    security.acme = {
      acceptTerms = true;
      certs.${domain} = {
        domain = domain;
        email = cfg.acmeEmail;
        extraDomainNames = [ "conference.${domain}" "upload.${domain}" ];
        dnsProvider = "desec";
        credentialFiles."DESEC_TOKEN_FILE" = config.sops.secrets.desec_token.path;
        environmentFile = builtins.toFile "acme-desec.env" ''
          DESEC_PROPAGATION_TIMEOUT=600
          DESEC_POLLING_INTERVAL=10
        '';
        group = "prosody";
        reloadServices = [ "prosody" ];
      };
    };

    services.prosody = {
      enable = true;
      dataDir = prosodyDir;
      admins = cfg.admins;
      allowRegistration = false; # accounts are created with prosodyctl

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
      httpFileShare.domain = "upload.${domain}";

      extraConfig = ''
        -- Certificate for the HTTPS listener (file uploads on port 5281)
        https_ssl = {
          certificate = "${certDir}/fullchain.pem";
          key = "${certDir}/key.pem";
        }
      '' + lib.optionalString (!cfg.federation) ''

        -- No federation: don't talk to other XMPP servers
        modules_disabled = { "s2s" }
      '';
    };

    # <storageDir>          root-owned, traversable (other services can live here later)
    # <storageDir>/prosody  only Prosody can read it
    systemd.tmpfiles.rules = [
      "d ${cfg.storageDir} 0755 root root - -"
      "d ${prosodyDir} 0750 prosody prosody - -"
    ];

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

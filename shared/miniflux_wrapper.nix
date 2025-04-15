{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.miniflux_wrapper;
  secrets = config.sops.secrets;
in

{
  imports = [ ./nginx_wrapper.nix ];

  options.services.miniflux_wrapper = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    baseUrl = mkOption {
      type = types.str;
      default = "https://news.lovisotto.it";
    };

    internalPort = mkOption {
      type = types.int;
      default = 8036;
    };

    opmlBackupFolder = mkOption {
      type = types.str;
      default = "/var/lib/miniflux_opml_backup";
    };

    opmlBackupGroup = mkOption {
      type = types.str;
      default = "miniflux_opml";
    };
  };

  config = mkIf cfg.enable {

    users.groups.miniflux = {};
    users.users.miniflux = {
      createHome = false;
      isSystemUser = true;
      group = config.users.groups.miniflux.name;
    };

    sops.secrets.miniflux_admin_credentials = {
      mode = "0400";
      owner = config.users.users.miniflux.name;
      group = config.users.users.miniflux.group;
    };

    services.miniflux = {
      enable = true;
      config = {
        LISTEN_ADDR = "127.0.0.1:" + toString cfg.internalPort;
        BASE_URL = cfg.baseUrl;
      };
      adminCredentialsFile = secrets.miniflux_admin_credentials.path;
    };

    services.nginx_wrapper.enable = true;
    services.nginx.virtualHosts."news.lovisotto.it" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.internalPort}";
        proxyWebsockets = true;
        extraConfig = "proxy_ssl_server_name on;";
      };
    };

    users.groups."${cfg.opmlBackupGroup}" = {};
    systemd.tmpfiles.settings.miniflux = {
      "${cfg.opmlBackupFolder}".d = {
        user = config.users.users.miniflux.name;
        group = cfg.opmlBackupGroup;
        mode = "0755";
      };
    };

    systemd.services.miniflux_backup_admin_opml = {
      description = "Backup the OPML for the admin user of miniflux";

      serviceConfig = {
        Type = "oneshot";
        User = config.users.users.miniflux.name;
        Group = config.users.users.miniflux.group;
        EnvironmentFile = secrets.miniflux_admin_credentials.path;
        Environment = ''DATABASE_URL="${config.services.miniflux.config.DATABASE_URL}"'';

        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        PrivateTmp = true;
        BindPaths = [
          cfg.opmlBackupFolder
        ];
        BindReadOnlyPaths = [
          "/nix/store"
          "/run/postgresql"
        ];
      };

      path = with pkgs; [ miniflux ];
      script = ''
          miniflux -export-user-feeds "$ADMIN_USERNAME" \
              > "${cfg.opmlBackupFolder}/$ADMIN_USERNAME.opml"
      '';
    };
  };
}

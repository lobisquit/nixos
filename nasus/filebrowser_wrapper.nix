{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.filebrowser_wrapper;
  secrets = config.sops.secrets;
  user_conf = config.users.users.filebrowser;
in
{
  options = {
    services.filebrowser_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      internalPort = mkOption {
        type = types.int;
        default = 8035;
      };

      dataDir = mkOption {
        type = types.path;
        default = "/mnt/data/";
      };
    };
  };

  config = mkIf cfg.enable {
    users.groups.storage = {};
    users.users.filebrowser = {
      createHome = true;
      home = "/var/lib/filebrowser/";
      isSystemUser = true;
      group = config.users.groups.storage.name;
    };

    sops.secrets.filebrowser_secret_environment = {
      mode = "0400";
      owner = user_conf.name;
      group = user_conf.group;
    };

    systemd.services.filebrowser = {
      description = "File Browser service for storage";

      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      path = with pkgs; [
        filebrowser
        wget
      ];

      script = ''
          ${pkgs.filebrowser}/bin/filebrowser \
              --address=127.0.0.1 \
              --port=${toString cfg.internalPort} \
              --database=${user_conf.home + "filebrowser.db"} \
              --root=${toString cfg.dataDir} \
              --baseurl=/ \
              --password=$INITIAL_HASHED_PASSWORD \
              --username=$INITIAL_USERNAME
          '';

      serviceConfig = {
        Restart = "on-failure";
        User = user_conf.name;
        Group = user_conf.group;

        EnvironmentFile = secrets.filebrowser_secret_environment.path;

        TemporaryFileSystem = "/";
        BindPaths = [
          user_conf.home
          cfg.dataDir
        ];
        BindReadOnlyPaths = [
          "/nix/store"
        ];
      };
    };

    services.nginx.virtualHosts."storage.lovisotto.it" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.internalPort}";
        proxyWebsockets = true;
        extraConfig = "proxy_ssl_server_name on;";
      };
    };
  };
}

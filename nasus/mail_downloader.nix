{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.mail_downloader;
  secrets = config.sops.secrets;
in
{
  options = {
    services.mail_downloader = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      mailDir = mkOption {
        type = types.path;
        default = "/mnt/data/";
      };
    };
  };

  config = mkIf cfg.enable {
    users.groups.storage = {};
    users.users.mail_downloader = {
      createHome = true;
      home = "/var/lib/mail_downloader/";
      isSystemUser = true;
      group = config.users.groups.storage.name;
    };

    sops.secrets.offlineimap_configuration = {
      mode = "0400";
      owner = config.users.users.mail_downloader.name;
      group = config.users.users.mail_downloader.group;
    };

    systemd.services.mail_downloader = {
      description = "Sync IMAP to local folders";

      after = [ "network.target" ];
      wantedBy = [ "backup_remote.service" "backup_local.service" ];
      before = [ "backup_remote.service" "backup_local.service" ];
      serviceConfig = {
        User = config.users.users.mail_downloader.name;
        Group = config.users.users.mail_downloader.group;
        Type = "oneshot";

        TemporaryFileSystem = "/";
        BindPaths = [
          config.users.users.mail_downloader.home
          cfg.mailDir
        ];
        BindReadOnlyPaths = [
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/nix/store"
          secrets.offlineimap_configuration.path
        ];
      };

      path = with pkgs; [ offlineimap ];

      script = ''
          cd ${cfg.mailDir}
          # backup all accounts by default
          offlineimap -c ${secrets.offlineimap_configuration.path} \
            || echo "Errors should be for some mails only"
          exit 0
          '';
    };
  };
}

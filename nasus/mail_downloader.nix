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
        default = "/var/lib/mail_downloader/mail";
        description = "Folder where the mails are synced, also backed up as the `mail` source.";
      };
    };
  };

  imports = [ ./backupper.nix ];

  config = mkIf cfg.enable {
    users.groups.mail_downloader = {};
    users.users.mail_downloader = {
      createHome = true;
      home = "/var/lib/mail_downloader/";
      isSystemUser = true;
      group = config.users.groups.mail_downloader.name;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.mailDir} 0750 mail_downloader mail_downloader - -"
      # fix the owner of mails moved here from elsewhere
      "Z ${cfg.mailDir} - mail_downloader mail_downloader - -"
    ];

    # Repositories are chosen by the host
    services.backupper.sources.mail = {
      paths = [ cfg.mailDir ];
      groups = [ config.users.groups.mail_downloader.name ];
      runBefore = [ "mail_downloader.service" ];
    };

    sops.secrets.offlineimap_configuration = {
      mode = "0400";
      owner = config.users.users.mail_downloader.name;
      group = config.users.users.mail_downloader.group;
    };

    systemd.services.mail_downloader = {
      description = "Sync IMAP to local folders";

      after = [ "network.target" ];
      unitConfig.RequiresMountsFor = [ cfg.mailDir ];
      serviceConfig = {
        User = config.users.users.mail_downloader.name;
        Group = config.users.users.mail_downloader.group;
        Type = "oneshot";
        # new files readable by the group, hence by the backup
        UMask = "0027";

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

{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.backupper;
  secrets = config.sops.secrets;
  miniflux_cfg = config.services.miniflux_wrapper;
  backup_user = config.users.users.backupper.name;
  backup_group = config.users.groups.backupper.name;
in

with lib;

{
  imports =
    [
      ./miniflux_wrapper.nix
    ];

  options.services.backupper = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };

    groups = mkOption {
      type = types.listOf types.str;
      default = [];
    };

    hdd_mountpoint = mkOption {
      type = types.path;
      default = "/mnt/backup_hdd";
    };
  };

  config = mkIf cfg.enable {
    users.groups.backupper = {};
    users.users.backupper = {
      createHome = true;
      home = "/var/lib/backupper/";
      isSystemUser = true;
      group = backup_group;
      extraGroups = cfg.groups ++ [ miniflux_cfg.backupGroup ];
      uid = 123;
    };

    sops.secrets.restic_remote_configuration = {
      mode = "0400";
      owner = backup_user;
      group = config.users.users.backupper.group;
    };

    sops.secrets.restic_local_configuration = {
      mode = "0400";
      owner = backup_user;
      group = config.users.users.backupper.group;
    };

    systemd.tmpfiles.rules = [
      "d ${config.users.users.backupper.home + ".cache/restic"} 0750 ${backup_user} ${backup_group} -"
    ];

    systemd.services.backup_remote = {
      description = "Perform backup to remote location";
      requires = if miniflux_cfg.enable
                 then [ "miniflux_backup_admin_opml.service" ]
                 else [];
      after = if miniflux_cfg.enable
              then [ "miniflux_backup_admin_opml.service" ]
              else [];

      path = with pkgs; [ restic ];

      script = "exec ${./backupper.sh}";

      serviceConfig = {
        User = backup_user;
        Type = "oneshot";

        EnvironmentFile = [
          secrets.restic_remote_configuration.path
        ];
        Environment =
          if miniflux_cfg.enable
          then ["MINIFLUX_BACKUP_ENABLED=y"
                "MINIFLUX_BACKUP_FOLDER=${miniflux_cfg.backupFolder}"]
          else [];

        TemporaryFileSystem = "/";
        PrivateTmp = true;
        BindPaths = [
          "${config.users.users.backupper.home}/.cache/restic"
        ];
        BindReadOnlyPaths = [
          "/bin/sh"
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/etc/passwd"
          "/nix/store"
          miniflux_cfg.backupFolder
        ];
      };

      startAt = "*-*-* 03:00:00";
    };
  };
}

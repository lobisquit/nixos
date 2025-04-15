{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.backupper;
  secrets = config.sops.secrets;
in

{
  options.services.backupper = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "readonly_storage";
    };

    data_directory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sftp_storage/data";
    };

    hdd_mountpoint = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/backup_hdd/";
    };
  };

  config = mkIf cfg.enable {
    users.groups."${cfg.group}" = {};
    users.users.backupper = {
      createHome = true;
      home = "/var/lib/backupper/";
      isSystemUser = true;
      group = cfg.group;
      uid = 123;
    };

    sops.secrets.restic_remote_configuration = {
      mode = "0400";
      owner = config.users.users.backupper.name;
      group = config.users.users.backupper.group;
    };

    sops.secrets.restic_local_configuration = {
      mode = "0400";
      owner = config.users.users.backupper.name;
      group = config.users.users.backupper.group;
    };

    systemd.services.backup_remote = {
      description = "Perform backup to remote location";

      path = with pkgs; [ restic ];

      script = "exec ${./backupper.sh} Documenti";

      serviceConfig = {
        User = config.users.users.backupper.name;
        Type = "oneshot";

        EnvironmentFile = [
          secrets.restic_remote_configuration.path
        ];
        Environment = [
          "DATA_DIR=${cfg.data_directory}"
        ];

        TemporaryFileSystem = "/";
        PrivateTmp = true;
        BindPaths = [
          "${config.users.users.backupper.home}/.cache/restic/"
        ];
        BindReadOnlyPaths = [
          "/bin/sh"
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/etc/passwd"
          "/nix/store"
          cfg.data_directory
        ];
      };

      startAt = "*-*-* 03:00:00";
    };

    systemd.timers.backup_remote.timerConfig.RandomizedDelaySec = "30m";

    systemd.mounts = [{
      type = "exfat";
      mountConfig = {
        Options = "defaults,uid=${toString config.users.users.backupper.uid}";
      };
      bindsTo = [ "backup_local.service" ];
      what = "/dev/disk/by-uuid/FA3D-8377";
      where = (toString cfg.hdd_mountpoint);
    }];

    systemd.services.backup_local = {
      description = "Perform backup to local location";
      requires = [ "mnt-backup_hdd.mount" ];
      after = [ "mnt-backup_hdd.mount" ];

      path = with pkgs; [
        restic
        curl
      ];

      preStart = "sleep 5";
      script = "exec ${./backupper.sh} Documenti Immagini Musica Video";

      serviceConfig = {
        User = config.users.users.backupper.name;
        Type = "oneshot";

        EnvironmentFile = [
          secrets.restic_local_configuration.path
        ];
        Environment = [
          "RESTIC_REPOSITORY=${cfg.hdd_mountpoint}/home/restic-repo"
          "DATA_DIR=${cfg.data_directory}"
        ];

        TemporaryFileSystem = "/";
        PrivateTmp = true;
        BindPaths = [
          "${config.users.users.backupper.home}/.cache/restic/"
          "${cfg.hdd_mountpoint}/home/restic-repo"
        ];
        BindReadOnlyPaths = [
          "/bin/sh"
          "/etc/passwd"
          "/nix/store"
          cfg.data_directory
        ];
      };
    };
  };
}

{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.backupper;
  secrets = config.sops.secrets;
  miniflux_cfg = config.services.miniflux_wrapper;
in

{
  imports =
    [
      ./miniflux_wrapper.nix
    ];

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

    postgres_backup = lib.mkOption {
      type = lib.types.bool;
      default = miniflux_cfg.enable;
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

    users.users.postgres = {};

    systemd.services.postgresql_create_backupper_user = {
      description = "Set proper postgresql user for backupper";
      before = [ "backup_local.service"
                 "backup_remote.service"
               ];

      serviceConfig = {
        Type = "oneshot";
        User = config.users.users.postgres.name;

        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        BindReadOnlyPaths = [
          "/etc/passwd"
          "/nix/store"
          "/run/postgresql"
        ];
      };

      path = with pkgs; [ postgresql ];
      script = ''psql -c "DROP ROLE IF EXISTS backupper;
                          CREATE ROLE backupper LOGIN;
                          GRANT pg_read_all_data TO backupper;"'';
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

    sops.secrets.miniflux_token = {
      mode = "0400";
      owner = config.users.users.backupper.name;
      group = config.users.users.backupper.group;
    };

    systemd.services.backup_remote = {
      description = "Perform backup to remote location";
      requires = [ "postgresql_create_backupper_user.service" ];
      after = [ "postgresql_create_backupper_user.service" ];

      path = with pkgs; [
        restic
        curl
        postgresql
      ];

      script = "exec ${./backupper.sh} Documenti";

      serviceConfig = {
        User = config.users.users.backupper.name;
        Type = "oneshot";

        EnvironmentFile = [
          secrets.restic_remote_configuration.path
          secrets.miniflux_token.path
        ];
        Environment = [
          "MINIFLUX_PORT=${ toString miniflux_cfg.internalPort }"
          "DATA_DIR=${cfg.data_directory}"
          "POSTGRES_BACKUP=${if cfg.postgres_backup then "y" else ""}"
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
          "/run/postgresql"
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
      requires = [ "mnt-backup_hdd.mount"
                   "postgresql_create_backupper_user.service" ];
      after = [ "mnt-backup_hdd.mount"
                "postgresql_create_backupper_user.service" ];

      path = with pkgs; [
        restic
        curl
        postgresql
      ];

      preStart = "sleep 5";
      script = "exec ${./backupper.sh} Documenti Immagini Musica Video";

      serviceConfig = {
        User = config.users.users.backupper.name;
        Type = "oneshot";

        EnvironmentFile = [
          secrets.restic_local_configuration.path
          secrets.miniflux_token.path
        ];
        Environment = [
          "MINIFLUX_PORT=${ toString miniflux_cfg.internalPort }"
          "RESTIC_REPOSITORY=${cfg.hdd_mountpoint}/home/restic-repo"
          "DATA_DIR=${cfg.data_directory}"
          "POSTGRES_BACKUP=${if cfg.postgres_backup then "y" else ""}"
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
          "/run/postgresql"
        ];
      };
    };
  };
}

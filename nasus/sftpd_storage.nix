{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.sftpd_storage;
in

{
  imports =
    [
      ./sshd_wrapper.nix
    ];

  options.services.sftpd_storage = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "storage";
    };

    readonly_group = lib.mkOption {
      type = lib.types.str;
      default = "readonly_storage";
    };

    data_directory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sftp_storage/data";
    };
  };

  config = mkIf cfg.enable {

    users.groups = {
      "${cfg.group}" = {};
      "${cfg.readonly_group}" = {};
    };

    users.users.storage_unison = {
      home = "/var/lib/storage_unison/";
      createHome = true;
      group = cfg.group;
      isSystemUser = true;
      shell = "/bin/sh";

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMx+4brxB5LBmoTehcqbdzpL8vlkqyYwop922dSUPBE2 enrico@lobisquit-pc"
      ];
    };

    users.users.storage = {
      home = "/var/lib/storage/";
      createHome = true;
      group = cfg.group;
      isSystemUser = true;

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMcmh/Qkx+yoMlzkQzGvXJcv02lHG1rj0sU70wqFp3HC termux@lobisquit-padel1"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID04L2cT9niM1G8JjFGtc86im2dj8gOInzOJeUtq9lAl enrico@lobisquit-pc"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEPQruWsbaoPtD4EmKS+RZZn3zughIgeVIXhMtjKur9m cx-explorer@tablet"
      ];
    };

    services.openssh.extraConfig = ''
    Match User storage
      ForceCommand internal-sftp -d ${ baseNameOf cfg.data_directory }
      PasswordAuthentication no
      ChrootDirectory ${ dirOf cfg.data_directory }
      PermitTunnel no
      AllowAgentForwarding no
      AllowTcpForwarding no
    Match All
    '';

    systemd.services.sshd.requires = [ "storage-set-permissions.service" ];

    systemd.tmpfiles.rules = [
      "d ${dirOf cfg.data_directory} 0755 root root -"
      "d ${cfg.data_directory} 0770 storage ${cfg.group} -"
    ];

    systemd.services."storage-set-permissions" = {
      description = "Set the correct permissions to the storage folder";
      path = with pkgs; [ acl strace ];

      script = ''
          set -ex

          # set sticky bit, to propagate default permissions to new files
          chmod g+s "${cfg.data_directory}"

          setfacl --recursive --default -m g::rwX "${cfg.data_directory}"
          setfacl --recursive --default -m o::0 "${cfg.data_directory}"

          setfacl --recursive -m g::rwX "${cfg.data_directory}"
          setfacl --recursive -m o::0 "${cfg.data_directory}"

          if [[ ! -z "${cfg.readonly_group}" ]]; then
              setfacl --recursive -m g:"${cfg.readonly_group}":rX "${cfg.data_directory}"
              setfacl --recursive --default -m g:"${cfg.readonly_group}":rX "${cfg.data_directory}"
          fi
          '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "true";
        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        BindPaths = [ "${cfg.data_directory}" ];
        BindReadOnlyPaths = [
          "/etc/group"
          "/nix/store"
        ];
      };
    };
  };
}

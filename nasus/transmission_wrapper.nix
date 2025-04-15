{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.transmission_wrapper;
  samba_cfg = config.services.samba_wrapper;
  secrets = config.sops.secrets;
  user_conf = config.users.users.transmission;
  tr_user = config.services.transmission.user;
  tr_group = config.services.transmission.group;
in
{
  imports =
    [
      ./samba_wrapper.nix
    ];

  options = {
    services.transmission_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      internalPort = mkOption {
        type = types.int;
        default = 8035;
      };

      home = mkOption {
        type = types.path;
        default = "/mnt/storage_drive/transmission";
      };
    };
  };

  config = mkIf cfg.enable {
    sops.secrets.transmission_credentials = {
      mode = "0400";
      owner = config.services.transmission.user;
      group = config.services.transmission.group;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.home} 0750 ${tr_user} ${tr_group} -"
      "d ${cfg.home}/.config/transmission-daemon 0750 ${tr_user} ${tr_group} -"
      "d ${cfg.home}/Downloads 0750 ${tr_user} ${tr_group} -"
      "d ${cfg.home}/Others 0750 ${tr_user} ${tr_group} -"
    ];

    services.transmission = {
      enable = true;
      openRPCPort = true;
      credentialsFile = secrets.transmission_credentials.path;
      openPeerPorts = true;
      home = cfg.home;
      settings = {
        incomplete-dir-enabled = false;
        rpc-bind-address = "0.0.0.0";
        rpc-whitelist-enabled = true;
        rpc-whitelist = "127.0.0.1,192.168.77.*,192.168.0.*";
        blocklist-enabled = true;
        blocklist-url = "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz";
        ratio-limit-enabled = true;
        ratio-limit = 3.0;
      };
    };

    systemd.services.transmission.serviceConfig.BindPaths = [
       "${cfg.home}/Others"
    ];

    users = mkIf samba_cfg.enable {
      groups.samba_enrico = { };
      users.samba_enrico = {
        isSystemUser = true;
        group = "samba_enrico";
        home = "/var/empty";
        createHome = false;
        shell = pkgs.shadow;
      };

      groups.samba_erika = { };
      users.samba_erika = {
        isSystemUser = true;
        group = "samba_erika";
        home = "/var/empty";
        createHome = false;
        shell = pkgs.shadow;
      };
    };

    sops.secrets.smbpasswd = mkIf samba_cfg.enable { };

    systemd.services.samba_setup_users = mkIf samba_cfg.enable {
      description = "Set user passwords with smbpasswd";

      after = [ "samba.target" ];
      wantedBy = [ "multi-user.target" ];

      path = with pkgs; [ samba ];

      script = ''
        set -e

        while read -r line; do
          chunks=( $line )
          username="''${chunks[0]}"
          password="''${chunks[1]}"
          echo -e "$password\n$password" | smbpasswd -a "$username"
        done < ${secrets.smbpasswd.path}
        '';

      serviceConfig = {
        PrivateNetwork = true;
        TemporaryFileSystem = "/";
        BindPaths = [
          "/var/lib/samba"
          "/var/lock/samba"
        ];
        BindReadOnlyPaths = [
          "/etc/passwd"
          "/etc/samba/smb.conf"
          "/nix/store"
          secrets.smbpasswd.path
        ];
      };
    };

    services.samba.settings = mkIf samba_cfg.enable {
      downloads = mkIf samba_cfg.enable {
        path = "${cfg.home}/Downloads";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "force user" = "transmission";
        "force group" = "transmission";
        "write list" = "transmission";
        "valid users" = "samba_enrico samba_erika";
      };

      others = mkIf samba_cfg.enable {
        path = "${cfg.home}/Others";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "force user" = "transmission";
        "force group" = "transmission";
        "write list" = "transmission";
        "valid users" = "samba_enrico";
      };
    };
  };
}

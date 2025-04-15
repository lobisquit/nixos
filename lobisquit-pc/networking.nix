{ lib, config, pkgs, ... }:

let
  sops_secrets = config.sops.secrets;
in

{
  networking.hostName = "lobisquit-pc";
  networking.networkmanager.enable = true;

  sops.secrets.smb_enrico = { };

  systemd.tmpfiles.rules = [
    "d /mnt/transmission 0750 enrico root -"
    "d /mnt/others 0750 enrico root -"
  ];

  environment.systemPackages = [ pkgs.cifs-utils ];

  fileSystems = {
    "/mnt/transmission" = {
      device = "//nasus.home.lovisotto.it/downloads";
      fsType = "cifs";
      options = [
        "x-systemd.automount"
         "x-systemd.after=network-online.target"
        "nofail,noauto"
        "_netdev"
        "credentials=${sops_secrets.smb_enrico.path}"
      ];
    };
    "/mnt/others" = {
      device = "//nasus.home.lovisotto.it/others";
      fsType = "cifs";
      options = [
        "x-systemd.automount"
        "x-systemd.after=network-online.target"
        "nofail,noauto"
        "_netdev"
        "credentials=${sops_secrets.smb_enrico.path}"
      ];
    };
  };

  sops.secrets = {
    wireguard_private_key = { };
  };

  networking.wg-quick.interfaces = {
    wg-home-inner = {
      address = [ "192.168.77.4/24" ];
      dns = [ "192.168.77.1" ];
      privateKeyFile = sops_secrets.wireguard_private_key.path;

      peers = [
        {
          publicKey = "Wb6v3aDIUvHLlQ76r32ZfzoMkd5matP2YcQt9IOWe3Q=";
          allowedIPs = [ "192.168.77.0/24" "10.0.0.0/24" ];
          endpoint = "home.lovisotto.it:51190";
          persistentKeepalive = 60;
        }
      ];

      autostart = false;
    };

    wg-home-full = {
      address = [ "192.168.77.4/24" ];
      dns = [ "192.168.77.1" ];
      privateKeyFile = config.sops.secrets.wireguard_private_key.path;

      peers = [
        {
          publicKey = "Wb6v3aDIUvHLlQ76r32ZfzoMkd5matP2YcQt9IOWe3Q=";
          allowedIPs = [ "0.0.0.0/0" ];
          endpoint = "home.lovisotto.it:51190";
          persistentKeepalive = 60;
        }
      ];

      autostart = false;
    };
  };
}

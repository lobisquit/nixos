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

  sops.secrets = {
    wireguard_private_key = { };
  };

  networking.wg-quick.interfaces = {
    wg-home-inner = {
      address = [ "10.3.0.4/24" ];
      dns = [ "10.3.0.1" ];
      privateKeyFile = sops_secrets.wireguard_private_key.path;

      peers = [
        {
          publicKey = "Wb6v3aDIUvHLlQ76r32ZfzoMkd5matP2YcQt9IOWe3Q=";
          allowedIPs = [ "10.3.0.0/16" ];
          endpoint = "home.lovisotto.it:51190";
          persistentKeepalive = 60;
        }
      ];

      autostart = false;
    };

    wg-home-full = {
      address = [ "10.3.0.4/24" ];
      dns = [ "10.3.0.1" ];
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

  sops.secrets.ssh_self_cert = {
    mode = "0400";
    owner = "enrico";
  };

  sops.secrets.ssh_self_key = {
    mode = "0400";
    owner = "enrico";
  };
}

{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.samba_wrapper;
  secrets = config.sops.secrets;
in
{
  options = {
    services.samba_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      dataDir = mkOption {
        type = types.path;
        default = "/mnt/data/";
      };
    };
  };

  config = mkIf cfg.enable {
    networking.firewall = {
      allowPing = true;
      allowedTCPPorts = [ 5357 ]; # wsdd
      allowedUDPPorts = [ 3702 ]; # wsdd
    };

    services.samba-wsdd.enable = true;

    services.samba = {
      enable = true;
      openFirewall = true;
      settings = {
        global = {
          "server string" = "${config.networking.hostName}";
          "netbios name" = "${config.networking.hostName}";
          "workgroup" = "WORKGROUP";
          "security" = "user";

          "create mask" = "0664";
          "force create mode" = "0664";
          "directory mask" = "0775";
          "force directory mode" = "0775";
          "follow symlinks" = "yes";

          "hosts allow" = "192.168.0.0/24 192.168.77.0/24 localhost";
          "hosts deny" = "0.0.0.0/0";
          "guest account" = "nobody";
          "map to guest" = "bad user";
        };
      };
    };
  };
}

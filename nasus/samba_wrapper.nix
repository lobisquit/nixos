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
      allowedTCPPorts = [
        445  # SMB over TCP, the only port used without NetBIOS
        5357 # wsdd
      ];
      allowedUDPPorts = [ 3702 ]; # wsdd
    };

    services.samba-wsdd.enable = true;

    services.samba = {
      enable = true;
      # only 445 is needed (see above): the module would also open the
      # NetBIOS ports 137-139
      openFirewall = false;

      # NetBIOS name service and domain integration are not used: clients
      # find the server with wsdd or connect by name/IP
      nmbd.enable = false;
      winbindd.enable = false;

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

          "hosts allow" = "10.1.0.0/16 10.3.0.0/16 localhost";
          "hosts deny" = "0.0.0.0/0";

          # No guests and no anonymous sessions: unknown users and wrong
          # passwords are refused instead of becoming "nobody", and
          # shares can't be listed without logging in.
          "map to guest" = "never";
          "restrict anonymous" = "2";

          # Only SMB 3, encrypted when the client supports it
          "server min protocol" = "SMB3";
          "server smb encrypt" = "desired";

          # No NetBIOS (nmbd is off) and no printers
          "disable netbios" = "yes";
          "smb ports" = "445";
          "load printers" = "no";
          "printing" = "bsd";
          "printcap name" = "/dev/null";
          "disable spoolss" = "yes";
        };
      };
    };
  };
}

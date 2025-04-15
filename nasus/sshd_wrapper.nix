{ inputs, outputs, lib, config, pkgs, ... }:
with lib;
let
  cfg = config.services.sshd_wrapper;
in
{
  options.services.sshd_wrapper = {
    port = lib.mkOption {
      type = lib.types.int;
      default = 2222;
    };
  };

  config = {
    services.openssh = {
      enable = true;

      ports = [ cfg.port ];
      openFirewall = true;

      allowSFTP = true;

      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        X11Forwarding = false;

        AllowUsers = [ "root" "storage" "storage_unison" ];

        # Use only the algorithms recommended by SSH audit
        Ciphers = [ "chacha20-poly1305@openssh.com"
                    "aes256-gcm@openssh.com"
                    "aes128-gcm@openssh.com"
                    "aes256-ctr"
                    "aes192-ctr"
                    "aes128-ctr" ];


        KexAlgorithms = [ "curve25519-sha256"
                          "curve25519-sha256@libssh.org"
                          "diffie-hellman-group16-sha512"
                          "diffie-hellman-group18-sha512"
                          "diffie-hellman-group14-sha256" ];


        Macs = [ "hmac-sha2-256-etm@openssh.com"
                 "hmac-sha2-512-etm@openssh.com"
                 "umac-128-etm@openssh.com" ];
      };
    };

    users.users.root = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICsHxNkEZo0CU1LCrqXfrMJ1rQshWtQCcp5XewttcLe2 enrico@lobisquit-minipc"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPHQvG3o1UdCWZ4N0iY1UyaKt0ANsbMUXluqCRIzxBp JuiceSSH@Padel1"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOCNCp4ek5dvMRBOOqDlmuH+lQ41Rk4jG2Mcm/tHdhkj Termius@tablet"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINc+i2CAGsqJR1xSd1r8+R30MCQoyXDTVd+8ObJ+KjKP enrico@lobisquit-pc"
      ];
    };
  };
}

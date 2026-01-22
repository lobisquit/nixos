{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  nix.settings.experimental-features = ["nix-command" "flakes"];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "lobisquit-minipc";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Rome";

  services.xserver.enable = true;
  services.xserver.xkb.layout = "gb";
  console.useXkbConfig = true;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.enrico = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    packages = with pkgs; [
      firefox
      restic
      git
      (writeShellScriptBin "mount_encrypted" '' ${builtins.readFile ./mount_encrypted.sh} '')
      (writeShellScriptBin "fetch_local" '' ${builtins.readFile ./fetch_local.sh} '')
    ];
  };

  environment.systemPackages = with pkgs; [
    htop
    nmon
    sops
    tmux
    wireguard-tools
    cryptsetup
  ];

  services.xserver.videoDrivers = [ "modesetting" ];
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
    ];
  };

  networking.firewall.enable = true;

  # secrets
  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  sops.secrets.wireguard_private_key = { };

  networking.wg-quick.interfaces = {
    wg-home-inner = {
      address = [ "192.168.77.6/24" ];
      dns = [ "192.168.77.1" ];
      privateKeyFile = config.sops.secrets.wireguard_private_key.path;

      peers = [
        {
          publicKey = "Wb6v3aDIUvHLlQ76r32ZfzoMkd5matP2YcQt9IOWe3Q=";
          allowedIPs = [ "192.168.77.0/24" "10.0.0.0/24" "10.0.14.0/24" ];
          endpoint = "home.lovisotto.it:51190";
          persistentKeepalive = 60;
        }
      ];

      autostart = false;
    };

    wg-home-full = {
      address = [ "192.168.77.6/24" ];
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

  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.lxqt.enable = true;

  sops.secrets.restic_local_configuration = {
    mode = "0400";
    owner = config.users.users.enrico.name;
    group = config.users.users.enrico.group;
  };

  system.stateVersion = "25.11";
}

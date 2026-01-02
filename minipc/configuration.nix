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
      (writeShellScriptBin "mount_encrypted" '' ${builtins.readFile ./mount_encrypted.sh} '')
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

  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.lxqt.enable = true;

  system.stateVersion = "25.11";
}

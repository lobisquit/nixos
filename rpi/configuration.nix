{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelParams = [
    "console=ttyS1,115200n8"
  ];

  networking.hostName = "rpi";

  time.timeZone = "Europe/Rome";

  environment.systemPackages = with pkgs; [
    htop
    nmon
    gnumake
    sops
    tmux
  ];

  services.openssh = {
     enable = true;
     openFirewall = true;
  };

  networking.firewall.enable = true;

  system.stateVersion = "25.05";

  networking.firewall.allowedTCPPorts = [ 8123 ];
}

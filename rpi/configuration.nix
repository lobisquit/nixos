{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./monitoring.nix
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
    age
  ];

  services.openssh = {
     enable = true;
     openFirewall = true;
  };

  networking.firewall.enable = true;

  system.stateVersion = "25.05";

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  services.monitoring.enable = true;
}

{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./monitoring.nix
      ./podcasts_fetcher.nix
      ./miniflux_wrapper.nix
      ./backupper.nix
    ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelParams = [
    "console=ttyS1,115200n8"
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];

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

  services.podcasts_fetcher = {
    enable = true;
    podcastDir = "/mnt/storage_drive/podcasts";
    protectedPaths = [];
  };

  services.miniflux_wrapper.enable = true;

  services.backupper.enable = true;
}

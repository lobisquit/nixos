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

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "octoprint";

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

  system.stateVersion = "25.11";

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  services.monitoring.enable = true;

  # services.podcasts_fetcher = {
  #   enable = true;
  #   podcastDir = "/mnt/storage_drive/podcasts";
  #   protectedPaths = [];
  # };

  # services.miniflux_wrapper.enable = true;

  # services.backupper.enable = true;

  sops.secrets.wifi_password = {
    mode = "0400";
  };

  networking.wireless = {
    enable = true;
    secretsFile = config.sops.secrets.wifi_password.path;
    networks = {
      "SuchReliableMuchControl".pskRaw = "ext:home";
    };
  };
}

{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./backlight_off.nix
      ./hardware-configuration.nix
      ./doorman.nix
      ./monitoring.nix
      ./podcasts_fetcher.nix
      ./miniflux_wrapper.nix
      ./backupper.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.logind.extraConfig = "HandleLidSwitch=ignore";

  nix.settings.experimental-features = ["nix-command" "flakes"];

  time.timeZone = "Europe/Rome";

  networking.hostName = "bacero";

  i18n.defaultLocale = "it_IT.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "it_IT.UTF-8";
    LC_IDENTIFICATION = "it_IT.UTF-8";
    LC_MEASUREMENT = "it_IT.UTF-8";
    LC_MONETARY = "it_IT.UTF-8";
    LC_NAME = "it_IT.UTF-8";
    LC_NUMERIC = "it_IT.UTF-8";
    LC_PAPER = "it_IT.UTF-8";
    LC_TELEPHONE = "it_IT.UTF-8";
    LC_TIME = "it_IT.UTF-8";
  };

  console.keyMap = "it2";

  environment.systemPackages = with pkgs; [
    htop
    nmon
    sops
    tmux
  ];

  services.openssh = {
     enable = true;
     openFirewall = true;
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICsHxNkEZo0CU1LCrqXfrMJ1rQshWtQCcp5XewttcLe2 enrico@lobisquit-minipc"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJe9tAxZdwMpXBEZNnzJWjqLOHSJz5/VRUYawVu6MzAl JuiceSSH"
  ];

  networking.firewall.enable = true;

  system.stateVersion = "25.05";

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  services.monitoring.enable = true;

  # duplicate with doorman if enabled
  services.pulseaudio.enable = true;
  users.extraUsers.root.extraGroups = [ "audio" ];

  services.podcasts_fetcher = {
    enable = true;
    podcastDir = "/mnt/storage_drive/podcasts";
    protectedPaths = [];
  };

  services.backlight_off.enable = true;

  services.miniflux_wrapper.enable = true;

  services.backupper.enable = true;

  services.doorman.enable = true;
}

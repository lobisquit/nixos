{ inputs, outputs, libs, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./locale.nix
      ./networking.nix
      ./sound.nix
      ./users.nix
      ./backup_hdd.nix
      ./xserver.nix
      inputs.home-manager.nixosModules.home-manager
    ];

  nix.settings.experimental-features = ["nix-command" "flakes"];

  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "23.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.tmp.cleanOnBoot = true;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  services.printing = {
    enable = true;
    drivers = [ pkgs.epson-escpr ];
  };

  hardware.printers.ensurePrinters = [{
  name = "EpsonXP2200_Somina_Gens";
  deviceUri = "socket://192.168.1.57:9100";
  model = "epson-inkjet-printer-escpr/Epson-XP-2200_Series-epson-escpr-en.ppd";
  ppdOptions.PageSize = "A4";
}];

  environment.systemPackages = with pkgs; [
    git
    wireguard-tools
    acl
    btop
    qmk
    vial
  ];

  home-manager = {
    extraSpecialArgs = { inherit inputs outputs; };
    users = {
      enrico = import ./enrico.nix;
    };
  };

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/etc/age/enrico.txt";

  # required by platformio and Via auto-detection
  services.udev.packages = with pkgs; [
    platformio-core.udev
    vial
    via
  ];

  hardware.keyboard.qmk.enable = true;
  programs.kclock.enable = true;

  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.sane-airscan ];
  };
  users.users.enrico.extraGroups = [ "scanner" "lp" ];

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
}

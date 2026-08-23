{ inputs, outputs, libs, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./locale.nix
      ./networking.nix
      ./sound.nix
      ./users.nix
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

  services.printing.enable = true;

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
}

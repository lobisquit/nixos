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
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  services.printing.enable = true;

  environment.systemPackages = with pkgs; [
    git
    wireguard-tools
    acl
    htop
  ];

  home-manager = {
    extraSpecialArgs = { inherit inputs outputs; };
    users = {
      enrico = import ./enrico.nix;
    };
  };

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/etc/age/enrico.txt";

  # required by platformio
  services.udev.packages = with pkgs; [ platformio-core.udev ];

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "beancount_bot" ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust
    '';
    ensureUsers = [
      {
        name = "beancount_bot";
        ensureDBOwnership = true;
      }
    ];
  };
}

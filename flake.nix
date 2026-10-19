{
  inputs = {
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nixpkgs_unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs_stable.url = "github:nixos/nixpkgs/nixos-26.05";

    home-manager.inputs.nixpkgs.follows = "nixpkgs_unstable";
    home-manager.url = "github:nix-community/home-manager/master";

    sops-nix_stable.url = "github:Mic92/sops-nix";
    sops-nix_stable.inputs.nixpkgs.follows = "nixpkgs_stable";

    sops-nix_unstable.url = "github:Mic92/sops-nix";
    sops-nix_unstable.inputs.nixpkgs.follows = "nixpkgs_unstable";
  };

  outputs = { self,
              nixpkgs_unstable,
              nixpkgs_stable,
              home-manager,
              nixos-hardware,
              sops-nix_stable,
              sops-nix_unstable,
              ...
            }
    @ inputs:
      let
        inherit (self) outputs;
      in {
        nixosConfigurations = {
          lobisquit-pc = nixpkgs_unstable.lib.nixosSystem {
            specialArgs = {inherit inputs outputs;};
            modules = [
              ./lobisquit-pc/configuration.nix
              sops-nix_unstable.nixosModules.sops
            ];
          };

          nasus = nixpkgs_stable.lib.nixosSystem {
            specialArgs = {inherit inputs outputs;};
            modules = [
              ./nasus/configuration.nix
              sops-nix_stable.nixosModules.sops
            ];
          };

          bacero = nixpkgs_stable.lib.nixosSystem {
            specialArgs = {inherit inputs outputs;};
            modules = [
              ./bacero/configuration.nix
              sops-nix_stable.nixosModules.sops
            ];
          };

          minipc = nixpkgs_stable.lib.nixosSystem {
            specialArgs = {inherit inputs outputs;};
            modules = [
              ./minipc/configuration.nix
              sops-nix_stable.nixosModules.sops
            ];
          };

          octoprint = nixpkgs_unstable.lib.nixosSystem {
            specialArgs = {inherit inputs outputs;};
            system = "aarch64-linux";
            modules = [
              ./octoprint/configuration.nix
              sops-nix_stable.nixosModules.sops
              nixos-hardware.nixosModules.raspberry-pi-4
            ];
          };
        };

        homeConfigurations = {
          "enrico" = home-manager.lib.homeManagerConfiguration {
            pkgs = nixpkgs_unstable.legacyPackages.x86_64-linux;
            extraSpecialArgs = {inherit inputs outputs;};
            modules = [ ./lobisquit-pc/enrico.nix ];
          };
        };
      };
}

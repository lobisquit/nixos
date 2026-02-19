{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.navidrome_wrapper;
  secrets = config.sops.secrets;
in
{
  imports =
    [
      ./nginx_wrapper.nix
    ];

  options = {
    services.navidrome_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      internalPort = mkOption {
        type = types.int;
        default = 4533;
      };

      group = mkOption {
        type = types.str;
        default = "navidrome";
      };

      fqdn = mkOption {
        type = types.str;
        default = "navidrome.domain";
      };

      musicFolder = mkOption {
        type = types.path;
        default = "/mnt/storage_drive/navidrome";
      };
    };
  };

  config = mkIf cfg.enable {
    # Overlay to fix build issue from
    # https://github.com/NixOS/nixpkgs/issues/481611#issuecomment-3890134071
    nixpkgs.overlays = [
      (self: super: {
        navidrome = self.callPackage (pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/cimm/nixpkgs/71aa374ad541b41e6fccd543c67b6952d2ccafca/pkgs/by-name/na/navidrome/package.nix";
          sha256 = "16mfj85w8d7vzc9pgcgjn7a71z7jywqpdn8igk9zp0hw9dvm9rmq";
        }) {};
      })
    ];

    services.navidrome = {
      enable = true;
      openFirewall = true;
      group = cfg.group;

      settings = {
        Address = "127.0.0.1";
        Port = cfg.internalPort;
        MusicFolder = cfg.musicFolder;
        EnableSharing = true;
      };
    };

    services.nginx_wrapper.enable = true;
    services.nginx.virtualHosts."${cfg.fqdn}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.internalPort}";
      };
    };

    sops.secrets.desec_token = {
      mode = "0400";
      owner = "acme";
      group = "acme";
    };

    security.acme.certs = {
      "${cfg.fqdn}" = {
        domain = cfg.fqdn;
        group = "nginx";
        dnsProvider = "desec";
        dnsResolver = "ns1.desec.io:53";
        environmentFile = secrets.desec_token.path;
        server = "https://acme-v02.api.letsencrypt.org/directory";
        webroot = null;
      };
    };
  };
}

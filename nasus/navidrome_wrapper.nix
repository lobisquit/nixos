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

      enableSharing = mkOption {
        type = types.bool;
        default = false;
        description = "Public share links (anyone with the link can listen, no login).";
      };

      musicFolder = mkOption {
        type = types.path;
        default = "/mnt/storage_drive/navidrome";
      };
    };
  };

  config = mkIf cfg.enable {
    services.navidrome = {
      enable = true;
      # listens on localhost only: reached through nginx
      openFirewall = false;
      group = cfg.group;

      settings = {
        Address = "127.0.0.1";
        Port = cfg.internalPort;
        MusicFolder = cfg.musicFolder;
        EnableSharing = cfg.enableSharing;
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

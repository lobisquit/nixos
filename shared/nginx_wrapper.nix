{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.nginx_wrapper;
in
{
  options = {
    services.nginx_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  };

  config = mkIf cfg.enable {
    security.acme = {
      defaults.email = "webmaster@lovisotto.it";
      acceptTerms = true;
    };

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 80 443 ];
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
    };
  };
}

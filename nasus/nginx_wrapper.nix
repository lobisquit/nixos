{ config, lib, options, pkgs, ... }:

with lib;

{
  imports =
    [
      ./filebrowser_wrapper.nix
      ./miniflux_wrapper.nix
    ];

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
}

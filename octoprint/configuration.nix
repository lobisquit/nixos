{ config, lib, pkgs, ... }:

let
  secrets = config.sops.secrets;
in
{
  imports =
    [
      ./hardware-configuration.nix
      ./monitoring.nix
      ./nginx_wrapper.nix
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

    ffmpeg
    v4l-utils
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

  sops.secrets.wifi_password = {
    mode = "0400";
    owner = "wpa_supplicant";
  };

  networking.wireless = {
    enable = true;
    secretsFile = config.sops.secrets.wifi_password.path;
    networks = {
      "SuchReliableMuchControl".pskRaw = "ext:home";
    };
  };

  services.octoprint = {
    enable = true;
    openFirewall = true;
  };

  users.users."${config.services.octoprint.user}".extraGroups = ["video"];

  services.mjpg-streamer = {
    enable = true;
  };

  networking.firewall.allowedTCPPorts = [ 5050 ];
  networking.firewall.allowedUDPPorts = config.networking.firewall.allowedTCPPorts;

  sops.secrets.lego_acme_configuration.mode = "0400";
  services.nginx_wrapper.env_file = config.sops.secrets.lego_acme_configuration.path;

  services.nginx_wrapper.enable = true;
  services.nginx.virtualHosts."octoprint.home.lovisotto.it" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.octoprint.port}";
      recommendedProxySettings = true;
    };

    locations."/mjpg/" = {
      proxyPass = "http://127.0.0.1:5050/";
      recommendedProxySettings = true;
    };
  };

  sops.secrets.desec_token = {
    mode = "0400";
    owner = "acme";
    group = "acme";
  };

  security.acme.certs = {
    "octoprint.home.lovisotto.it" = {
      domain = "octoprint.home.lovisotto.it";
      group = "nginx";
      dnsProvider = "desec";
      dnsResolver = "ns1.desec.io:53";
      environmentFile = secrets.desec_token.path;
      server = "https://acme-v02.api.letsencrypt.org/directory";
      webroot = null;
      extraLegoFlags = [];
    };
  };
}

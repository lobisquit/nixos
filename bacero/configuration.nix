{ config, lib, pkgs, ... }:

let
  secrets = config.sops.secrets;
in
{
  imports =
    [
      ./backlight_off.nix
      ./hardware-configuration.nix
      ./doorman.nix
      ./monitoring.nix
      ./podcasts_fetcher.nix
      ./miniflux_wrapper.nix
      ./cgit_wrapper.nix
      ./backupper.nix
      ./xmpp/mail_notifier.nix
      ./xmpp/rain_notifier.nix
      ./xmpp/cinema_notifier.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.logind.settings.Login.HandleLidSwitch = "ignore";

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

  environment.etc."ssh/ca_key.pub" = {
    source = ../shared/ssh_ca_key.pub;
    mode = "0644";
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    extraConfig = "TrustedUserCAKeys /etc/ssh/ca_key.pub";

    # Only keys and certificates: the NixOS defaults allow passwords.
    # Ciphers, key exchanges and MACs already come from the curated list
    # of NixOS (services.openssh.enableRecommendedAlgorithms).
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthenticationMethods = "publickey";
      PermitRootLogin = "prohibit-password";
      AllowUsers = [ "root" ];

      X11Forwarding = false;
      AllowAgentForwarding = false;

      MaxAuthTries = 3;
      LoginGraceTime = 30;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICsHxNkEZo0CU1LCrqXfrMJ1rQshWtQCcp5XewttcLe2 enrico@lobisquit-minipc"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJxJVIy0OGLKIkzlb+V69iqwc+TY8xaY2NaSV4mjheB2 Termux@padel1"
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

  # reachable only from the LAN and the VPN
  services.cgit_wrapper = {
    enable = true;
    # dedicated key, ~/.ssh/git_lovisotto_it on lobisquit-pc
    authorizedKeys = [ (lib.fileContents ../shared/git_lovisotto_it.pub) ];
  };

  services.backupper = {
    enable = true;
    repositories.remote = {
      startAt = "*-*-* 03:00:00";
      # the B2 key of this host cannot delete: retention is applied
      # from the PC with `make prune_remote`
      prune = false;
    };
    # declared by miniflux_wrapper.nix
    sources.miniflux.repositories = [ "remote" ];
    # declared by cgit_wrapper.nix
    sources.git.repositories = [ "remote" ];
  };

  # PostgreSQL, shared by miniflux and beancount_bot: only Unix sockets,
  # every system user reaches only the database named after it (peer
  # authentication), and only the postgres user is superuser.
  services.postgresql = {
    enableTCPIP = false;
    authentication = lib.mkForce ''
      # TYPE  DATABASE  USER      METHOD
      local   all       postgres  peer map=postgres
      local   sameuser  all       peer
    '';
  };

  services.doorman.enable = true;

  services.xmpp_mail_notifier.enable = true;
  services.xmpp_rain_notifier = {
    enable = true;
    recipients = [ "enrico@lovisotto.it" "erika@lovisotto.it" ];
  };

  services.xmpp_cinema_notifier = {
    enable = true;
    room = "uscite_al_cinema@conference.lovisotto.it";
  };
}

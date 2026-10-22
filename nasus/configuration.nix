{ inputs, outputs, lib, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./sftpd_storage.nix
      ./backlight_off.nix
      ./backupper.nix
      ./monitoring.nix
      ./navidrome_wrapper.nix
      ./transmission_wrapper.nix
      ./samba_wrapper.nix
      ./mail_downloader.nix
      ./cal_card_downloader.nix
      ./xmpp_server.nix
      ./xmpp_irc.nix
      ./xmpp_telegram.nix
      ./xmpp_transcriber_bot.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  services.logind.settings.Login.HandleLidSwitchDocked = "ignore";
  services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";
  services.logind.settings.Login.HandleLidSwitch = "ignore";

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "nasus";

  networking.networkmanager.enable = true;
  time.timeZone = "Europe/Rome";

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

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    wireguard-tools
    acl
    htop
    nmon
    gnumake
    unison
    sops
    tmux
  ];

  system.stateVersion = "24.05";

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";

  services.sftpd_storage = {
    enable = true;
    data_directory = "/mnt/storage_drive/sftp_chroot/data";
  };
  services.backupper = {
    enable = true;

    repositories.remote = {
      startAt = "*-*-* 03:00:00";
      # the B2 key of this host cannot delete: retention is applied
      # from the PC with `make prune_remote`
      prune = false;
    };
    repositories.local = {
      localPath = "/mnt/backup_hdd/home/restic-repo";
      requires = [ "mnt-backup_hdd.mount" ];
    };

    sources = {
      # declared by sftpd_storage.nix
      Documenti.repositories = [ "remote" "local" ];
      Immagini.repositories = [ "local" ];
      Musica.repositories = [ "local" ];
      Video.repositories = [ "local" ];

      # declared by mail_downloader.nix and cal_card_downloader.nix
      mail.repositories = [ "remote" "local" ];
      cal_card.repositories = [ "remote" "local" ];

      # declared by xmpp_server.nix
      prosody.repositories = [ "remote" "local" ];
      prosody_uploads.repositories = [ "local" ];

      # declared by xmpp_irc.nix
      biboumi.repositories = [ "remote" "local" ];

      # declared by xmpp_telegram.nix
      slidgram.repositories = [ "remote" "local" ];
    };
  };

  # External exFAT drive for the local backup, mounted only while it runs
  systemd.mounts = [{
    type = "exfat";
    mountConfig.Options = "defaults,uid=${toString config.users.users.backupper.uid}";
    bindsTo = [ "backup_local.service" ];
    what = "/dev/disk/by-uuid/FA3D-8377";
    where = "/mnt/backup_hdd";
  }];
  systemd.services.backup_local.preStart = "sleep 5";

  services.monitoring.enable = true;

  services.backlight_off.enable = true;

  services.transmission_wrapper = {
    enable = true;
    fqdn = "transmission.home.lovisotto.it";
    allowedNetworks = [ "10.1.0.0/16" "10.3.0.0/16" ];
  };

  services.samba_wrapper.enable = true;

  services.mail_downloader = {
    enable = true;
    mailDir = "/mnt/storage_drive/mail";
  };

  services.cal_card_downloader = {
    enable = true;
    davDir = "/mnt/storage_drive/cal_card";
  };

  services.navidrome_wrapper = {
    enable = true;
    fqdn = "musica.home.lovisotto.it";
    musicFolder = "${config.services.sftpd_storage.data_directory}/Musica";
    group = "storage";
  };

  services.xmpp_server = {
    enable = true;
    federation = false;
  };

  services.xmpp_telegram = {
    enable = true;
    image = "codeberg.org/slidge/slidgram:v0.5.0@sha256:d081775bfeb8ff03eebbea49bb1558edd87f73313a39f78fa054c4ccfa8252ab";
  };
  services.xmpp_irc.enable = true;

  services.xmpp_transcriber_bot = {
    enable = true;
    language = "it";
    cpuThreads = 4;
    model = "large-v3-turbo";
    modelDir = "/mnt/storage_drive/xmpp/transcriber_bot";
    initialPrompt = "Hello Enrico ed Erika, fatemi sapere cosa ne pensate!";
  };
}

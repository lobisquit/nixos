{ inputs, outputs, libs, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./sftpd_storage.nix
      ./telegram_reminder.nix
      ./backlight_off.nix
      ./backupper.nix
      ./monitoring.nix
      ./transmission_wrapper.nix
      ./samba_wrapper.nix
      ./mail_downloader.nix
      ./cal_card_downloader.nix
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
    data_directory = config.services.sftpd_storage.data_directory;
  };

  services.telegram_reminder.enable = true;

  services.monitoring.enable = true;

  services.backlight_off.enable = true;

  services.transmission_wrapper = {
    enable = true;
    fqdn = "transmission.home.lovisotto.it";
    root_domain = "home.lovisotto.it";
  };

  services.samba_wrapper.enable = true;

  services.mail_downloader = {
    enable = true;
    mailDir = "${config.services.sftpd_storage.data_directory}/Documenti/Mail";
  };

  services.cal_card_downloader = {
    enable = true;
    davDir = "${config.services.sftpd_storage.data_directory}/Documenti";
  };

  services.navidrome = {
    enable = true;
    openFirewall = true;
    group = "storage";

    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      MusicFolder = "${config.services.sftpd_storage.data_directory}/Musica";
      EnableSharing = true;
    };
  };

  sops.secrets.lego_acme_configuration = {
    mode = "0400";
    owner = "acme";
    group = "acme";
  };

  services.nginx_wrapper.env_file = config.sops.secrets.lego_acme_configuration.path;
}

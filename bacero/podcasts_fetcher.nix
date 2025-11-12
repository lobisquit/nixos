{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.podcasts_fetcher;
  secrets = config.sops.secrets;

  ilpost_pythonEnv = pkgs.python312.withPackages (ps: with ps; [
    ps.selenium
    ps.feedparser
    ps.pulsectl
    ps.feedgen
  ]);

  base_pythonEnv = pkgs.python312.withPackages (ps: with ps; [
    ps.feedparser
    ps.feedgen
  ]);
in
{
  options = {
    services.podcasts_fetcher = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      podcastDir = mkOption {
        type = types.path;
        default = "/mnt/data/";
      };

      baseUrl = mkOption {
        type = types.str;
        default = "podcast.lovisotto.it";
      };

      protectedPaths = mkOption {
        type = types.listOf types.str;
        default = [];
      };
    };
  };

  config = mkIf cfg.enable {
    services.pulseaudio.enable = true;
    services.pulseaudio.systemWide = true;

    users.groups.podcasts_fetcher = {};
    users.users.podcasts_fetcher = {
      createHome = true;
      home = "/var/lib/podcasts_fetcher/";
      isSystemUser = true;
      group = config.users.groups.podcasts_fetcher.name;
      extraGroups = ["pulse-access"];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.podcastDir} 0750 podcasts_fetcher ${config.services.nginx.group} -"
      "d ${config.users.users.podcasts_fetcher.home}.cache 0750 podcasts_fetcher podcasts_fetcher -"
    ];

    sops.secrets.podcasts_fetcher_ilpost_credentials = {
      mode = "0400";
      owner = config.users.users.podcasts_fetcher.name;
      group = config.users.users.podcasts_fetcher.group;
    };

    sops.secrets.podcasts_fetcher_ilpost_configuration = {
      mode = "0400";
      owner = config.users.users.podcasts_fetcher.name;
      group = config.users.users.podcasts_fetcher.group;
    };

    sops.secrets.podcasts_fetcher_nginx_rss_credentials = {
      mode = "0400";
      owner = config.services.nginx.user;
      group = config.services.nginx.group;
    };

    systemd.services.podcasts_ilpost = {
      description = "Download the latest podcasts from the RSS feeds";

      after = [ "network.target" ];
      serviceConfig = {
        User = config.users.users.podcasts_fetcher.name;
        Group = config.users.users.podcasts_fetcher.group;
        Type = "oneshot";
        EnvironmentFile = secrets.podcasts_fetcher_ilpost_credentials.path;

        PrivateTmp = true;
        InaccessiblePaths = cfg.protectedPaths ++ [
          "/home"
          "/root"
          "/boot"
        ];
      };

      path = with pkgs; [
        ilpost_pythonEnv
        ffmpeg
        pulseaudio
        firefox
        geckodriver
        which
      ];

      script = ''
        set -e

        export PYTHONPATH=$(${ilpost_pythonEnv}/bin/python -m site --user-site)
        export FIREFOX=$(which firefox)
        export GECKODRIVER=$(which geckodriver)
        export BASE_URL=${cfg.baseUrl}

        cd ${cfg.podcastDir}
        python ${./podcasts/podcasts_ilpost.py} "${secrets.podcasts_fetcher_ilpost_configuration.path}"
      '';

      preStop = ''
        set -e
        # remove files older than 30 days
        find ${cfg.podcastDir} -mtime +30 -type f -delete
      '';

      startAt = "*:00/30";
    };

    sops.secrets.podcasts_fetcher_youtube_configuration = {
      mode = "0400";
      owner = config.users.users.podcasts_fetcher.name;
      group = config.users.users.podcasts_fetcher.group;
    };

    systemd.services.podcasts_youtube = {
      description = "Download the latest podcasts from YouTube";

      after = [ "network.target" ];
      serviceConfig = {
        User = config.users.users.podcasts_fetcher.name;
        Group = config.users.users.podcasts_fetcher.group;
        Type = "oneshot";

        TemporaryFileSystem = "/";
        BindPaths = [
          cfg.podcastDir
          "${config.users.users.podcasts_fetcher.home}/.cache"
        ];
        BindReadOnlyPaths = [
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/nix/store"
          secrets.podcasts_fetcher_youtube_configuration.path
        ];
      };

      path = with pkgs; [
        base_pythonEnv
        yt-dlp
      ];

      script = ''
        set -e

        export PYTHONPATH=$(${base_pythonEnv}/bin/python -m site --user-site)
        export BASE_URL=${cfg.baseUrl}

        cd ${cfg.podcastDir}
        python ${./podcasts/podcasts_youtube.py} "${secrets.podcasts_fetcher_youtube_configuration.path}"
      '';

      preStop = ''
        set -e
        # remove files older than 30 days
        find ${cfg.podcastDir} -mtime +30 -type f -delete
      '';

      startAt = "*:10/30";
    };

    sops.secrets.podcasts_fetcher_spreaker_configuration = {
      mode = "0400";
      owner = config.users.users.podcasts_fetcher.name;
      group = config.users.users.podcasts_fetcher.group;
    };

    systemd.services.podcasts_spreaker = {
      description = "Download the latest podcasts from Spreaker";

      after = [ "network.target" ];
      serviceConfig = {
        User = config.users.users.podcasts_fetcher.name;
        Group = config.users.users.podcasts_fetcher.group;
        Type = "oneshot";

        TemporaryFileSystem = "/";
        BindPaths = [ cfg.podcastDir ];
        BindReadOnlyPaths = [
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/nix/store"
          secrets.podcasts_fetcher_spreaker_configuration.path
        ];
      };

      path = with pkgs; [ base_pythonEnv ];

      script = ''
        set -e

        export PYTHONPATH=$(${base_pythonEnv}/bin/python -m site --user-site)
        export BASE_URL=${cfg.baseUrl}

        cd ${cfg.podcastDir}
        python ${./podcasts/podcasts_spreaker.py} "${secrets.podcasts_fetcher_spreaker_configuration.path}"
      '';

      preStop = ''
        set -e
        # remove files older than 30 days
        find ${cfg.podcastDir} -mtime +30 -type f -delete
      '';

      startAt = "*:15/30";
    };

    services.nginx_wrapper.enable = true;
    services.nginx.virtualHosts."${cfg.baseUrl}" = {
      enableACME = true;
      forceSSL = true;
      locations = {
        "/" = {
          root = "${cfg.podcastDir}";
          basicAuthFile = secrets.podcasts_fetcher_nginx_rss_credentials.path;
        };
      };
    };
  };
}

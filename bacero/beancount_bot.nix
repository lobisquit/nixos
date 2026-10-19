{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.beancount_bot;
  secrets = config.sops.secrets;
in
{
  options = {
    services.beancount_bot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      backupFolder = mkOption {
        type = types.str;
        default = "/var/lib/beancount_bot_backup";
      };

      backupGroup = mkOption {
        type = types.str;
        default = "miniflux_backup";
      };
    };
  };

  config = mkIf cfg.enable {
    users.groups.beancount_bot = {};
    users.users.beancount_bot = {
      isSystemUser = true;
      group = config.users.groups.beancount_bot.name;
    };

    sops.secrets.beancount_bot_environment = {
      mode = "0400";
      owner = config.users.users.beancount_bot.name;
      group = config.users.users.beancount_bot.group;
    };

    systemd.services.beancount_bot = {
      description = "Track beancount transactions via a Telegram bot";

      after = [ "network.target" ];
      wantedBy = [ "default.target" ];

      # restart limits belong to [Unit], not [Service]
      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        User = config.users.users.beancount_bot.name;
        Group = config.users.users.beancount_bot.group;
        EnvironmentFile = secrets.beancount_bot_environment.path;
        WorkingDirectory = "${./beancount_bot}";
        Restart = "always";
        RestartSec = "5s";
        PrivateTmp = true;
        InaccessiblePaths = [
          "/home"
          "/root"
          "/boot"
          "/mnt"
        ];
      };

      path = with pkgs; [
        (pkgs.python3.withPackages (ps: with ps; [
          aiogram
          asyncpg
        ]))
      ];

      script = ''
        python ${./beancount_bot}/run.py
      '';
    };


    services.postgresql = {
      enable = true;
      ensureDatabases = [ "beancount_bot" ];
      ensureUsers = [
        {
          name = "beancount_bot";
          ensureDBOwnership = true;
        }
      ];
    };

    users.groups."${cfg.backupGroup}" = {};
    systemd.tmpfiles.settings.beancount_bot = {
      "${cfg.backupFolder}".d = {
        user = config.users.users.beancount_bot.name;
        group = cfg.backupGroup;
        mode = "0755";
      };
    };
  };
}

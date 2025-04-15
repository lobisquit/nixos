{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.telegram_reminder;
  secrets = config.sops.secrets;
in

{
  options.services.telegram_reminder = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.groups.telegram_reminder = {};
    users.users.telegram_reminder = {
      createHome = false;
      isSystemUser = true;
      group = config.users.groups.telegram_reminder.name;
    };

    sops.secrets.telegram_reminder_environment = {
      mode = "0400";
      owner = config.users.users.telegram_reminder.name;
      group = config.users.users.telegram_reminder.group;
    };

    systemd.services.telegram_reminder = {
      enable = true;
      description = "Send reminders via a Telegram BOT";

      path = with pkgs; [ curl ];

      script = ''
      curl "https://api.telegram.org/bot$BOT_TOKEN/sendMessage?chat_id=$CHAT_ID&text=$TEXT" \
          2>/dev/null \
          >/dev/null
      '';

      serviceConfig = {
        User = config.users.users.telegram_reminder.name;
        EnvironmentFile = secrets.telegram_reminder_environment.path;
        Type = "oneshot";

        TemporaryFileSystem = "/";
        BindReadOnlyPaths = [
          "/dev/null"
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/nix/store"
        ];
      };

      startAt = "*-*-* 22:00:00";
    };
  };
}

{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.mensaspaziale_bot;
  secrets = config.sops.secrets;

in

{
  options.services.mensaspaziale_bot = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.groups.mensaspaziale_bot = {};
    users.users.mensaspaziale_bot = {
      group = config.users.groups.mensaspaziale_bot.name;
      createHome = false;
      isSystemUser = true;
    };

    sops.secrets.mensaspaziale_bot = {
      mode = "0400";
      owner = config.users.users.mensaspaziale_bot.name;
      group = config.users.users.mensaspaziale_bot.group;
    };

    systemd.services.mensaspaziale_bot = {
      description = "Send canteen menu every week day";

      path = [ pkgs.python3 ];

      script = "python ${./mensaspaziale_bot.py}";

      serviceConfig = {
        User = config.users.users.mensaspaziale_bot.name;
        PrivateTmp = true;
        EnvironmentFile = secrets.mensaspaziale_bot.path;
      };
      startAt = "*-*-* 07:30:00";
    };
  };
}

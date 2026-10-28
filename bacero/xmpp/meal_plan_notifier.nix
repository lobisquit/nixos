{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_meal_plan_notifier;
  secrets = config.sops.secrets;
  python = pkgs.python3.withPackages (ps: [ ps.slixmpp ps.pyyaml ]);
in
{
  options.services.xmpp_meal_plan_notifier = {
    enable = lib.mkEnableOption ''
      an evening message to an XMPP group chat with tonight's dinner and
      all of tomorrow's meals, from a weekly plan (`planFile`). The bot
      password is in the sops secret `meal_plan_notifier_configuration`;
      the format is described at the top of xmpp/meal_plan_notifier.py
    '';

    domain = lib.mkOption {
      type = lib.types.str;
      default = "lovisotto.it";
      description = "XMPP domain of the bot and of the group chat.";
    };

    jid = lib.mkOption {
      type = lib.types.str;
      default = "dieta@${cfg.domain}";
      description = "Bot account that sends the plan.";
    };

    room = lib.mkOption {
      type = lib.types.str;
      default = "piano_alimentare@conference.${cfg.domain}";
      description = "Group chat (MUC) where the plan is sent.";
    };

    nick = lib.mkOption {
      type = lib.types.str;
      default = "Piano alimentare";
      description = "Nickname shown in the group chat.";
    };

    startAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 18:30:00";
      description = "When to send the plan (systemd OnCalendar format).";
    };

    planFile = lib.mkOption {
      type = lib.types.path;
      default = ./meal_plan.yaml;
      description = ''
        Weekly plan: one entry per weekday (lunedì … domenica), each with
        colazione, pranzo, spuntino and cena.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.meal_plan_notifier_configuration = { };

    systemd.services.xmpp_meal_plan_notifier = {
      description = "Evening meal plan over XMPP";
      inherit (cfg) startAt;
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = {
        BOT_JID = cfg.jid;
        ROOM = cfg.room;
        NICK = cfg.nick;
        PLAN_FILE = "${cfg.planFile}";
        TIMEZONE = config.time.timeZone;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${python}/bin/python ${./meal_plan_notifier.py}";
        DynamicUser = true;
        LoadCredential = "configuration:${secrets.meal_plan_notifier_configuration.path}";

        ProtectHome = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
      };
    };
  };
}

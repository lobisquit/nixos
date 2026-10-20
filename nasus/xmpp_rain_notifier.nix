{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_rain_notifier;
  secrets = config.sops.secrets;
  python = pkgs.python3.withPackages (ps: [ ps.slixmpp ps.pyyaml ]);
in
{
  options.services.xmpp_rain_notifier = {
    enable = lib.mkEnableOption ''
      a morning XMPP alert when rain is expected in the given time windows.
      Position and bot password are in the sops secret
      `rain_notifier_configuration`; the format is described at the top
      of xmpp_rain_notifier.py
    '';

    jid = lib.mkOption {
      type = lib.types.str;
      default = "meteo@${config.services.xmpp_server.domain}";
      description = "Bot account that sends the alert.";
    };

    recipient = lib.mkOption {
      type = lib.types.str;
      default = "enrico@${config.services.xmpp_server.domain}";
      description = "Who receives the alert.";
    };

    startAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 08:00:00";
      description = "When to check the forecast (systemd OnCalendar format).";
    };

    windows = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "8-10" "17-19" ];
      description = "Local-time windows to check, \"start-end\" (end excluded).";
    };

    minProbability = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 50;
      description = "Precipitation probability (%) above which an hour is rainy.";
    };

    minPrecipitation = lib.mkOption {
      type = lib.types.str;
      default = "0.2";
      description = "Precipitation (mm in one hour) above which an hour is rainy.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.rain_notifier_configuration = { };

    systemd.services.xmpp_rain_notifier = {
      description = "Morning rain alert over XMPP";
      inherit (cfg) startAt;
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "prosody.service" ];

      environment = {
        BOT_JID = cfg.jid;
        RECIPIENT = cfg.recipient;
        WINDOWS = lib.concatStringsSep "," cfg.windows;
        MIN_PROBABILITY = toString cfg.minProbability;
        MIN_PRECIPITATION = cfg.minPrecipitation;
        TIMEZONE = config.time.timeZone;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${python}/bin/python ${./xmpp_rain_notifier.py}";
        DynamicUser = true;
        LoadCredential = "configuration:${secrets.rain_notifier_configuration.path}";

        ProtectHome = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
      };
    };
  };
}

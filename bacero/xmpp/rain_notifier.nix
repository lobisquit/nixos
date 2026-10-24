{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_rain_notifier;
  secrets = config.sops.secrets;
  python = pkgs.python3.withPackages (ps: [ ps.slixmpp ps.pyyaml ]);

  # Both runs share the same script, user and state directory.
  service = mode: startAt: {
    description = "Rain alert over XMPP (${mode})";
    inherit startAt;
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    environment = {
      BOT_JID = cfg.jid;
      RECIPIENTS = lib.concatStringsSep "," cfg.recipients;
      WINDOWS = lib.concatStringsSep "," cfg.windows;
      AFTERNOON_WINDOWS = lib.concatStringsSep "," cfg.afternoonWindows;
      MIN_PROBABILITY = toString cfg.minProbability;
      MIN_PRECIPITATION = cfg.minPrecipitation;
      TIMEZONE = config.time.timeZone;
    };

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${python}/bin/python ${./rain_notifier.py} ${mode}";
      DynamicUser = true;
      User = "xmpp_rain_notifier"; # same name = same UID for both units
      StateDirectory = "xmpp_rain_notifier"; # what the morning run announced
      LoadCredential = "configuration:${secrets.rain_notifier_configuration.path}";

      ProtectHome = true;
      PrivateDevices = true;
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
    };
  };
in
{
  options.services.xmpp_rain_notifier = {
    enable = lib.mkEnableOption ''
      XMPP alerts when rain is expected in the given time windows:
      one check in the morning, plus one in the afternoon that warns
      only if the forecast changed. Position and bot password are in the
      sops secret `rain_notifier_configuration`; the format is described
      at the top of xmpp/rain_notifier.py
    '';

    domain = lib.mkOption {
      type = lib.types.str;
      default = "lovisotto.it";
      description = "XMPP domain of the bot and of the default recipient.";
    };

    jid = lib.mkOption {
      type = lib.types.str;
      default = "meteo@${cfg.domain}";
      description = "Bot account that sends the alert.";
    };

    recipients = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "enrico@${cfg.domain}" ];
      example = [ "enrico@lovisotto.it" "erika@lovisotto.it" ];
      description = "Who receives the alerts.";
    };

    startAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 08:00:00";
      description = "When to run the morning check (systemd OnCalendar format).";
    };

    windows = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "8-10" "17-19" ];
      description = "Local-time windows of the morning check, \"start-end\" (end excluded).";
    };

    afternoonStartAt = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "*-*-* 15:00:00";
      description = ''
        When to run the afternoon check (systemd OnCalendar format);
        null disables it.
      '';
    };

    afternoonWindows = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "17-19" ];
      description = ''
        Windows of the afternoon check. An alert is sent only for windows
        that are rainy now but were not announced in the morning.
        Use the same names as in `windows`.
      '';
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

    systemd.services = {
      xmpp_rain_notifier = service "morning" cfg.startAt;
    } // lib.optionalAttrs (cfg.afternoonStartAt != null) {
      xmpp_rain_notifier_afternoon = service "afternoon" cfg.afternoonStartAt;
    };
  };
}

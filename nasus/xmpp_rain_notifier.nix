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
    after = [ "network-online.target" "prosody.service" ];

    environment = {
      BOT_JID = cfg.jid;
      RECIPIENTS = lib.concatStringsSep "," cfg.recipients;
      ROOMS = lib.concatStringsSep "," cfg.rooms;
      ROOM_NICK = cfg.roomNick;
      WINDOWS = lib.concatStringsSep "," cfg.windows;
      AFTERNOON_WINDOWS = lib.concatStringsSep "," cfg.afternoonWindows;
      MIN_PROBABILITY = toString cfg.minProbability;
      MIN_PRECIPITATION = cfg.minPrecipitation;
      TIMEZONE = config.time.timeZone;
    };

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${python}/bin/python ${./xmpp_rain_notifier.py} ${mode}";
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
      at the top of xmpp_rain_notifier.py
    '';

    jid = lib.mkOption {
      type = lib.types.str;
      default = "meteo@${config.services.xmpp_server.domain}";
      description = "Bot account that sends the alert.";
    };

    recipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "enrico@${config.services.xmpp_server.domain}" ];
      example = [ "enrico@lovisotto.it" "erika@lovisotto.it" ];
      description = "Who receives the alerts in a private chat.";
    };

    rooms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "famiglia@conference.lovisotto.it" ];
      description = ''
        Group chats (MUC) where the alerts are posted. In members-only
        rooms, add the bot account as a member first.
      '';
    };

    roomNick = lib.mkOption {
      type = lib.types.str;
      default = "Meteo";
      description = "Nickname of the bot in the group chats.";
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
    assertions = [
      {
        assertion = cfg.recipients != [ ] || cfg.rooms != [ ];
        message = "services.xmpp_rain_notifier: set at least one of recipients and rooms.";
      }
    ];

    sops.secrets.rain_notifier_configuration = { };

    systemd.services = {
      xmpp_rain_notifier = service "morning" cfg.startAt;
    } // lib.optionalAttrs (cfg.afternoonStartAt != null) {
      xmpp_rain_notifier_afternoon = service "afternoon" cfg.afternoonStartAt;
    };
  };
}

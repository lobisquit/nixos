{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_cinema_notifier;
  secrets = config.sops.secrets;
  python = pkgs.python3.withPackages (ps: [ ps.slixmpp ps.pyyaml ]);
in
{
  options.services.xmpp_cinema_notifier = {
    enable = lib.mkEnableOption ''
      a weekly message to an XMPP group chat with the films coming out in
      Italian cinemas (source: TMDB). The TMDB API key and the bot
      password are in the sops secret `cinema_notifier_configuration`;
      the format is described at the top of xmpp_cinema_notifier.py
    '';

    domain = lib.mkOption {
      type = lib.types.str;
      default = "lovisotto.it";
      description = "XMPP domain of the bot.";
    };

    jid = lib.mkOption {
      type = lib.types.str;
      default = "uscite_cinema@${cfg.domain}";
      description = "Bot account that sends the list.";
    };

    room = lib.mkOption {
      type = lib.types.str;
      example = "cinema@conference.lovisotto.it";
      description = "Group chat (MUC) where the list is sent.";
    };

    nick = lib.mkOption {
      type = lib.types.str;
      default = "Uscite cinema";
      description = "Nickname shown in the group chat.";
    };

    startAt = lib.mkOption {
      type = lib.types.str;
      default = "Wed *-*-* 09:00:00";
      description = "When to send the list (systemd OnCalendar format).";
    };

    days = lib.mkOption {
      type = lib.types.ints.between 1 14;
      default = 5;
      description = ''
        How many days the list covers, starting from the day it runs:
        5 from Wednesday means Wednesday to Sunday.
      '';
    };

    maxMovies = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "At most this many films, the most popular ones.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.cinema_notifier_configuration = { };

    systemd.services.xmpp_cinema_notifier = {
      description = "Weekly cinema releases over XMPP";
      inherit (cfg) startAt;
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = {
        BOT_JID = cfg.jid;
        ROOM = cfg.room;
        NICK = cfg.nick;
        DAYS = toString cfg.days;
        MAX_MOVIES = toString cfg.maxMovies;
        REGION = "IT";
        LANGUAGE = "it-IT";
        TIMEZONE = config.time.timeZone;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${python}/bin/python ${./xmpp_cinema_notifier.py}";
        DynamicUser = true;
        LoadCredential = "configuration:${secrets.cinema_notifier_configuration.path}";

        ProtectHome = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
      };
    };
  };
}

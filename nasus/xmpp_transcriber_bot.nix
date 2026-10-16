{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_transcriber_bot;
  python = pkgs.python3.withPackages (ps: [ ps.slixmpp ps.faster-whisper ]);
in
{
  options.services.xmpp_transcriber_bot = {
    enable = lib.mkEnableOption "the XMPP voice-message transcriber bot";

    jid = lib.mkOption {
      type = lib.types.str;
      default = "transcriber@${config.services.xmpp_server.domain}";
      description = "Bot account. Users of this same domain can use the bot.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "small";
      description = "faster-whisper model: tiny, base, small, medium, large-v3...";
    };

    language = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "it";
      description = "Spoken language; null = auto-detect for every message.";
    };

    initialPrompt = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Ciao, come stai? Tutto bene, grazie. Ci vediamo domani.";
      description = ''
        Short, well-punctuated sample text in the spoken language.
        Whisper imitates its style (punctuation, capitals).
        Write a normal sentence, not instructions.
      '';
    };

    cpuThreads = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = ''
        CPU cores Whisper may use for one transcription.
        0 = library default (4). Fewer cores = slower, but lighter on the PC.
      '';
    };

    modelDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/transcriber_bot";
      example = "/mnt/storage_drive/xmpp/whisper";
      description = ''
        Folder where the Whisper models are downloaded and kept.
        Created automatically, owned by the transcriber_bot user.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.transcriber_bot_password = { };

    # A fixed system user, so the model folder keeps the same owner everywhere.
    users.users.transcriber_bot = {
      isSystemUser = true;
      group = "transcriber_bot";
    };
    users.groups.transcriber_bot = { };

    systemd.tmpfiles.rules = [
      # Create the folder if missing...
      "d ${cfg.modelDir} 0750 transcriber_bot transcriber_bot - -"
      # ...and fix the owner of everything inside (files left by older runs).
      "Z ${cfg.modelDir} - transcriber_bot transcriber_bot - -"
    ];

    systemd.services.xmpp_transcriber_bot = {
      description = "XMPP transcriber bot";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "prosody.service" ];

      environment = {
        BOT_JID = cfg.jid;
        WHISPER_MODEL = cfg.model;
        WHISPER_LANGUAGE = lib.optionalString (cfg.language != null) cfg.language;
        WHISPER_PROMPT = lib.optionalString (cfg.initialPrompt != null) cfg.initialPrompt;
        WHISPER_THREADS = toString cfg.cpuThreads;
        HF_HOME = cfg.modelDir; # downloaded Whisper models live here
      };

      # Wait for the drive if modelDir is on a separate mount.
      unitConfig.RequiresMountsFor = [ cfg.modelDir ];

      serviceConfig = {
        ExecStart = "${python}/bin/python ${./xmpp_transcriber_bot.py}";
        User = "transcriber_bot";
        Group = "transcriber_bot";
        ReadWritePaths = [ cfg.modelDir ];
        LoadCredential = "password:${config.sops.secrets.transcriber_bot_password.path}";
        Restart = "always";
        RestartSec = 10;

        # Lowest priority: other services always win CPU and disk access.
        Nice = 19;
        CPUWeight = "idle";
        IOSchedulingClass = "idle";
      };
    };
  };
}

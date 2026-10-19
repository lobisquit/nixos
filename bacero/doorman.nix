{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.doorman;
  secrets = config.sops.secrets;
  storage_cfg = config.services.sftpd_storage;

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    ps.pyserial
    ps.slixmpp
    ps.aiohttp # needed by slixmpp for file uploads
  ]);

in

{
  options.services.doorman = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    ttyUSBVendorId = lib.mkOption {
      type = lib.types.str;
      default = "1a86";
    };

    ttyUSBProductId = lib.mkOption {
      type = lib.types.str;
      default = "7523";
    };

    ttyDoorman = lib.mkOption {
      type = lib.types.str;
      default = "ttyDOORMAN";
    };

    xmppJid = lib.mkOption {
      type = lib.types.str;
      default = "doorman@lovisotto.it";
      description = "XMPP account used to send the recordings.";
    };

    xmppRoom = lib.mkOption {
      type = lib.types.str;
      default = "doorman@conference.lovisotto.it";
      description = "Group chat where the recordings are sent.";
    };

    xmppNick = lib.mkOption {
      type = lib.types.str;
      default = "doorman";
      description = "Nickname shown in the group chat.";
    };
  };

  config = mkIf cfg.enable {
    services.pulseaudio.enable = true;
    services.pulseaudio.systemWide = true;

    users.groups.doorman = {};
    users.users.doorman = {
      createHome = true;
      home = "/var/lib/doorman/";
      isSystemUser = true;
      group = config.users.groups.doorman.name;
      extraGroups = [ "video" "pulse-access" "dialout" ];
    };

    sops.secrets.doorman = {
      mode = "0400";
      owner = config.users.users.doorman.name;
      group = config.users.users.doorman.group;
    };

    services.udev.extraRules = lib.concatStrings [
      ''SUBSYSTEM=="tty", ''
      ''ATTRS{idVendor}=="${cfg.ttyUSBVendorId}", ''
      ''ATTRS{idProduct}=="${cfg.ttyUSBProductId}", ''
      ''SYMLINK+="${cfg.ttyDoorman}"''
    ] + "\n" +
    lib.concatStrings [
      ''SUBSYSTEM=="tty", ''
      ''ATTRS{idVendor}=="${cfg.ttyUSBVendorId}", ''
      ''ATTRS{idProduct}=="${cfg.ttyUSBProductId}", ''
      ''ENV{SYSTEMD_WANTS}+="doorman.service"''
    ];

    systemd.services.doorman = {
      description = "Run camera when door is open";

      path = with pkgs; [
        ffmpeg
        util-linux # ionice
        pulseaudio
        alsa-utils
        pythonEnv
      ];

      script = "python ${./doorman.py}";

      # restart limits belong to [Unit], not [Service]
      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        User = config.users.users.doorman.name;
        PrivateTmp = true;
        EnvironmentFile = secrets.doorman.path;
        Environment = [
          "SERIAL_DEV=/dev/${cfg.ttyDoorman}"
          "TMP_PATH=${config.users.users.doorman.home}"
          "XMPP_JID=${cfg.xmppJid}"
          "XMPP_ROOM=${cfg.xmppRoom}"
          "XMPP_NICK=${cfg.xmppNick}"
        ];
        Restart = "always";
        RestartSec = "5s";

        # Sandbox: read-only system, writable only its home (recordings);
        # devices limited to the serial board, the camera and the sound card.
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ config.users.users.doorman.home ];
        DevicePolicy = "closed";
        DeviceAllow = [
          "char-ttyUSB rw"       # board on /dev/${cfg.ttyDoorman} (CH340)
          "char-video4linux rw"  # camera
          "char-alsa rw"         # amixer
        ];

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        # PulseAudio socket, XMPP
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
      };
    };
  };
}

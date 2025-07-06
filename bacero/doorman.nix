{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.doorman;
  secrets = config.sops.secrets;
  storage_cfg = config.services.sftpd_storage;

  pythonEnv = pkgs.python312.withPackages (ps: with ps; [
    ps.pyserial
    ps.requests
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
  };

  config = mkIf cfg.enable {
    hardware.pulseaudio.enable = true;
    hardware.pulseaudio.systemWide = true;

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
        pulseaudio
        alsa-utils
        pythonEnv
      ];

      script = "python ${./doorman.py}";

      serviceConfig = {
        User = config.users.users.doorman.name;
        PrivateTmp = true;
        EnvironmentFile = secrets.doorman.path;
        Environment = [ "SERIAL_DEV=/dev/${cfg.ttyDoorman}" ];
      };
    };
  };
}

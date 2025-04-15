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
      };

      wantedBy = [ "multi-user.target" ];
    };
  };
}

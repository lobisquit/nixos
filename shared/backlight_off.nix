{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.backlight_off;
in

{
  options.services.backlight_off = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = mkIf cfg.enable {
    systemd.timers.backlight_off = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        Unit = "backlight_off.service";
      };
    };

    systemd.services.backlight_off = {
      description = "Switches backlight off";

      script = '' brightnessctl --quiet set 0 '';
      path = with pkgs; [ brightnessctl ];

      serviceConfig = {
        Type = "oneshot";

        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        BindPaths = [ "/sys" ];
        BindReadOnlyPaths = [ "/nix/store" ];
      };
    };
  };
}

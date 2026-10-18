{ config, lib, ... }:

# One-way mirror of calendars and address books to local folders, with
# the vdirsyncer module of nixpkgs (unit vdirsyncer@cal_card).
#
# The whole vdirsyncer configuration is the sops secret
# cal_card_downloader_vdirsyncer, so that collections, folders and URLs
# are not public. It must set
#
#   [general]
#   status_path = "/var/lib/vdirsyncer/cal_card"
#
# and the local folders must be inside davDir. Missing folders are
# created by the discovery that runs before every sync.

let
  cfg = config.services.cal_card_downloader;
  secret = config.sops.secrets.cal_card_downloader_vdirsyncer;
  unit = "vdirsyncer@cal_card";
in
{
  options.services.cal_card_downloader = {
    enable = lib.mkEnableOption "the download of calendars and contacts";

    davDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/cal_card_downloader";
      description = ''
        Base folder of the downloads, the only one vdirsyncer can write to.
        Also backed up as the `cal_card` source.
      '';
    };
  };

  imports = [ ./backupper.nix ];

  config = lib.mkIf cfg.enable {
    users.groups.cal_card_downloader = { };
    users.users.cal_card_downloader = {
      isSystemUser = true;
      group = config.users.groups.cal_card_downloader.name;
    };

    sops.secrets.cal_card_downloader_vdirsyncer = {
      mode = "0400";
      owner = config.users.users.cal_card_downloader.name;
      group = config.users.users.cal_card_downloader.group;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.davDir} 0750 cal_card_downloader cal_card_downloader - -"
    ];

    services.vdirsyncer = {
      enable = true;
      jobs.cal_card = {
        user = config.users.users.cal_card_downloader.name;
        group = config.users.users.cal_card_downloader.group;
        configFile = secret.path;
        # `yes | vdirsyncer discover` before every sync: needed after a
        # change of the configuration, and creates missing local folders
        forceDiscover = true;
      };
    };

    # The module always creates a timer: sync only before the backups,
    # which pull in the unit (see runBefore below)
    systemd.timers.${unit}.enable = false;

    # Additions to the unit of the nixpkgs module
    systemd.services.${unit} = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.davDir ];
      serviceConfig = {
        # the module sets ProtectSystem=strict
        ReadWritePaths = [ cfg.davDir ];
        # new files readable by the group, hence by the backup
        UMask = "0027";
      };
    };

    # Repositories are chosen by the host
    services.backupper.sources.cal_card = {
      paths = [ cfg.davDir ];
      groups = [ config.users.groups.cal_card_downloader.name ];
      runBefore = [ "${unit}.service" ];
    };
  };
}

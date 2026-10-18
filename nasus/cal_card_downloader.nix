{ config, lib, pkgs, ... }:

# One-way mirror of calendars and address books to local folders, with
# vdirsyncer: every collection becomes a folder with one file per event
# or contact. Remote sources are read-only and a failed sync never
# touches the files already downloaded. See cal_card_downloader.py.
#
# Everything about the collections lives in the host sops file:
#
#   cal_card_downloader:
#     username: ...          # for the CalDAV/CardDAV collections
#     password: ...
#     collections: |
#       caldav<TAB>Calendario/Personale<TAB>https://...
#       carddav<TAB>Contatti/Rubrica<TAB>https://...
#       ics<TAB>Calendario/Abbonamento<TAB>https://...

let
  cfg = config.services.cal_card_downloader;
  secrets = config.sops.secrets;
  user = config.users.users.cal_card_downloader;

  secretNames = map (key: "cal_card_downloader/${key}") [ "username" "password" "collections" ];
  secretPath = key: secrets."cal_card_downloader/${key}".path;
in
{
  options.services.cal_card_downloader = {
    enable = lib.mkEnableOption "the download of calendars and contacts";

    davDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/cal_card_downloader/dav";
      description = ''
        Base folder of the downloads (the folders of the collections are
        relative to it), also backed up as the `cal_card` source.
      '';
    };

    startAt = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Also sync on a schedule; the backups pull in a sync anyway.";
    };
  };

  imports = [ ./backupper.nix ];

  config = lib.mkIf cfg.enable {
    users.groups.cal_card_downloader = { };
    users.users.cal_card_downloader = {
      createHome = true;
      home = "/var/lib/cal_card_downloader/";
      isSystemUser = true;
      group = config.users.groups.cal_card_downloader.name;
    };

    sops.secrets = lib.genAttrs secretNames (_: {
      mode = "0400";
      owner = user.name;
      group = user.group;
    });

    systemd.tmpfiles.rules = [
      "d ${cfg.davDir} 0750 cal_card_downloader cal_card_downloader - -"
    ];

    # Repositories are chosen by the host
    services.backupper.sources.cal_card = {
      paths = [ cfg.davDir ];
      groups = [ config.users.groups.cal_card_downloader.name ];
      runBefore = [ "cal_card_downloader.service" ];
    };

    systemd.services.cal_card_downloader = {
      description = "Sync DAV calendars and contacts to local folders";

      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.davDir ];
      startAt = lib.optional (cfg.startAt != null) cfg.startAt;

      environment = {
        DAV_DIR = cfg.davDir;
        STATE_DIR = user.home;
        COLLECTIONS_FILE = secretPath "collections";
        USERNAME_FILE = secretPath "username";
        PASSWORD_FILE = secretPath "password";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        PYTHONUNBUFFERED = "1"; # keep the log lines in order
      };

      path = [ pkgs.vdirsyncer ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${./cal_card_downloader.py}";
        User = user.name;
        Group = user.group;
        # new files readable by the group, hence by the backup
        UMask = "0027";

        TemporaryFileSystem = "/:ro";
        PrivateTmp = true;
        BindPaths = [ user.home cfg.davDir ];
        BindReadOnlyPaths = [
          "/nix/store"
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
        ] ++ map (name: secrets.${name}.path) secretNames;

        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}

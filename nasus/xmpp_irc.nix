{ config, lib, pkgs, ... }:
let
  cfg  = config.services.xmpp_irc;
  xcfg = config.services.xmpp_server;
  jid  = "irc.${xcfg.domain}";
  # DynamicUser: the real state directory is under /var/lib/private
  stateDir = "/var/lib/private/biboumi";
in
{
  imports = [ ./backupper.nix ];

  options.services.xmpp_irc = {
    enable = lib.mkEnableOption "Biboumi IRC gateway";

    backupFolder = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/biboumi_backup";
      description = "Where a consistent copy of the biboumi database is written before each backup.";
    };

    backupGroup = lib.mkOption {
      type = lib.types.str;
      default = "biboumi_backup";
      description = "Group that can read the copy (backupper joins it).";
    };
  };

  config = lib.mkIf cfg.enable {
    # One secret, used in two formats
    sops.secrets.biboumi_secret.owner = "prosody";
    sops.templates."biboumi-credentials".content = ''
      password=${config.sops.placeholder.biboumi_secret}
    '';

    services.biboumi = {
      enable = true;
      credentialsFile = config.sops.templates."biboumi-credentials".path;
      settings = {
        password = null; # real value comes from credentialsFile
        hostname = jid;
        xmpp_server_ip = "127.0.0.1";
        port = 5347;
        admin = xcfg.admins;
        identd_port = 0; # no identd (we won't forward 113)
        realname_customization = true;
        persistent_by_default = true;
      };
    };

    services.prosody.extraConfig = ''
      Component "${jid}"
        component_secret = FileLine("${config.sops.secrets.biboumi_secret.path}")
    '';

    # Fix thanks to
    # https://github.com/NixOS/nixpkgs/issues/493443#issuecomment-3955771427
    systemd.services.biboumi.serviceConfig = {
      RootDirectoryStartOnly = lib.mkForce false;
      RootDirectory = lib.mkForce "";
      BindPaths = lib.mkForce [];
      BindReadOnlyPaths = lib.mkForce [];
    };

    systemd.services.biboumi = {
      after = [ "prosody.service" ];
      wants = [ "prosody.service" ];
    };

    # The database holds the per-user settings set with ad-hoc commands
    # (persistent channels, nicknames, SASL passwords...). It belongs to
    # the dynamic user of biboumi and is readable only by root, so a
    # oneshot unit copies it where backupper can read it.
    users.groups.${cfg.backupGroup} = { };
    # Readable only by root and by the backup group; the setgid bit makes
    # new files belong to the backup group.
    systemd.tmpfiles.settings.biboumi_backup = {
      "${cfg.backupFolder}".d = {
        user = "root";
        group = cfg.backupGroup;
        mode = "2750";
      };
    };

    systemd.services.biboumi_backup_db = {
      description = "Consistent copy of the biboumi database for the backups";
      # restore: stop biboumi, copy the file to ${stateDir}/biboumi.sqlite, start biboumi

      path = [ pkgs.sqlite ];
      serviceConfig = {
        Type = "oneshot";
        UMask = "0027";

        # Only the state of biboumi and the backup folder are visible.
        # The state is writable because SQLite may have to roll back a
        # journal left by a crash before it can read the database.
        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        PrivateTmp = true;
        BindPaths = [ stateDir cfg.backupFolder ];
        BindReadOnlyPaths = [ "/nix/store" ];
      };

      # .backup is safe while biboumi runs. Write to a temporary file and
      # rename it only on success, so a failed copy never replaces the
      # previous good one.
      script = ''
        target="${cfg.backupFolder}/biboumi.sqlite"
        tmp=$(mktemp "$target.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        sqlite3 "${stateDir}/biboumi.sqlite" ".backup '$tmp'"
        chmod 0640 "$tmp"
        mv -f "$tmp" "$target"
        trap - EXIT
      '';
    };

    # Repositories are chosen by the host.
    services.backupper.sources.biboumi = {
      paths = [ cfg.backupFolder ];
      groups = [ cfg.backupGroup ];
      runBefore = [ "biboumi_backup_db.service" ];
    };
  };
}

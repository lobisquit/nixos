{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.miniflux_wrapper;
  secrets = config.sops.secrets;
in

{
  imports = [ ./nginx_wrapper.nix ./backupper.nix ];

  options.services.miniflux_wrapper = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    baseUrl = mkOption {
      type = types.str;
      default = "news.lovisotto.it";
    };

    internalPort = mkOption {
      type = types.int;
      default = 8036;
    };

    backupFolder = mkOption {
      type = types.str;
      default = "/var/lib/miniflux_backup";
    };

    backupGroup = mkOption {
      type = types.str;
      default = "miniflux_backup";
    };
  };

  config = mkIf cfg.enable {

    users.groups.miniflux = {};
    users.users.miniflux = {
      createHome = false;
      isSystemUser = true;
      group = config.users.groups.miniflux.name;
    };

    sops.secrets.miniflux_admin_credentials = {
      mode = "0400";
      owner = config.users.users.miniflux.name;
      group = config.users.users.miniflux.group;
    };

    services.miniflux = {
      enable = true;
      config = {
        LISTEN_ADDR = "127.0.0.1:" + toString cfg.internalPort;
        BASE_URL = "https://" + cfg.baseUrl;
        CLEANUP_REMOVE_SESSIONS_DAYS = "180";
      };
      adminCredentialsFile = secrets.miniflux_admin_credentials.path;
    };

    services.nginx_wrapper.enable = true;
    services.nginx.virtualHosts."${cfg.baseUrl}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.internalPort}";
        proxyWebsockets = true;
        extraConfig = "proxy_ssl_server_name on;";
      };
    };

    users.groups."${cfg.backupGroup}" = {};
    # Readable only by miniflux and by the backup group. The setgid bit
    # makes new files belong to the backup group, so that backupper can
    # read them without them being world-readable.
    systemd.tmpfiles.settings.miniflux = {
      "${cfg.backupFolder}".d = {
        user = config.users.users.miniflux.name;
        group = cfg.backupGroup;
        mode = "2750";
      };
    };

    systemd.services.miniflux_backup_admin_opml = {
      description = "Backup the OPML for the admin user of miniflux";
      # and restore with psql -d miniflux < postgres_miniflux.sql

      serviceConfig = {
        Type = "oneshot";
        User = config.users.users.miniflux.name;
        Group = config.users.users.miniflux.group;
        # new files: rw for the owner, r for the (backup) group, nothing for others
        UMask = "0027";
        EnvironmentFile = secrets.miniflux_admin_credentials.path;
        Environment = ''DATABASE_URL="${config.services.miniflux.config.DATABASE_URL}"'';

        TemporaryFileSystem = "/";
        PrivateNetwork = true;
        PrivateTmp = true;
        BindPaths = [
          cfg.backupFolder
        ];
        BindReadOnlyPaths = [
          "/nix/store"
          "/run/postgresql"
          "/etc/passwd"
        ];
      };

      path = with pkgs; [
        miniflux
        postgresql
      ];
      # Write to a temporary file and rename it only on success: a failed
      # export never truncates the previous good copy, and the new file
      # always gets the permissions above, even if an old one exists.
      script = ''
          dir="${cfg.backupFolder}"

          save() {
              local target="$dir/$1"; shift
              tmp=$(mktemp "$target.XXXXXX")
              trap 'rm -f "$tmp"' EXIT
              "$@" > "$tmp"
              chmod 0640 "$tmp"
              mv -f "$tmp" "$target"
              trap - EXIT
          }

          save "$ADMIN_USERNAME.opml" miniflux -export-user-feeds "$ADMIN_USERNAME"
          save postgres_miniflux.sql pg_dump miniflux
      '';
    };

    # The full database, for a complete restore, and the OPML list of
    # feeds, for easy imports into other apps. Repositories are chosen
    # by the host.
    services.backupper.sources.miniflux = {
      paths = [ cfg.backupFolder ];
      groups = [ cfg.backupGroup ];
      runBefore = [ "miniflux_backup_admin_opml.service" ];
    };
  };
}

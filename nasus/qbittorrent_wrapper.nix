{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.qbittorrent_wrapper;
  samba_cfg = config.services.samba_wrapper;
  secrets = config.sops.secrets;
  qb_user = config.services.qbittorrent.user;
  qb_group = config.services.qbittorrent.group;
  qb_conf = "${config.services.qbittorrent.profileDir}/qBittorrent/config/qBittorrent.conf";
  blocklist = "${cfg.home}/blocklist.p2p";

  # The upstream module copies the generated qBittorrent.conf (without the
  # password) in its own ExecStartPre; this one runs right after it and adds
  # the PBKDF2 hash from sops, so the hash never lands in the Nix store.
  inject_password = pkgs.writeShellScript "qbittorrent-inject-password" ''
    set -eu
    secret=${secrets.qbittorrent_password_pbkdf2.path}
    conf=${qb_conf}

    if [ ! -s "$secret" ]; then
      echo "Missing or empty qBittorrent password secret" >&2
      exit 1
    fi

    # awk reads the hash from the file, so no shell or sed escaping applies
    ${pkgs.gawk}/bin/awk '
      NR == FNR { pw = $0; next }
      { print }
      /^\[Preferences\]$/ { print "WebUI\\Password_PBKDF2=\"" pw "\"" }
    ' "$secret" "$conf" > "$conf.tmp"

    if ! ${pkgs.gnugrep}/bin/grep -q '^WebUI\\Password_PBKDF2=' "$conf.tmp"; then
      echo "No [Preferences] section in $conf, password not set" >&2
      rm -f "$conf.tmp"
      exit 1
    fi

    chmod 600 "$conf.tmp"
    mv "$conf.tmp" "$conf"
  '';
in
{
  imports =
    [
      ./samba_wrapper.nix
      ./nginx_wrapper.nix
    ];

  options = {
    services.qbittorrent_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      internalPort = mkOption {
        type = types.port;
        default = 8035;
      };

      peerPort = mkOption {
        type = types.port;
        # same as Transmission, so the router port forward stays valid
        default = 51413;
      };

      fqdn = mkOption {
        type = types.str;
        default = "torrent.domain";
      };

      home = mkOption {
        type = types.path;
        default = "/mnt/storage_drive/torrent";
      };

      webuiUsername = mkOption {
        type = types.str;
        default = "admin";
        description = ''
          Web UI user name. The password hash comes from the
          qbittorrent_password_pbkdf2 sops secret.
        '';
      };

      allowedNetworks = mkOption {
        type = types.nonEmptyListOf types.str;
        example = [ "10.1.0.0/16" "10.3.0.0/16" ];
        description = ''
          Networks (CIDR) allowed to reach the web interface through nginx;
          every other client gets 403. qBittorrent itself listens only on
          localhost, so nginx is the only way in.
        '';
      };

      blocklistUrl = mkOption {
        type = types.str;
        default = "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz";
        description = "Gzipped blocklist in P2P format, refreshed weekly.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Content: the bare value generated for the password, i.e.
    # @ByteArray(<salt base64>:<key base64>), on a single line.
    sops.secrets.qbittorrent_password_pbkdf2 = {
      mode = "0400";
      owner = qb_user;
      group = qb_group;
      restartUnits = [ "qbittorrent.service" ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.home} 0750 ${qb_user} ${qb_group} -"
      "d ${cfg.home}/Downloads 0750 ${qb_user} ${qb_group} -"
      "d ${cfg.home}/Others 0750 ${qb_user} ${qb_group} -"
      "d ${config.services.qbittorrent.profileDir} 0750 ${qb_user} ${qb_group} -"
    ];

    services.qbittorrent = {
      enable = true;
      profileDir = "${cfg.home}/.qbittorrent";
      webuiPort = cfg.internalPort;
      torrentingPort = cfg.peerPort;
      # would also open the Web UI port: peer ports are opened below
      openFirewall = false;

      serverConfig = {
        LegalNotice.Accepted = true;

        BitTorrent.Session = {
          DefaultSavePath = "${cfg.home}/Downloads";
          TempPathEnabled = false;

          IPFilteringEnabled = true;
          IPFilter = blocklist;

          GlobalMaxRatio = 3;
          ShareLimitAction = "Stop";
        };

        Preferences = {
          General.Locale = "it";

          WebUI = {
            Address = "127.0.0.1";
            Username = cfg.webuiUsername;
            # Password_PBKDF2 is added at start-up by inject_password

            # nginx connects from localhost: localhost must not skip login
            LocalHostAuth = true;
            AuthSubnetWhitelistEnabled = false;

            # reject requests for other host names (DNS rebinding)
            HostHeaderValidation = true;
            ServerDomains = cfg.fqdn;
            CSRFProtection = true;
            ClickjackingProtection = true;

            # real client address from nginx, used for the login ban
            ReverseProxySupportEnabled = true;
            TrustedReverseProxiesList = "127.0.0.1";
            MaxAuthenticationFailCount = 5;
            BanDuration = 3600;

            HTTPS.Enabled = false;
            UseUPnP = false;
          };
        };
      };
    };

    systemd.services.qbittorrent.serviceConfig.ExecStartPre =
      mkAfter [ "${inject_password}" ];

    networking.firewall = {
      allowedTCPPorts = [ cfg.peerPort ];
      allowedUDPPorts = [ cfg.peerPort ];
    };

    # qBittorrent cannot download the blocklist by itself
    systemd.services.qbittorrent-blocklist = {
      description = "Refresh the qBittorrent IP blocklist";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      path = with pkgs; [ curl gzip coreutils ];

      script = ''
        set -eu
        tmp=$(mktemp ${cfg.home}/.blocklist.XXXXXX)
        trap 'rm -f "$tmp"' EXIT
        curl -fsSL --retry 3 ${escapeShellArg cfg.blocklistUrl} | gunzip > "$tmp"
        # never replace a working list with an empty one
        [ -s "$tmp" ]
        chmod 640 "$tmp"
        mv "$tmp" ${blocklist}
      '';

      serviceConfig = {
        Type = "oneshot";
        User = qb_user;
        Group = qb_group;
        # qBittorrent reads the list only at start-up; "+" runs it as root
        ExecStartPost = "+${pkgs.systemd}/bin/systemctl try-restart qbittorrent.service";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.home ];
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.qbittorrent-blocklist = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    users = mkIf samba_cfg.enable {
      groups.samba_enrico = { };
      users.samba_enrico = {
        isSystemUser = true;
        group = "samba_enrico";
        home = "/var/empty";
        createHome = false;
        shell = pkgs.shadow;
      };

      groups.samba_erika = { };
      users.samba_erika = {
        isSystemUser = true;
        group = "samba_erika";
        home = "/var/empty";
        createHome = false;
        shell = pkgs.shadow;
      };
    };

    sops.secrets.smbpasswd = mkIf samba_cfg.enable { };

    systemd.services.samba_setup_users = mkIf samba_cfg.enable {
      description = "Set user passwords with smbpasswd";

      after = [ "samba.target" ];
      wantedBy = [ "multi-user.target" ];

      path = with pkgs; [ samba ];

      # The secret has one "username password" line per user; the password
      # is the rest of the line, so it may contain spaces, "*" or "\".
      # Samba users that are no longer in the secret are removed.
      script = ''
        set -eu

        declare -A wanted=()
        # "|| [ -n ... ]": also the last line when it has no final newline
        while read -r username password || [ -n "''${username:-}" ]; do
          # skip empty lines and comments
          [ -n "$username" ] && [ "''${username:0:1}" != "#" ] || continue
          wanted[$username]=1
          printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a "$username"
        done < ${secrets.smbpasswd.path}

        # never wipe all the users because of an empty or broken secret
        if [ "''${#wanted[@]}" -eq 0 ]; then
          echo "No users in the secret: existing Samba users left untouched" >&2
          exit 1
        fi

        for existing in $(pdbedit -L | cut -d: -f1); do
          if [ -z "''${wanted[$existing]:-}" ]; then
            echo "Removing Samba user $existing, not in the secret"
            # pdbedit, unlike smbpasswd -x, also removes entries whose Unix
            # account no longer exists; a failure here is only a warning
            pdbedit -x -u "$existing" \
              || echo "Warning: could not remove Samba user $existing" >&2
          fi
        done
        '';

      serviceConfig = {
        PrivateNetwork = true;
        TemporaryFileSystem = "/";
        BindPaths = [
          "/var/lib/samba"
          "/var/lock/samba"
        ];
        BindReadOnlyPaths = [
          "/etc/passwd"
          "/etc/samba/smb.conf"
          "/nix/store"
          secrets.smbpasswd.path
        ];
      };
    };

    services.nginx_wrapper.enable = true;
    services.nginx.virtualHosts."${cfg.fqdn}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.internalPort}";
        extraConfig = concatMapStrings (net: "allow ${net};\n") cfg.allowedNetworks + ''
          deny all;
          # .torrent files uploaded from the Web UI or Transdroid
          client_max_body_size 50m;
        '';
      };
    };

    sops.secrets.desec_token = {
      mode = "0400";
      owner = "acme";
      group = "acme";
    };

    security.acme.certs = {
      "${cfg.fqdn}" = {
        domain = cfg.fqdn;
        group = "nginx";
        dnsProvider = "desec";
        dnsResolver = "ns1.desec.io:53";
        environmentFile = secrets.desec_token.path;
        server = "https://acme-v02.api.letsencrypt.org/directory";
        webroot = null;
      };
    };

    services.samba.settings = mkIf samba_cfg.enable {
      downloads = mkIf samba_cfg.enable {
        path = "${cfg.home}/Downloads";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "force user" = qb_user;
        "force group" = qb_group;
        "write list" = qb_user;
        "valid users" = "samba_enrico samba_erika";
      };

      others = mkIf samba_cfg.enable {
        path = "${cfg.home}/Others";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "force user" = qb_user;
        "force group" = qb_group;
        "write list" = qb_user;
        "valid users" = "samba_enrico";
      };
    };
  };
}

{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.transmission_wrapper;
  samba_cfg = config.services.samba_wrapper;
  secrets = config.sops.secrets;
  user_conf = config.users.users.transmission;
  tr_user = config.services.transmission.user;
  tr_group = config.services.transmission.group;
in
{
  imports =
    [
      ./samba_wrapper.nix
      ./nginx_wrapper.nix
    ];

  options = {
    services.transmission_wrapper = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      internalPort = mkOption {
        type = types.int;
        default = 8035;
      };

      fqdn = mkOption {
        type = types.str;
        default = "transmission.domain";
      };

      home = mkOption {
        type = types.path;
        default = "/mnt/storage_drive/transmission";
      };

      allowedNetworks = mkOption {
        type = types.nonEmptyListOf types.str;
        example = [ "10.1.0.0/16" "10.3.0.0/16" ];
        description = ''
          Networks (CIDR) allowed to reach the web interface through nginx;
          every other client gets 403. Transmission itself listens only on
          localhost, so nginx is the only way in.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    sops.secrets.transmission_credentials = {
      mode = "0400";
      owner = config.services.transmission.user;
      group = config.services.transmission.group;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.home} 0750 ${tr_user} ${tr_group} -"
      "d ${cfg.home}/.config/transmission-daemon 0750 ${tr_user} ${tr_group} -"
      "d ${cfg.home}/Downloads 0750 ${tr_user} ${tr_group} -"
      "d ${cfg.home}/Others 0750 ${tr_user} ${tr_group} -"
    ];

    services.transmission = {
      enable = true;
      # RPC reachable only through nginx (TLS + network filter)
      openRPCPort = false;
      credentialsFile = secrets.transmission_credentials.path;
      openPeerPorts = true;
      home = cfg.home;
      package = pkgs.transmission_4;
      settings = {
        incomplete-dir-enabled = false;
        rpc-bind-address = "127.0.0.1";
        rpc-whitelist-enabled = true;
        rpc-whitelist = "127.0.0.1";
        # reject requests for other host names (DNS rebinding)
        rpc-host-whitelist-enabled = true;
        rpc-host-whitelist = cfg.fqdn;
        # username and password come from credentialsFile
        rpc-authentication-required = true;
        blocklist-enabled = true;
        rpc-port = cfg.internalPort;
        blocklist-url = "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz";
        ratio-limit-enabled = true;
        ratio-limit = 3.0;
      };
    };

    systemd.services.transmission.serviceConfig.BindPaths = [
       "${cfg.home}/Others"
    ];

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
        "force user" = "transmission";
        "force group" = "transmission";
        "write list" = "transmission";
        "valid users" = "samba_enrico samba_erika";
      };

      others = mkIf samba_cfg.enable {
        path = "${cfg.home}/Others";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "force user" = "transmission";
        "force group" = "transmission";
        "write list" = "transmission";
        "valid users" = "samba_enrico";
      };
    };
  };
}

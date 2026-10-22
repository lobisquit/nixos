{ config, lib, pkgs, ... }:

with lib;

# Self-hosted git repositories, browsable with cgit and reachable only
# from the LAN and the VPN.
#
# - Web and HTTPS clones (read only): https://<fqdn>/<repo>.git
# - Push and clone over SSH, as the `git` user (git-shell only):
#     git@<fqdn>:<repo>.git
#
# A new repository is created on the server with
#   ssh root_bacero 'sudo -u git git init --bare /var/lib/git/<repo>.git'
# and the text in <repo>.git/description is shown in the index.

let
  cfg = config.services.cgit_wrapper;
  secrets = config.sops.secrets;
in
{
  imports = [ ./nginx_wrapper.nix ./backupper.nix ];

  options.services.cgit_wrapper = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };

    fqdn = mkOption {
      type = types.str;
      default = "git.lovisotto.it";
    };

    reposDir = mkOption {
      type = types.str;
      default = "/var/lib/git";
    };

    allowedNetworks = mkOption {
      type = types.listOf types.str;
      default = [ "10.1.0.0/16" "10.3.0.0/16" ];
      description = "Networks allowed to reach the web interface (LAN and VPN).";
    };

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "SSH public keys allowed to push, as the git user.";
    };
  };

  config = mkIf cfg.enable {

    # Owner of the repositories: push happens as this user, through SSH,
    # and git-shell allows nothing but git commands.
    users.groups.git = { };
    users.users.git = {
      isSystemUser = true;
      group = config.users.groups.git.name;
      home = cfg.reposDir;
      createHome = false;
      shell = "${pkgs.git}/bin/git-shell";
      # no port, agent or X11 forwarding, no pty
      openssh.authorizedKeys.keys = map (key: "restrict ${key}") cfg.authorizedKeys;
    };
    services.openssh.settings.AllowUsers = [ config.users.users.git.name ];

    # Readable by the git group (cgit and backupper), nothing for others.
    # The setgid bit makes new repositories belong to the git group.
    systemd.tmpfiles.settings.cgit_wrapper = {
      "${cfg.reposDir}".d = {
        user = config.users.users.git.name;
        group = config.users.groups.git.name;
        mode = "2750";
      };
    };

    # cgit and git-http-backend run as the cgit user, which can only read
    # the repositories: git refuses repositories owned by someone else
    # unless they are marked as safe.
    users.users.cgit.extraGroups = [ config.users.groups.git.name ];
    programs.git = {
      enable = true;
      config.safe.directory = "${cfg.reposDir}/*";
    };

    services.cgit."${cfg.fqdn}" = {
      enable = true;
      scanPath = cfg.reposDir;
      # HTTPS clones go to git-http-backend, read only (no push over HTTP)
      gitHttpBackend = {
        enable = true;
        checkExportOkFiles = false;
      };
      settings = {
        root-title = cfg.fqdn;
        root-desc = "Repository di casa";
        clone-url = "https://${cfg.fqdn}/$CGIT_REPO_URL git@${cfg.fqdn}:$CGIT_REPO_URL";
        enable-index-owner = 0;
        enable-commit-graph = 1;
        enable-log-filecount = 1;
        enable-log-linecount = 1;
        branch-sort = "age";
        snapshots = "tar.gz zip";
        # README of the default branch in the "about" tab
        readme = [ ":README.md" ":README" ];
        about-filter = "${config.services.cgit."${cfg.fqdn}".package}/lib/cgit/filters/about-formatting.sh";
        source-filter = "${config.services.cgit."${cfg.fqdn}".package}/lib/cgit/filters/syntax-highlighting.py";
      };
    };

    services.nginx_wrapper.enable = true;
    services.nginx.virtualHosts."${cfg.fqdn}" = {
      enableACME = true;
      forceSSL = true;
      # at server level, so it applies to every location defined by cgit
      extraConfig = concatMapStrings (net: "allow ${net};\n") cfg.allowedNetworks + ''
        deny all;
      '';
    };

    # The name is not reachable from the Internet, so the certificate is
    # obtained with the DNS challenge.
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

    # Repositories are chosen by the host.
    services.backupper.sources.git = {
      paths = [ cfg.reposDir ];
      groups = [ config.users.groups.git.name ];
    };
  };
}

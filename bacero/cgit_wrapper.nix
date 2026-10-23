{ config, lib, pkgs, ... }:

with lib;

# Self-hosted git repositories, browsable with cgit and reachable only
# from the LAN and the VPN.
#
# - Web and HTTPS clones (read only): https://<fqdn>/<repo>.git
# - Push and clone over SSH, as the `git` user (git-shell only):
#     git@<fqdn>:<repo>.git
#
# Repositories are managed with the commands of the git user:
#   ssh git@<fqdn> new <repo> [description]
#   ssh git@<fqdn> desc <repo> <description>
#   ssh git@<fqdn> list
#   ssh git@<fqdn> help
# (or just `ssh git@<fqdn>` for an interactive git-shell with them).

let
  cfg = config.services.cgit_wrapper;
  secrets = config.sops.secrets;

  # Commands available in git-shell, from the git-shell-commands folder
  # in the home of the git user. Names allowed: letters, digits, . _ -
  shellCommand = name: text: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = with pkgs; [ git coreutils ];
    text = ''
      repos="${cfg.reposDir}"

      repo_dir() {
        local name="''${1%.git}"
        if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
          echo "invalid name: '$1'" >&2
          exit 1
        fi
        echo "$repos/$name.git"
      }

    '' + text;
  };

  # cgit has no mobile layout: on small screens wide tables scroll on
  # their own instead of the whole page, commit messages and diffs wrap,
  # and the header loses the logo and the search forms.
  mobileHead = pkgs.writeText "cgit-head.html" ''
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      @media (max-width: 720px) {
        div#cgit { margin: 0; padding: 0 6px; }
        table#header td.logo,
        table#header td.form,
        table.tabs td.form { display: none; }
        table#header td.main { font-size: 160%; }
        table.tabs td { white-space: normal; }
        table.tabs td a { display: inline-block; padding: 4px 6px; }
        table.list, table.diffstat, table.blob, table.diff,
        table#downloads, div#summary {
          display: block;
          max-width: 100%;
          overflow-x: auto;
        }
        div.commit-subject, div.commit-msg, table.list td.logmsg,
        table.diff td div { white-space: pre-wrap; overflow-wrap: anywhere; }
        div.path { overflow-wrap: anywhere; }
      }
    </style>
  '';

  shellCommands = pkgs.linkFarm "git-shell-commands" (map
    (cmd: { name = cmd.name; path = "${cmd}/bin/${cmd.name}"; })
    [
      (shellCommand "new" ''
        if [ $# -lt 1 ]; then
          echo "usage: new <repo> [description]" >&2
          exit 1
        fi
        dir=$(repo_dir "$1"); shift
        if [ -e "$dir" ]; then
          echo "$(basename "$dir") already exists" >&2
          exit 1
        fi
        git init --quiet --bare --initial-branch=main "$dir"
        if [ $# -gt 0 ]; then
          echo "$*" > "$dir/description"
        fi
        name=$(basename "$dir")
        echo "created $name"
        echo "  git remote add origin git@${cfg.fqdn}:$name"
        echo "  git clone git@${cfg.fqdn}:$name"
      '')

      (shellCommand "desc" ''
        if [ $# -lt 2 ]; then
          echo "usage: desc <repo> <description>" >&2
          exit 1
        fi
        dir=$(repo_dir "$1"); shift
        if [ ! -d "$dir" ]; then
          echo "$(basename "$dir") does not exist" >&2
          exit 1
        fi
        echo "$*" > "$dir/description"
      '')

      (shellCommand "list" ''
        shopt -s nullglob
        for dir in "$repos"/*.git; do
          printf '%-30s %s\n' "$(basename "$dir")" "$(head -n1 "$dir/description" 2>/dev/null)"
        done
      '')

      # no shellCommand: shellcheck would fail on the unused $repos
      (pkgs.writeShellScriptBin "help" ''
        echo "new <repo> [description]   create an empty repository"
        echo "desc <repo> <description>  change the description shown by cgit"
        echo "list                       list the repositories"
      '')
    ]);
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
      default = "/mnt/storage_drive/git";
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
      # no port, agent or X11 forwarding; the pty is for the
      # interactive git-shell
      openssh.authorizedKeys.keys = map (key: "restrict,pty ${key}") cfg.authorizedKeys;
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
      "${cfg.reposDir}/git-shell-commands"."L+" = {
        argument = "${shellCommands}";
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
        # usable on phones, on top of the default cgit.css
        head-include = "${mobileHead}";
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

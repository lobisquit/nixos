{ inputs, lib, config, pkgs, ... }:

{
  nixpkgs = {
    overlays = [
    ];
    config = {
      allowUnfree = true;
      allowUnfreePredicate = _: true;
    };
  };

  systemd.user.startServices = "sd-switch";

  home = {
    stateVersion = "24.05";

    username = "enrico";
    homeDirectory = "/home/enrico";

    packages = with pkgs; [
      libreoffice
      gnumake
      audacious
      sops
      popcorntime
      unison
      kicad-small
      nmon
      tor-browser
      vlc
      freecad
      blender
      openscad
      prusa-slicer
      isort
      age
    ];
  };

  programs = {
    git = {
      enable = true;
      settings = {
        user = {
          name = "Enrico Lovisotto";
          email = "dev@lovisotto.it";
        };
        init.defaultBranch = "main";
      };

      signing.format = null;
    };

    home-manager.enable = true;

    tmux = {
      enable = true;
      prefix = "C-a";
      mouse = true;
      extraConfig = ''
          bind I split-window -h
          bind - split-window -v
          unbind '"'
          unbind %
      '';
    };

    firefox.enable = true;
    emacs.enable = true;
    alacritty.enable = true;
    htop.enable = true;

    bash = {
      enable = true;
      enableCompletion = true;
      historyFile = "$HOME/.cache/.bash_history";
      bashrcExtra = ''
      if command -v tmux &> /dev/null && \
         [ -n "$PS1" ] && \
         [[ ! "$TERM" =~ screen ]] && \
         [[ ! "$TERM" =~ tmux ]] && \
         [ -z "$TMUX" ]; then
        tmux
      fi
      '';

      sessionVariables = {
        EDITOR = "emacs";
      };

      shellAliases = {
        sync_folders = "unison -auto -perms 0 -dontchmod ~ ssh://storage_unison_nasus//mnt/storage_drive/sftp_chroot/data/ -path Documenti -path Immagini -path Video -path Musica";
        chamber = "cd ~/Progetti/fermentation-chamber/ && nix-shell";
      };
    };

    # Cannot use sops in home-manager, it seems. SSH secrets are
    # defined in networking.nix and paths are hardcoded here.

    ssh = {
      enable = true;
      enableDefaultConfig = false;

      matchBlocks = {
        "git.sr.ht" = {
          hostname = "git.sr.ht";
          user = "git";
          identityFile = "/home/enrico/.ssh/srht";
          identitiesOnly = true;
        };

        "gitlab.com" = {
          hostname = "gitlab.com";
          user = "git";
          identityFile = "/home/enrico/.ssh/gitlab";
          identitiesOnly = true;
        };

        "github.com" = {
          hostname = "github.com";
          user = "git";
          identityFile = "/home/enrico/.ssh/github";
          identitiesOnly = true;
        };

        root_nasus = {
          hostname = "nasus.home.lovisotto.it";
          user = "root";
          identityFile = "/run/secrets/ssh_self_key";
          port = 2222;
          identitiesOnly = true;
          extraOptions = {
            CertificateFile = "/run/secrets/ssh_self_cert";
          };
        };

        storage_unison_nasus = {
          hostname = "nasus.home.lovisotto.it";
          user = "storage_unison";
          identityFile = "/run/secrets/ssh_self_key";
          port = 2222;
          identitiesOnly = true;
          extraOptions = {
            CertificateFile = "/run/secrets/ssh_self_cert";
          };
        };

        storage_nasus = {
          hostname = "nasus.home.lovisotto.it";
          user = "storage";
          identityFile = "/run/secrets/ssh_self_key";
          port = 2222;
          identitiesOnly = true;
          extraOptions = {
            CertificateFile = "/run/secrets/ssh_self_cert";
          };
        };

        root_minipc = {
          hostname = "10.63.16.102";
          user = "root";
          identityFile = "/home/enrico/.ssh/minipc";
          port = 22;
          identitiesOnly = true;
        };

        root_router = {
          hostname = "home.lovisotto.it";
          user = "root";
          identityFile = "/home/enrico/.ssh/router";
          identitiesOnly = true;
        };

        root_octoprint = {
          hostname = "octoprint.home.lovisotto.it";
          user = "root";
          identityFile = "/run/secrets/ssh_self_key";
          identitiesOnly = true;
          extraOptions = {
            CertificateFile = "/run/secrets/ssh_self_cert";
          };
        };

        root_bacero = {
          hostname = "bacero.home.lovisotto.it";
          user = "root";
          identityFile = "/run/secrets/ssh_self_key";
          identitiesOnly = true;
          extraOptions = {
            CertificateFile = "/run/secrets/ssh_self_cert";
          };
        };
      };
    };
  };
}

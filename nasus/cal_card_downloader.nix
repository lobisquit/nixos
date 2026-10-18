{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.cal_card_downloader;
  secrets = config.sops.secrets;
in
{
  options = {
    services.cal_card_downloader = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      davDir = mkOption {
        type = types.path;
        default = "/var/lib/cal_card_downloader/dav";
        description = ''
          Folder where calendars and contacts are downloaded (local paths
          in the configuration secret are relative to it), also backed up
          as the `cal_card` source.
        '';
      };
    };
  };

  imports = [ ./backupper.nix ];

  config = mkIf cfg.enable {
    users.groups.cal_card_downloader = {};
    users.users.cal_card_downloader = {
      createHome = true;
      home = "/var/lib/cal_card_downloader/";
      isSystemUser = true;
      group = config.users.groups.cal_card_downloader.name;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.davDir} 0750 cal_card_downloader cal_card_downloader - -"
      # fix the owner of files moved here from elsewhere
      "Z ${cfg.davDir} - cal_card_downloader cal_card_downloader - -"
    ];

    # Repositories are chosen by the host
    services.backupper.sources.cal_card = {
      paths = [ cfg.davDir ];
      groups = [ config.users.groups.cal_card_downloader.name ];
      runBefore = [ "cal_card_downloader.service" ];
    };

    sops.secrets.cal_card_downloader_credentials = {
      mode = "0400";
      owner = config.users.users.cal_card_downloader.name;
      group = config.users.users.cal_card_downloader.group;
    };

    sops.secrets.cal_card_downloader_configuration = {
      mode = "0400";
      owner = config.users.users.cal_card_downloader.name;
      group = config.users.users.cal_card_downloader.group;
    };

    systemd.services.cal_card_downloader = {
      description = "Sync DAV calendars and contacts to local folders";

      after = [ "network.target" ];
      unitConfig.RequiresMountsFor = [ cfg.davDir ];
      serviceConfig = {
        User = config.users.users.cal_card_downloader.name;
        Group = config.users.users.cal_card_downloader.group;
        Type = "oneshot";

        TemporaryFileSystem = "/";
        BindPaths = [
          config.users.users.cal_card_downloader.home
          # the folder is dedicated to the downloads, whatever subfolders
          # the secret configuration uses
          cfg.davDir
        ];
        BindReadOnlyPaths = [
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/nix/store"
          secrets.cal_card_downloader_credentials.path
          secrets.cal_card_downloader_configuration.path
        ];
      };

      path = with pkgs; [ cadaver curl ];

      script = ''
        #!/bin/bash

        set -e

        function dav_download() {
            local_subfolder="$1"
            remote_url="$2"

            # cleanup and re-download all files since no timestamp
            # for DAV files is available anyway
            rm -rf "$local_subfolder"
            mkdir -p "$local_subfolder"

            cd "$local_subfolder"
            echo 'mget *' | cadaver "$remote_url" 2>&1 > ~/log.txt
            cat ~/log.txt

            # assign write permission to new files to the group as well
            # no matter if cadaver failed
            find . -type f -exec chmod 660 {} \;
            find . -type d -exec chmod 770 {} \;

            # Unfortunately cadaver does not propagate the error code of its commands to shell.
            # This is a workaround grepping for errors.
            cat ~/log.txt \
                | grep 'Host not found\|Could not open collection\|Unrecognised command\|Could not access' \
              && exit 1

            echo "DAV <$local_subfolder> processed successfully"
        }

        function ics_download() {
            local_path="$1"
            remote_url="$2"

            mkdir -p $(dirname "$local_path")
            rm -f "''${local_path}.ics"
            curl "$remote_url" -o "''${local_path}.ics"

            # assign write permission to the new file to the group as well
            chmod 660 "''${local_path}.ics"

            echo "ICS <$local_path> processed successfully"
        }

        rm -f $HOME/.netrc
        ln -s ${secrets.cal_card_downloader_credentials.path} $HOME/.netrc

        while IFS=$'\t' read -r -a single_conf
        do
            cd ${cfg.davDir}

            resource_type="''${single_conf[0]}"
            local_path="''${single_conf[1]}"
            remote_url="''${single_conf[2]}"

            if [ "$resource_type" == "DAV" ]
            then
                dav_download "$local_path" "$remote_url"
            elif [ "$resource_type" == "ICS" ]
            then
                ics_download "$local_path" "$remote_url"
            else
                echo "Invalid resource type: $resource_type"
                exit 1
            fi
        done < ${secrets.cal_card_downloader_configuration.path}
      '';
    };
  };
}

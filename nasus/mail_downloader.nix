{ config, lib, pkgs, ... }:

# One-way mirror of IMAP mailboxes to local Maildir folders, with mbsync
# (isync). mbsync copies messages as opaque bytes, so malformed old mails
# are not a problem, and it exits with an error when something fails.
#
# The whole mbsync configuration is the sops secret mail_downloader_mbsync,
# so that accounts, addresses and passwords are not public. Each account
# is an IMAPAccount + IMAPStore (far) + MaildirStore (near) + Channel with
#
#   Sync Pull          # never write to the server
#   Create Near        # new remote folders appear locally
#   Expunge Near       # mails deleted on the server are deleted here too
#   SyncState /var/lib/mail_downloader/state/<account>-
#
# with one SyncState prefix per account (state files are named after the
# mailbox, so two accounts with a folder of the same name would clash) and
# the Maildir paths inside mailDir. The MaildirStore Path folders must
# exist: create them once by hand.
#
# mbsync adds an X-TUID header to each copy; mails without an empty line
# between headers and body are skipped with a "skipping" warning in the log.

let
  cfg = config.services.mail_downloader;
  secret = config.sops.secrets.mail_downloader_mbsync;
  user = config.users.users.mail_downloader;

  # mbsync creates files with mode 0600 and folders with 0700, whatever the
  # umask: open them to the group, hence to the backup
  groupReadable = pkgs.writeShellScript "mail_downloader-permissions" ''
    ${pkgs.findutils}/bin/find ${lib.escapeShellArg cfg.mailDir} -type d ! -perm -g=rx -exec ${pkgs.coreutils}/bin/chmod g+rx {} +
    ${pkgs.findutils}/bin/find ${lib.escapeShellArg cfg.mailDir} -type f ! -perm -g=r -exec ${pkgs.coreutils}/bin/chmod g+r {} +
  '';
in
{
  options.services.mail_downloader = {
    enable = lib.mkEnableOption "the download of mails";

    mailDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mail_downloader/mail";
      description = ''
        Base folder of the Maildir copies, the only one mbsync can write to
        besides its state. Also backed up as the `mail` source.
      '';
    };
  };

  imports = [ ./backupper.nix ];

  config = lib.mkIf cfg.enable {
    users.groups.mail_downloader = { };
    users.users.mail_downloader = {
      createHome = true;
      home = "/var/lib/mail_downloader/";
      isSystemUser = true;
      group = config.users.groups.mail_downloader.name;
    };

    sops.secrets.mail_downloader_mbsync = {
      mode = "0400";
      owner = user.name;
      group = user.group;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.mailDir} 0750 mail_downloader mail_downloader - -"
      # mbsync state, kept out of the Maildir folders
      "d ${user.home}/state 0700 mail_downloader mail_downloader - -"
    ];

    # Repositories are chosen by the host
    services.backupper.sources.mail = {
      paths = [ cfg.mailDir ];
      groups = [ config.users.groups.mail_downloader.name ];
      runBefore = [ "mail_downloader.service" ];
    };

    systemd.services.mail_downloader = {
      description = "Sync IMAP to local folders";

      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.mailDir ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.isync}/bin/mbsync --config ${secret.path} --all";
        # also after a failed sync, for the mails already downloaded
        ExecStopPost = groupReadable;
        User = user.name;
        Group = user.group;
        UMask = "0027";

        TemporaryFileSystem = "/:ro";
        PrivateTmp = true;
        BindPaths = [ user.home cfg.mailDir ];
        BindReadOnlyPaths = [
          "/nix/store"
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          secret.path
        ];

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

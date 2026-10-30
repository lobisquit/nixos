{ config, lib, pkgs, ... }:

# Deletes the old Alertmanager notifications from the Sent folder of the
# mailbox used to send them, recognised by the header that every
# Alertmanager adds (see monitoring.nix). Mailbox credentials are in the
# sops secret `alert_mail_cleaner_configuration`; the format is described
# at the top of alert_mail_cleaner.py

let
  cfg = config.services.alert_mail_cleaner;
  secrets = config.sops.secrets;
  python = pkgs.python3.withPackages (ps: [ ps.imapclient ps.pyyaml ]);
in
{
  options.services.alert_mail_cleaner = {
    enable = lib.mkEnableOption "the cleanup of Alertmanager mails from the Sent folder";

    header = lib.mkOption {
      type = lib.types.str;
      default = "X-Alertmanager-Host";
      description = "Header that marks the Alertmanager mails.";
    };

    hosts = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "nasus" "bacero" "octoprint" ];
      description = "Accepted values of the header: the hosts that send alerts.";
    };

    keepDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Mails younger than this many days are kept.";
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Only log the mails that would be deleted.";
    };

    startAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:00:00";
      description = "When to run (systemd OnCalendar format).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.alert_mail_cleaner_configuration = { };

    systemd.services.alert_mail_cleaner = {
      description = "Delete old Alertmanager mails from the Sent folder";
      startAt = cfg.startAt;
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = {
        HEADER = cfg.header;
        HOSTS = lib.concatStringsSep "," cfg.hosts;
        KEEP_DAYS = toString cfg.keepDays;
        DRY_RUN = if cfg.dryRun then "1" else "0";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${python}/bin/python ${./alert_mail_cleaner.py}";
        DynamicUser = true;
        LoadCredential = "configuration:${secrets.alert_mail_cleaner_configuration.path}";

        ProtectHome = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
      };
    };

    # run at the next boot if the machine was off at startAt
    systemd.timers.alert_mail_cleaner.timerConfig.Persistent = true;
  };
}

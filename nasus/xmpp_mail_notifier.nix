{ config, lib, pkgs, ... }:

let
  cfg = config.services.xmpp_mail_notifier;
  secrets = config.sops.secrets;
  python = pkgs.python3.withPackages (ps: [ ps.slixmpp ps.imapclient ps.pyyaml ]);
in
{
  options.services.xmpp_mail_notifier = {
    enable = lib.mkEnableOption ''
      forwarding of new mails from IMAP folders to XMPP.
      Everything (accounts, folders, subject blacklists) is in the
      sops secret `mail_notifier_configuration`; the format is
      described at the top of xmpp_mail_notifier.py
    '';
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.mail_notifier_configuration = {
      # Restart the service when the configuration changes.
      restartUnits = [ "xmpp_mail_notifier.service" ];
    };

    systemd.services.xmpp_mail_notifier = {
      description = "Forward mails from IMAP folders to XMPP";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "prosody.service" ];

      serviceConfig = {
        ExecStart = "${python}/bin/python ${./xmpp_mail_notifier.py}";
        DynamicUser = true;
        StateDirectory = "xmpp_mail_notifier"; # remembers the last seen mails
        LoadCredential = "configuration:${secrets.mail_notifier_configuration.path}";
        Restart = "always";
        RestartSec = 10;

        ProtectHome = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
      };
    };
  };
}

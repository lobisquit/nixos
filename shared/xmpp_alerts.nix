{ config, lib, pkgs, ... }:

# Alertmanager notifications over XMPP.
#
# Alertmanager sends its webhooks to prometheus-xmpp-alerts (listening on
# localhost only), which forwards them as chat messages from a bot
# account on the Prosody server of nasus. The recipients can also reply
# to the bot to query Alertmanager, e.g. "alert" or "silence query".
#
# Setup of a new host:
#   1. on nasus: prosodyctl adduser alertmanager-<host>@lovisotto.it
#   2. sops <host>/secrets.yaml: add `alertmanager_xmpp_password: <password>`

let
  cfg = config.services.xmpp_alerts;
  secrets = config.sops.secrets;
in
{
  options.services.xmpp_alerts = {
    enable = lib.mkEnableOption "Alertmanager notifications over XMPP";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "lovisotto.it";
      description = "XMPP domain of the bot account.";
    };

    jid = lib.mkOption {
      type = lib.types.str;
      default = "alertmanager-${config.networking.hostName}@${cfg.domain}";
      description = ''
        Bot account that sends the alerts; one per host, so that the
        sender tells which host the alert comes from.
      '';
    };

    recipients = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "enrico@${cfg.domain}" ];
      description = ''
        Who receives the alerts. They are also allowed to query
        Alertmanager and set silences by writing to the bot.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9199;
      description = "Local port of the webhook that Alertmanager calls.";
    };

    webhookUrl = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "http://127.0.0.1:${toString cfg.port}/alert";
      description = "URL to put in the Alertmanager webhook_configs.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.alertmanager_xmpp_password = {
      restartUnits = [ "prometheus-xmpp-alerts.service" ];
    };

    services.prometheus.xmpp-alerts = {
      enable = true;
      settings = {
        jid = cfg.jid;
        # The configuration file ends up in the Nix store: the password
        # is read at runtime from the systemd credential (see below).
        password_command = ''cat "$CREDENTIALS_DIRECTORY/password"'';
        listen_address = "127.0.0.1";
        listen_port = cfg.port;
        recipients = map (jid: [ jid "chat" ]) cfg.recipients;
        amtool_allowed = cfg.recipients;
        alertmanager_url =
          "http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}";
      };
    };

    systemd.services.prometheus-xmpp-alerts = {
      after = lib.optional config.services.prosody.enable "prosody.service";
      # amtool, used to answer the "alert" and "silence" commands
      path = [ pkgs.prometheus-alertmanager ];
      serviceConfig = {
        LoadCredential = "password:${secrets.alertmanager_xmpp_password.path}";
        # the module restarts only on failure: keep trying if Prosody
        # (possibly on another host) is unreachable
        Restart = lib.mkForce "always";
        RestartSec = 30;
      };
    };
  };
}

{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.monitoring;
  secrets = config.sops.secrets;
  alertmanagerPort = config.services.prometheus.alertmanager.port;
in

{
  imports = [ ./xmpp_alerts.nix ];

  options.services.monitoring = {

    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    prometheusInternalPort = lib.mkOption {
      type = types.int;
      default = 9090;
    };
  };

  config = mkIf cfg.enable {

    # Alerts go over XMPP; the ones with `severity: critical` also by
    # email, since they may be the reason why XMPP does not work.
    services.xmpp_alerts.enable = true;

    sops.secrets.alertmanager_credentials = {
      mode = "0400";
    };

    services.prometheus = {
      enable = true;
      port = cfg.prometheusInternalPort;
      # Everything listens on localhost only: Prometheus scrapes the
      # exporters locally and the UIs are reached with an SSH tunnel
      # (ssh -L 9090:127.0.0.1:9090 root_<host>).
      listenAddress = "127.0.0.1";
      exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          enabledCollectors = [ "systemd" ];
        };
      };

      scrapeConfigs = [
        {
          job_name = "bacero";
          static_configs = [{
            targets = [
              "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
              # own metrics, to know when notifications fail
              "127.0.0.1:${toString alertmanagerPort}"
            ];
          }];
        }
      ];

      alertmanagers = [
        {
          scheme = "http";
          static_configs = [
            {
              targets = [
                # not "localhost", which may resolve to ::1
                "127.0.0.1:${toString alertmanagerPort}"
              ];
            }
          ];
        }
      ];

      ruleFiles = [ ./monitoring_prometheus_rules.yml ];

      alertmanager = {
        enable = true;
        listenAddress = "127.0.0.1";
        # single instance: no HA gossip, which otherwise listens on
        # 0.0.0.0:9094 (TCP and UDP)
        extraFlags = [ "--cluster.listen-address=" ];
        checkConfig = false;
        configText = ''
          global:
            resolve_timeout: 1m

          route:
            # default route: XMPP only
            group_by: ['job']
            group_wait: 10s
            group_interval: 10s
            repeat_interval: 1d
            receiver: 'xmpp'
            routes:
              # XMPP notifications are failing: email only, sending this
              # one over XMPP as well would just fail again
              - matchers: [ 'alertname="alertmanager:xmpp_failing"' ]
                receiver: 'email'
              - matchers: [ 'severity="critical"' ]
                receiver: 'xmpp_email'

          receivers:
          - name: 'xmpp'
            webhook_configs:
              - url: '${config.services.xmpp_alerts.webhookUrl}'

          - name: 'email'
            email_configs:
              - to: $RECIPIENT
                from: $SENDER
                smarthost: $SMARTHOST
                auth_username: $USERNAME
                auth_identity: $IDENTITY
                auth_password: $PASSWORD

          - name: 'xmpp_email'
            webhook_configs:
              - url: '${config.services.xmpp_alerts.webhookUrl}'
            email_configs:
              - to: $RECIPIENT
                from: $SENDER
                smarthost: $SMARTHOST
                auth_username: $USERNAME
                auth_identity: $IDENTITY
                auth_password: $PASSWORD
          '';
        environmentFile = secrets.alertmanager_credentials.path;
      };
    };

    users.groups.healthchecks_io = {};
    users.users.healthchecks_io = {
      createHome = false;
      isSystemUser = true;
      group = config.users.groups.healthchecks_io.name;
    };

    sops.secrets.healthchecks_io_environment = {
      mode = "0400";
      owner = config.users.users.healthchecks_io.name;
      group = config.users.users.healthchecks_io.group;
    };

    systemd.services.healthchecks_io = {
      enable = true;
      description = "Send alive message to healthchecks.io";

      path = with pkgs; [ curl ];

      script = "curl -fsS -m 10 --retry 5 https://hc-ping.com/$HEALTHCHECKS_IO_CODE";
      serviceConfig = {
        User = config.users.users.healthchecks_io.name;
        EnvironmentFile = secrets.healthchecks_io_environment.path;

        TemporaryFileSystem = "/";
        BindReadOnlyPaths = [
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/nix/store"
        ];
      };

      startAt = "*:0/30";
    };

    systemd.timers.healthchecks_io.timerConfig.RandomizedDelaySec = "10m";
  };
}

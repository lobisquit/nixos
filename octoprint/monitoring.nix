{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.monitoring;
  secrets = config.sops.secrets;
in

{
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

    sops.secrets.alertmanager_credentials = {
      mode = "0400";
    };

    services.prometheus = {
      enable = true;
      port = cfg.prometheusInternalPort;
      exporters = {
        node = {
          enable = true;
          enabledCollectors = [ "systemd" ];
        };
      };

      scrapeConfigs = [
        {
          job_name = "octoprint";
          static_configs = [{
            targets = [
              "127.0.0.1:${toString config.services.prometheus.exporters.node.port}"
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
                "localhost:${toString config.services.prometheus.alertmanager.port}"
              ];
            }
          ];
        }
      ];

      ruleFiles = [ ./monitoring_prometheus_rules.yml ];

      alertmanager = {
        enable = true;
        checkConfig = false;
        configText = ''
          global:
            resolve_timeout: 1m

          route:
            # default route
            group_by: ['job']
            group_wait: 10s
            group_interval: 10s
            repeat_interval: 1d
            receiver: 'email'

          receivers:
          - name: 'email'
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
  };
}

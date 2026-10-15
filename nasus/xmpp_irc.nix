{ config, lib, ... }:
let
  cfg  = config.services.xmpp_irc;
  xcfg = config.services.xmpp_server;
  jid  = "irc.${xcfg.domain}";
in
{
  options.services.xmpp_irc = {
    enable = lib.mkEnableOption "Biboumi IRC gateway";
  };

  config = lib.mkIf cfg.enable {
    # One secret, used in two formats
    sops.secrets.biboumi_secret.owner = "prosody";
    sops.templates."biboumi-credentials".content = ''
      password=${config.sops.placeholder.biboumi_secret}
    '';

    services.biboumi = {
      enable = true;
      credentialsFile = config.sops.templates."biboumi-credentials".path;
      settings = {
        password = null; # real value comes from credentialsFile
        hostname = jid;
        xmpp_server_ip = "127.0.0.1";
        port = 5347;
        admin = xcfg.admins;
        identd_port = 0; # no identd (we won't forward 113)
        realname_customization = true;
        persistent_by_default = true;
      };
    };

    services.prosody.extraConfig = ''
      Component "${jid}"
        component_secret = FileLine("${config.sops.secrets.biboumi_secret.path}")
    '';

    # Fix thanks to
    # https://github.com/NixOS/nixpkgs/issues/493443#issuecomment-3955771427
    systemd.services.biboumi.serviceConfig = {
      RootDirectoryStartOnly = lib.mkForce false;
      RootDirectory = lib.mkForce "";
      BindPaths = lib.mkForce [];
      BindReadOnlyPaths = lib.mkForce [];
    };

    systemd.services.biboumi = {
      after = [ "prosody.service" ];
      wants = [ "prosody.service" ];
    };
  };
}

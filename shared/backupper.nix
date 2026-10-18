{ lib, pkgs, config, ... }:

# Shared restic backup module.
#
# Hosts declare *where* backups go (repositories), while service modules
# declare *what* should be backed up (sources). The host then chooses,
# for every source, the repositories it is sent to: there is no default.
#
# One systemd unit `backup_<repository>` is generated per repository: it
# backs up each source with its own tag, applies the retention policy per
# tag, then runs a single prune and check. The unit only sees, read-only,
# the folders of the sources sent to that repository.

let
  inherit (lib) mkOption mkEnableOption mkIf types;

  cfg = config.services.backupper;
  secrets = config.sops.secrets;
  user = config.users.users.backupper;
  cacheDir = "${user.home}/.cache/restic";

  enabledSources = lib.filterAttrs (_: s: s.enable) cfg.sources;

  # systemd expands specifiers like %h in paths and environment values,
  # so a literal % (Prosody encodes dots as %2e) must be written as %%
  escapeUnit = lib.replaceStrings [ "%" ] [ "%%" ];

  sourceModule = { name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to back up this source.";
      };

      paths = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "Paths to back up; they are bound read-only into the backup service.";
      };

      exclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Restic exclude patterns. Absolute paths that are not part of
          another source of the same repository are also made inaccessible
          to the backup service.
        '';
      };

      tag = mkOption {
        type = types.str;
        default = name;
        description = "Restic tag of the snapshots, also used to apply the retention policy.";
      };

      repositories = mkOption {
        type = types.nonEmptyListOf types.str;
        example = [ "remote" "local" ];
        description = "Names of the repositories this source is sent to; there is no default, every source must choose.";
      };

      groups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra groups the backupper user needs in order to read the paths.";
      };

      runBefore = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "miniflux_backup_admin_opml.service" ];
        description = ''
          Units that prepare the data (dumps, downloads). They are pulled in
          with a weak dependency: if they fail, the backup still runs.
        '';
      };
    };
  };

  repositoryModule = { name, ... }: {
    options = {
      secret = mkOption {
        type = types.str;
        default = "restic_${name}_configuration";
        description = "sops secret with the environment for restic (RESTIC_PASSWORD, RESTIC_REPOSITORY, credentials...).";
      };

      localPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path of a local repository; when set it overrides RESTIC_REPOSITORY,
          it is the only writable path and the service has no network.
        '';
      };

      startAt = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "systemd calendar expression; null means the backup is started manually.";
      };

      randomizedDelay = mkOption {
        type = types.str;
        default = "30m";
      };

      requires = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "mnt-backup_hdd.mount" ];
        description = "Units strictly required by the repository, such as the mount of an external disk.";
      };

      keep = mkOption {
        type = types.attrsOf types.int;
        # the single most recent snapshot of each of the last 7 days,
        # 5 weeks, 12 months and 100 years
        default = { daily = 7; weekly = 5; monthly = 12; yearly = 100; };
        description = "Retention policy, passed to restic forget as --keep-<name> <value>.";
      };
    };
  };

  sourcesFor = repoName:
    lib.filter (s: lib.elem repoName s.repositories) (lib.attrValues enabledSources);

  keepArgs = keep:
    lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--keep-${k} ${toString v}") keep);

  mkScript = repoName: repo: pkgs.writeShellScript "backup-${repoName}" ''
    set -o errexit -o nounset -o pipefail -o xtrace

    ${lib.concatMapStrings (s: ''
      restic backup --verbose ${lib.escapeShellArgs (
        [ "--tag" s.tag "--host" config.networking.hostName ]
        ++ lib.concatMap (e: [ "--exclude" e ]) s.exclude
        ++ s.paths
      )}
      restic forget --verbose --tag ${lib.escapeShellArg s.tag} ${keepArgs repo.keep}

    '') (sourcesFor repoName)}

    restic prune --verbose
    restic check --verbose
  '';

  mkService = repoName: repo:
    let
      sources = sourcesFor repoName;
      prepareUnits = lib.unique (lib.concatMap (s: s.runBefore) sources);
      paths = lib.unique (lib.concatMap (s: s.paths) sources);
      hidden = lib.filter (e: lib.hasPrefix "/" e && !(lib.elem e paths))
        (lib.unique (lib.concatMap (s: s.exclude) sources));
      # a repository on a local path does not need any network access
      isLocal = repo.localPath != null;
    in
    {
      description = "Restic backup to the ${repoName} repository";

      requires = repo.requires;
      wants = prepareUnits;
      after = repo.requires ++ prepareUnits;

      path = [ pkgs.restic ];
      startAt = lib.optional (repo.startAt != null) repo.startAt;

      serviceConfig = {
        Type = "oneshot";
        User = user.name;
        ExecStart = mkScript repoName repo;

        EnvironmentFile = [ secrets.${repo.secret}.path ];
        Environment = map escapeUnit ([ "RESTIC_CACHE_DIR=${cacheDir}" ]
          ++ lib.optional isLocal "RESTIC_REPOSITORY=${repo.localPath}");

        # Empty, read-only root: the only things visible are the bind
        # mounts below. The sops secret is read by systemd through
        # EnvironmentFile before the namespace is set up, so it is not
        # mounted at all.
        TemporaryFileSystem = "/:ro";
        PrivateTmp = true;

        # Read-only: the Nix store, the files restic needs to run and
        # exactly the folders of the sources sent to this repository.
        BindReadOnlyPaths = map escapeUnit ([
          "/nix/store"
          "/etc/passwd" # restic stores the user name in each snapshot
        ] ++ lib.optionals (!isLocal) [
          "/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
        ] ++ paths);

        # Excluded folders are not even readable ("-": ignore if missing).
        InaccessiblePaths = map (p: "-${escapeUnit p}") hidden;

        # Read-write: only the restic cache and, if local, the repository.
        BindPaths = map escapeUnit ([ cacheDir ] ++ lib.optional isLocal repo.localPath);

        # Network only for remote repositories.
        PrivateNetwork = isLocal;
        RestrictAddressFamilies =
          if isLocal then [ "AF_UNIX" ] else [ "AF_UNIX" "AF_INET" "AF_INET6" ];

        # Generic hardening: no privileges, no devices, no kernel tweaks.
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        UMask = "0077";
      };
    };
in
{
  options.services.backupper = {
    enable = mkEnableOption "restic backups";

    group = mkOption {
      type = types.str;
      default = "backupper";
      description = "Primary group of the backupper user.";
    };

    repositories = mkOption {
      type = types.attrsOf (types.submodule repositoryModule);
      default = { };
      description = "Destinations of the backups; each one becomes a backup_<name> service.";
    };

    sources = mkOption {
      type = types.attrsOf (types.submodule sourceModule);
      default = { };
      description = ''
        Data to back up, usually declared by the modules that own it.
        The repositories of each source are chosen by the host.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.groups.${cfg.group} = { };
    users.users.backupper = {
      createHome = true;
      home = "/var/lib/backupper/";
      isSystemUser = true;
      group = cfg.group;
      extraGroups = lib.unique (lib.concatMap (s: s.groups) (lib.attrValues enabledSources));
      uid = 123;
    };

    sops.secrets = lib.mapAttrs' (_: repo: lib.nameValuePair repo.secret {
      mode = "0400";
      owner = user.name;
      group = user.group;
    }) cfg.repositories;

    systemd.tmpfiles.rules = [ "d ${cacheDir} 0750 ${user.name} ${user.group} -" ];

    systemd.services = lib.mapAttrs' (name: repo:
      lib.nameValuePair "backup_${name}" (mkService name repo)
    ) cfg.repositories;

    systemd.timers = lib.mapAttrs' (name: repo:
      lib.nameValuePair "backup_${name}" { timerConfig.RandomizedDelaySec = repo.randomizedDelay; }
    ) (lib.filterAttrs (_: repo: repo.startAt != null) cfg.repositories);

    assertions = lib.flatten (lib.mapAttrsToList (name: s:
      map (r: {
        assertion = cfg.repositories ? ${r};
        message = "services.backupper.sources.${name}: unknown repository '${r}'";
      }) s.repositories
    ) enabledSources);
  };
}

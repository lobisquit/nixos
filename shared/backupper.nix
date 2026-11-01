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
#
# The check can instead run in its own `check_<repository>` unit, at its
# own time: useful for a repository shared by several hosts, where only
# one of them should check it, while no backup is running. Every restic
# command waits (--retry-lock) instead of failing when another host holds
# the lock.

let
  inherit (lib) mkOption mkEnableOption mkIf types;

  # how long a restic command waits for a lock held by someone else
  retryLock = "2h";

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

      prune = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Apply the retention policy (restic forget and prune) after the
          backup. Turn it off for a repository whose credentials cannot
          delete, such as a B2 key without deleteFiles: a compromised host
          can then add snapshots but not remove them, and the retention is
          applied from a trusted machine (scripts/restic_prune_remote.sh,
          which repeats the default policy of `keep`).
        '';
      };

      check = {
        afterBackup = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Run restic check at the end of backup_<name>. Turn it off for a
            repository shared by several hosts: check takes an exclusive
            lock and verifies the whole repository, the other hosts'
            snapshots included, so one host checking it is enough.
          '';
        };

        startAt = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "*-*-* 06:00:00";
          description = ''
            systemd calendar expression of a separate check_<name> unit;
            null means no such unit. Pick a time when no backup of any
            host is running.
          '';
        };

        readDataRotation = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          example = 30;
          description = ''
            In check_<name>, also read and verify the content of 1/N of the
            pack files, a different part every day: the whole repository is
            read every N days. null checks only the structure (index,
            snapshots, trees), never the file content.
          '';
        };
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

  checkedRepositories = lib.filterAttrs (_: repo: repo.check.startAt != null) cfg.repositories;

  sourcesFor = repoName:
    lib.filter (s: lib.elem repoName s.repositories) (lib.attrValues enabledSources);

  keepArgs = keep:
    lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--keep-${k} ${toString v}") keep);

  # every command waits for the lock instead of failing at once
  restic = "restic --retry-lock ${retryLock}";

  mkBackupScript = repoName: repo: pkgs.writeShellScript "backup-${repoName}" ''
    set -o errexit -o nounset -o pipefail -o xtrace

    ${lib.concatMapStrings (s: ''
      ${restic} backup --verbose ${lib.escapeShellArgs (
        [ "--tag" s.tag "--host" config.networking.hostName ]
        ++ lib.concatMap (e: [ "--exclude" e ]) s.exclude
        ++ s.paths
      )}
    '' + lib.optionalString repo.prune ''
      ${restic} forget --verbose --tag ${lib.escapeShellArg s.tag} ${keepArgs repo.keep}
    '' + "\n") (sourcesFor repoName)}
    ${lib.optionalString repo.prune "${restic} prune --verbose"}
    ${lib.optionalString repo.check.afterBackup "${restic} check --verbose"}
  '';

  mkCheckScript = repoName: repo: pkgs.writeShellScript "check-${repoName}" (''
    set -o errexit -o nounset -o pipefail -o xtrace

  '' + (if repo.check.readDataRotation == null then ''
    ${restic} check --verbose
  '' else
    let n = toString repo.check.readDataRotation; in ''
    # a different 1/${n} of the pack files every day, by day of the year
    # (10# avoids reading 008 and 009 as invalid octal numbers)
    part=$(( 10#$(date +%j) % ${n} + 1 ))
    ${restic} check --verbose --read-data-subset "$part/${n}"
  ''));

  # Sandbox shared by backup_<name> and check_<name>: an empty, read-only
  # root where only the given paths are visible.
  sandbox = repo: { readOnly ? [ ], hidden ? [ ] }:
    let
      # a repository on a local path does not need any network access
      isLocal = repo.localPath != null;
    in
    {
      Type = "oneshot";
      User = user.name;

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
      # exactly the given folders (the sources, for a backup).
      BindReadOnlyPaths = map escapeUnit ([
        "/nix/store"
        "/etc/passwd" # restic stores the user name in each snapshot
      ] ++ lib.optionals (!isLocal) [
        "/etc/resolv.conf"
        "/etc/ssl/certs/ca-certificates.crt"
      ] ++ readOnly);

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

  mkBackupService = repoName: repo:
    let
      sources = sourcesFor repoName;
      prepareUnits = lib.unique (lib.concatMap (s: s.runBefore) sources);
      paths = lib.unique (lib.concatMap (s: s.paths) sources);
      hidden = lib.filter (e: lib.hasPrefix "/" e && !(lib.elem e paths))
        (lib.unique (lib.concatMap (s: s.exclude) sources));
    in
    {
      description = "Restic backup to the ${repoName} repository";

      requires = repo.requires;
      wants = prepareUnits;
      after = repo.requires ++ prepareUnits;

      path = [ pkgs.restic ];
      startAt = lib.optional (repo.startAt != null) repo.startAt;

      serviceConfig = sandbox repo { readOnly = paths; inherit hidden; } // {
        ExecStart = mkBackupScript repoName repo;
      };
    };

  mkCheckService = repoName: repo: {
    description = "Restic check of the ${repoName} repository";

    requires = repo.requires;
    # never at the same time as this host's own backup
    after = repo.requires ++ [ "backup_${repoName}.service" ];

    path = [ pkgs.restic pkgs.coreutils ];
    startAt = [ repo.check.startAt ];

    # no source is needed: the check only reads the repository
    serviceConfig = sandbox repo { } // {
      ExecStart = mkCheckScript repoName repo;
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
      lib.nameValuePair "backup_${name}" (mkBackupService name repo)
    ) cfg.repositories
    // lib.mapAttrs' (name: repo:
      lib.nameValuePair "check_${name}" (mkCheckService name repo)
    ) checkedRepositories;

    systemd.timers = lib.mapAttrs' (name: repo:
      lib.nameValuePair "backup_${name}" { timerConfig.RandomizedDelaySec = repo.randomizedDelay; }
    ) (lib.filterAttrs (_: repo: repo.startAt != null) cfg.repositories);

    assertions = lib.flatten (lib.mapAttrsToList (name: s:
      map (r: {
        assertion = cfg.repositories ? ${r};
        message = "services.backupper.sources.${name}: unknown repository '${r}'";
      }) s.repositories
    ) enabledSources)
    ++ lib.mapAttrsToList (name: repo: {
      assertion = repo.check.readDataRotation == null || repo.check.startAt != null;
      message = "services.backupper.repositories.${name}.check.readDataRotation needs check.startAt";
    }) cfg.repositories;
  };
}

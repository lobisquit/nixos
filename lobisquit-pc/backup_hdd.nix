{ ... }:

# The external disk with the local restic repository of nasus, mounted
# automatically on first access when it is plugged in (as /mnt/backup_hdd,
# like on nasus) and unmounted again after some idle time.
#
# Read-only: on the PC it is only browsed (make mount_local), never
# written, so a mistake or a malicious process here cannot damage it.
# Readable by the "users" group, i.e. by enrico.
{
  fileSystems."/mnt/backup_hdd" = {
    device = "/dev/disk/by-uuid/FA3D-8377";
    fsType = "exfat";
    # no fsck at mount time: it is only read here, and fsck.exfat may be
    # missing, which would make the mount fail
    noCheck = true;
    options = [
      "ro"
      "noauto"                       # not at boot...
      "x-systemd.automount"          # ...but on first access
      "x-systemd.idle-timeout=10min" # and released when unused
      "x-systemd.device-timeout=5s"  # no long wait if it is not plugged in
      "nofail"
      # exFAT has no permissions: owner root, group users (gid 100 on
      # NixOS), nothing for others
      "uid=0"
      "gid=100"
      "fmask=0137"
      "dmask=0027"
    ];
  };
}

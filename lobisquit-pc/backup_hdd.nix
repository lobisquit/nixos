{ ... }:

# The external disk with the local restic repository of nasus, mounted on
# /mnt/backup_hdd (like on nasus) as soon as it is plugged in, and
# released when it is removed.
#
# Read-only: on the PC it is only browsed (make mount_local), never
# written, so a mistake or a malicious process here cannot damage it.
# Readable by the "users" group, i.e. by enrico.
let
  uuid = "FA3D-8377";
  where = "/mnt/backup_hdd";
in
{
  fileSystems.${where} = {
    device = "/dev/disk/by-uuid/${uuid}";
    fsType = "exfat";
    # no fsck at mount time: it is only read here, and fsck.exfat may be
    # missing, which would make the mount fail
    noCheck = true;
    options = [
      "ro"
      "noauto"                      # not at boot: udev mounts it on plug (below)
      "nofail"
      "x-systemd.device-bound=true" # unmounted when the disk is removed
      # exFAT has no permissions: owner root, group users (gid 100 on
      # NixOS), nothing for others
      "uid=0"
      "gid=100"
      "fmask=0137"
      "dmask=0027"
    ];
  };

  # Mount on plug: when the disk appears, udev asks systemd to start the
  # mount unit generated from the entry above (mnt-backup_hdd.mount)
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${uuid}", ENV{SYSTEMD_WANTS}+="mnt-backup_hdd.mount"
  '';
}

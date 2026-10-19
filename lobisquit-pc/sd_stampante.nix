{ ... }:

# The SD card of the 3D printer (through a USB reader), always at the same
# path, so that it can be the fixed output folder of the slicer. Mounted
# as soon as it is plugged in, and released when it is removed.
let
  uuid = "0403-0201";
  where = "/mnt/sd_stampante";
in
{
  fileSystems.${where} = {
    device = "/dev/disk/by-uuid/${uuid}";
    fsType = "vfat";
    # no fsck at mount time: it would only slow down the mount
    noCheck = true;
    options = [
      "noauto"                      # not at boot: udev mounts it on plug (below)
      "nofail"
      "x-systemd.device-bound=true" # unmounted when the card is removed
      # write every file to the card as soon as it is closed, so that
      # pulling the card out after a copy does not lose it
      "flush"
      # FAT has no permissions: owner root, group users (gid 100 on
      # NixOS, i.e. enrico) can read and write, nothing for others
      "uid=0"
      "gid=100"
      "fmask=0117"
      "dmask=0007"
    ];
  };

  # Mount on plug: when the card appears, udev asks systemd to start the
  # mount unit generated from the entry above (mnt-sd_stampante.mount)
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${uuid}", ENV{SYSTEMD_WANTS}+="mnt-sd_stampante.mount"
  '';
}

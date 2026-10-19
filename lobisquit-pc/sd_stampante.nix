{ ... }:

# The SD card of the 3D printer (through a USB reader), always at the same
# path, so that it can be the fixed output folder of the slicer. Mounted
# automatically on first access when it is plugged in, and kept mounted
# until it is removed.
{
  fileSystems."/mnt/sd_stampante" = {
    device = "/dev/disk/by-uuid/0403-0201";
    fsType = "vfat";
    # no fsck at mount time: it would only slow down the first access
    noCheck = true;
    options = [
      "noauto"                      # not at boot...
      "x-systemd.automount"         # ...but on first access
      "x-systemd.device-timeout=5s" # no long wait if it is not plugged in
      "x-systemd.device-bound=true" # unmounted when the card is removed
      "nofail"
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
}

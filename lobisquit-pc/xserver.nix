{ lib, ... }:

{
  services.xserver.enable = true;
  services.desktopManager.plasma6.enable = true;

  services.displayManager.sddm = {
    enable = true;
  };
}

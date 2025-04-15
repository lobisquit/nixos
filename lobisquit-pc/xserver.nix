{ lib, ... }:

{
  services.xserver.enable = true;
  services.desktopManager.plasma6.enable = true;

  services.displayManager.sddm = {
    enable = true;
    settings = {
      X11 = {
        ServerArguments = "-nolisten tcp -dpi 96";
      };
    };
  };
}

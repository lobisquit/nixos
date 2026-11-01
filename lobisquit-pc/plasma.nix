{ pkgs, ... }:

{
  programs.plasma = {
    enable = true;

    workspace = {
      clickItemTo = "select";

      wallpaperFillMode = "preserveAspectCrop";
      wallpaper = "${pkgs.kdePackages.plasma-workspace-wallpapers}/share/wallpapers/SafeLanding/contents/images/5120x2880.jpg";
    };

    input = {
      keyboard.layouts = [
        { layout = "it"; }
        { layout = "us"; variant = "alt-intl"; displayName = "usi"; }
        { layout = "us"; }
      ];

      touchpads = [{
        name = "ELAN06FA:00 04F3:32B9 Touchpad";
        vendorId = "04f3";
        productId = "32b9";
        naturalScroll = true;
        tapToClick = true;
        rightClickMethod = "bottomRight";
      }];
    };

    kwin.virtualDesktops = {
      number = 1;
      rows = 1;
    };

    kscreenlocker.autoLock = false;

    session.sessionRestore.restoreOpenApplicationsOnLogin = "startWithEmptySession";

    # Solo le scorciatoie diverse dai default di Plasma
    shortcuts."services/Alacritty.desktop".New = "Ctrl+Alt+T";

    powerdevil = {
      AC.powerButtonAction = "showLogoutScreen";
      battery.powerButtonAction = "showLogoutScreen";
      lowBattery.powerButtonAction = "showLogoutScreen";
    };

    configFile = {
      kdeglobals.General = {
        BrowserApplication = "firefox.desktop";
        TerminalApplication = "alacritty";
        TerminalService = "Alacritty.desktop";
      };

      kdeglobals."KFileDialog Settings" = {
        "Show hidden files" = true;
        "View Style" = "DetailTree";
      };

      # Accelerazione del mouse piatta
      kcminputrc.Mouse.X11LibInputXAccelProfileFlat = true;

      # Niente angolo attivo per la panoramica
      kwinrc.Effect-overview.BorderActivate = 9;

      baloofilerc.General."only basic indexing" = true;

      dolphinrc.General.RememberOpenedTabs = false;
      dolphinrc.IconsMode.PreviewSize = 112;

      # In Plasma 6 il file è kded6rc (kded5rc è un residuo di Plasma 5)
      kded6rc = {
        Module-browserintegrationreminder.autoload = false;
        Module-device_automounter.autoload = false;
      };
    };
  };
}

{ lib, inputs, outputs, ... }:

{
  users.users.enrico = {
    isNormalUser = true;
    description = "Enrico Lovisotto";
    extraGroups = [ "networkmanager" "wheel" "dialout" ];
  };
}

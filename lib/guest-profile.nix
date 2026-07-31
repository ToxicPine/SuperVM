{
  flakeRef,
  attribute,
}:

let
  profileFlake = builtins.getFlake flakeRef;
  guestProfiles =
    if profileFlake ? lib && profileFlake.lib ? guestProfiles then
      profileFlake.lib.guestProfiles
    else
      profileFlake.nixosConfigurations;
in
builtins.getAttr attribute guestProfiles

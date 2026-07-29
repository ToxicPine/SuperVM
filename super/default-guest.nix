# The configuration `supervm` boots when the caller does not name one.
#
# Deliberately minimal: it exists so `supervm <dir>` works with no further
# arguments, and as a worked example of what a caller's own configuration
# needs to contain, which is very little. Everything to do with microvm.nix,
# Snix and DAX is merged in by the SuperVM template.
{ nixpkgs, system }:

nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [
    {
      networking.hostName = "supervm";
      system.stateVersion = "24.05";

      users.users.root.password = "";
      services.getty.autologinUser = "root";

      environment.systemPackages = [ ];
    }
  ];
}

# Guest NixOS configurations and runners for the density benchmark.
#
# The benchmark boots up to 1024 identical nginx guests plus one idle
# guest.  Each load guest gets a deterministic address on 10.231.0.0/16,
# a locally-administered MAC, and a tap name derived from its index.
{
  lib,
  supervm,
  system,
}:
let
  instanceIndexes = lib.range 1 1024;
  formatHexByte = value: lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString value));
  makeLoadConfiguration =
    index:
    let
      thirdOctet = (index - 1) / 254;
      fourthOctet = (index - 1) - (thirdOctet * 254) + 1;
      macHigh = index / 256;
      macLow = index - (macHigh * 256);
    in
    lib.nixosSystem {
      inherit system;
      modules = [
        (import ./nginx-guest.nix {
          inherit index;
          address = "10.231.${toString thirdOctet}.${toString fourthOctet}";
          mac = "02:73:00:00:${formatHexByte macHigh}:${formatHexByte macLow}";
          tap = "svb${toString index}";
        })
      ];
    };
  idleConfiguration = lib.nixosSystem {
    inherit system;
    modules = [ ./idle-guest.nix ];
  };
  loadGuestConfigurations = builtins.listToAttrs (
    map (index: {
      name = "load-${toString index}";
      value = makeLoadConfiguration index;
    }) instanceIndexes
  );
  guestConfigurations = {
    idle = idleConfiguration;
  }
  // loadGuestConfigurations;
in
{
  inherit guestConfigurations loadGuestConfigurations;

  lameRunners = lib.mapAttrs (
    _name: guestConfiguration: supervm.lib.mkLameRunner { guest = guestConfiguration; }
  ) guestConfigurations;
}

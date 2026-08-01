{
  description = "Guest configurations for the SuperVM density benchmark";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;
      instanceIndexes = lib.range 1 1024;
      formatHexByte = value: lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString value));
      makeLoadProfile =
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
      loadProfiles = builtins.listToAttrs (
        map (index: {
          name = "load-${toString index}";
          value = makeLoadProfile index;
        }) instanceIndexes
      );
    in
    {
      lib.guestProfiles = {
        idle = lib.nixosSystem {
          inherit system;
          modules = [ ./idle-guest.nix ];
        };
      }
      // loadProfiles;

      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt;
    };
}

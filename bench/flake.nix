{
  description = "Guest configurations for the SuperVM density benchmark";

  inputs = {
    supervm.url = ../.;
    nixpkgs.follows = "supervm/nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      supervm,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
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
      lameRunners = lib.mapAttrs (
        _name: guestConfiguration: supervm.lib.mkLameRunner { guest = guestConfiguration; }
      ) guestConfigurations;
    in
    {
      nixosConfigurations = guestConfigurations;

      packages.${system}.supervm = supervm.packages.${system}.supervm;

      lameRunners.${system} = lameRunners;

      checks.${system} = {
        nginx-profile-lamevm = lameRunners."load-1";
        nginx-profile-supervm = supervm.lib.mkSuperRunner {
          guest = loadGuestConfigurations."load-1";
          daxMode = "always";
          upperStoreDir = "/var/lib/supervm-bench/check";
          lowerStoreFsSocket = "/run/supervm-bench/check-lower.sock";
          vsockCid = 3;
        };
        shellcheck =
          pkgs.runCommand "supervm-bench-shellcheck"
            {
              nativeBuildInputs = [ pkgs.shellcheck ];
            }
            ''
              cd ${./.}
              shellcheck \
                --enable=all \
                --external-sources \
                run-*.sh
              touch "$out"
            '';
      };
    };
}

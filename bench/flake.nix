{
  description = "Guest configurations for the SuperVM density benchmark";

  inputs = {
    supervm.url = ../.;
    nixpkgs.follows = "supervm/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      supervm,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      guests = import ./guests.nix {
        inherit lib supervm system;
      };
      benchmarkScriptNames = [
        "run-idle-fixed-count"
        "run-idle-max-count"
        "run-nginx-fixed-count"
        "run-nginx-max-count"
      ];
      # The run scripts locate the benchmark flake and the SuperVM source
      # tree relative to their own path, which points into the Nix store
      # when they run as flake apps.  Pin both references to the sources
      # this flake was evaluated from instead.
      makeBenchmarkApp = scriptName: {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = scriptName;
            text = ''
              export BENCHMARK_PROGRAM_NAME=''${BENCHMARK_PROGRAM_NAME:-${scriptName}}
              export SUPERVM_BENCH_FLAKE=''${SUPERVM_BENCH_FLAKE:-path:${self}}
              export SUPERVM_SOURCE_FLAKE=''${SUPERVM_SOURCE_FLAKE:-path:${supervm}}
              exec bash ${self}/${scriptName}.sh "$@"
            '';
          }
        );
      };
    in
    {
      nixosConfigurations = guests.guestConfigurations;

      packages.${system}.supervm = supervm.packages.${system}.supervm;

      lameRunners.${system} = guests.lameRunners;

      apps.${system} = lib.genAttrs benchmarkScriptNames makeBenchmarkApp;

      checks.${system} = {
        nginx-profile-lamevm = guests.lameRunners."load-1";
        nginx-profile-supervm = supervm.lib.mkSuperRunner {
          guest = guests.loadGuestConfigurations."load-1";
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

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
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.${system};
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
      idleProfiles = {
        idle = lib.nixosSystem {
          inherit system;
          modules = [ ./idle-guest.nix ];
        };
      };
      guestProfiles = idleProfiles // loadProfiles;
      benchmarkPrograms = [
        "run-idle-fixed-count.sh"
        "run-idle-max-count.sh"
        "run-nginx-fixed-count.sh"
        "run-nginx-max-count.sh"
      ];
      benchmarkRuntimePath = lib.makeBinPath (
        with pkgs;
        [
          bash
          coreutils
          findutils
          curl
          gawk
          gnused
          iproute2
          procps
          systemd
          util-linux
        ]
      );
      benchmarkProfileSource = pkgs.runCommand "supervm-benchmark-profile-source" { } ''
        mkdir -p "$out/bench"
        cp -R ${supervm.packages.${system}.supervm.sourceFlake}/. "$out/"
        cp -R ${./.}/. "$out/bench/"
      '';
      benchmarkSuite =
        pkgs.runCommand "supervm-benchmark-suite"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
          }
          ''
            mkdir -p "$out/bin" "$out/share/supervm-bench"
            cp -R ${./libexec} "$out/share/supervm-bench/libexec"
            ${lib.concatMapStringsSep "\n" (
              program:
              let
                source = ./. + "/${program}";
              in
              ''
                install -m755 ${source} "$out/share/supervm-bench/${program}"
                makeWrapper "$out/share/supervm-bench/${program}" "$out/bin/${program}" \
                  --set BENCHMARK_PROFILE_FLAKE "path:${benchmarkProfileSource}/bench" \
                  --set SUPERVM_LAUNCHER "${supervm.packages.${system}.supervm}/bin/supervm" \
                  --set LAMEVM_LAUNCHER "${supervm.packages.${system}.lamevm}/bin/lamevm" \
                  --set PATH "${benchmarkRuntimePath}"
              ''
            ) benchmarkPrograms}
          '';
    in
    {
      lib.guestProfiles = guestProfiles;

      packages.${system}.benchmark-suite = benchmarkSuite;

      apps.${system} = {
        idle-fixed-count = {
          type = "app";
          program = "${benchmarkSuite}/bin/run-idle-fixed-count.sh";
          meta.description = "Benchmark a fixed number of idle VMs";
        };
        idle-max-count = {
          type = "app";
          program = "${benchmarkSuite}/bin/run-idle-max-count.sh";
          meta.description = "Measure idle VM density under a memory limit";
        };
        nginx-fixed-count = {
          type = "app";
          program = "${benchmarkSuite}/bin/run-nginx-fixed-count.sh";
          meta.description = "Benchmark a fixed number of nginx VMs";
        };
        nginx-max-count = {
          type = "app";
          program = "${benchmarkSuite}/bin/run-nginx-max-count.sh";
          meta.description = "Measure nginx VM density under a memory limit";
        };
      };

      checks.${system} = {
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
                run-*.sh \
                libexec/process-memory-report.sh
              touch "$out"
            '';
      };
    };
}

{
  lib,
  pkgs,
  supervmPackage,
  lamevmPackage,
}:

let
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
      gnugrep
      gnused
      iproute2
      nix
      procps
      systemd
      util-linux
    ]
  );
  benchmarkProfileSource = pkgs.runCommand "supervm-benchmark-profile-source" { } ''
    mkdir -p "$out/bench"
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
              --set SUPERVM_LAUNCHER "${supervmPackage}/bin/supervm" \
              --set LAMEVM_LAUNCHER "${lamevmPackage}/bin/lamevm" \
              --set PATH "${benchmarkRuntimePath}"
          ''
        ) benchmarkPrograms}
      '';
in
{
  package = benchmarkSuite;

  check = pkgs.runCommand "supervm-bench-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
    cd ${./.}
    shellcheck \
      --enable=all \
      --external-sources \
      run-*.sh \
      libexec/process-memory-report.sh
    touch "$out"
  '';

  apps = {
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
}

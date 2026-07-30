# Package the small sourced modules that implement the SuperVM command.

{
  lib,
  writeText,
  writeTextFile,
  runtimeShell,
  stdenv,
  shellcheck,
  nix,
  coreutils,
  util-linux,
  socat,
  gnugrep,
  findutils,
  jq,
  snix,
  self,
}:

let
  arguments = writeText "supervm-arguments.sh" (builtins.readFile ./cli/arguments.sh);
  runtime = writeText "supervm-runtime.sh" (builtins.readFile ./cli/runtime.sh);
  prepare = writeText "supervm-prepare.sh" (builtins.readFile ./cli/prepare.sh);
  launch = writeText "supervm-launch.sh" (builtins.readFile ./cli/launch.sh);
in
writeTextFile {
  name = "supervm";
  destination = "/bin/supervm";
  executable = true;

  checkPhase = ''
    ${stdenv.shellDryRun} "$target"
    ${lib.getExe shellcheck} \
      --enable=all \
      --external-sources \
      --shell=bash \
      "$target"
  '';

  text = ''
    #!${runtimeShell}
    set -o errexit
    set -o nounset
    set -o pipefail

    export PATH="${
      lib.makeBinPath [
        nix
        coreutils
        util-linux
        socat
        gnugrep
        findutils
        jq
        snix
      ]
    }:''${PATH}"
    readonly SUPERVM_FLAKE=${self}

    source ${arguments}
    source ${runtime}
    source ${prepare}
    source ${launch}

    parse_arguments "''${@}"
    initialize

    case "''${subcommand}" in
      prepare) run_prepare ;;
      launch) run_launch ;;
      *) fail "internal error: unknown subcommand ''${subcommand}" ;;
    esac
  '';

  meta.description = "Prepare or boot a NixOS MicroVM with persistent private state";
}

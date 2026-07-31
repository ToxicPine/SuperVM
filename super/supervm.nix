# Package the small sourced modules that implement the SuperVM command.

{
  writeText,
  writeShellApplication,
  nix,
  coreutils,
  util-linux,
  socat,
  gawk,
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
writeShellApplication {
  name = "supervm";
  runtimeInputs = [
    nix
    coreutils
    util-linux
    socat
    gawk
    gnugrep
    findutils
    jq
    snix
  ];
  inheritPath = false;
  extraShellCheckFlags = [
    "--enable=all"
    "--external-sources"
  ];
  text = ''
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

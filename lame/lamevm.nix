{
  coreutils,
  nix,
  self,
  writeShellApplication,
}:

writeShellApplication {
  name = "lamevm";
  runtimeInputs = [
    nix
    coreutils
  ];
  inheritPath = false;
  extraShellCheckFlags = [ "--enable=all" ];
  text = ''
    readonly LAMEVM_FLAKE=${self}

    usage() {
      cat >&2 <<'USAGE'
    usage: lamevm prepare [--profile=FLAKE#CONFIG] <state-dir>
           lamevm launch <state-dir>

      prepare   Build the guest without booting and record its runner.

      launch    Boot the most recently prepared guest for this state directory.

      --profile NixOS guest configuration to boot, as FLAKE#NAME. Defaults to
                the same minimal configuration as supervm.

      state-dir Directory holding the prepared runner and VM runtime files.
                Created by prepare and reusable by launch.
    USAGE
      exit 2
    }

    fail() {
      echo "lamevm: $*" >&2
      exit 1
    }

    (($# > 0)) || usage
    subcommand=$1
    shift
    case ''${subcommand} in
      prepare | launch) ;;
      -h | --help) usage ;;
      *) usage ;;
    esac

    profile=
    positionals=()
    while (($# > 0)); do
      case $1 in
        --profile=*)
          profile=''${1#--profile=}
          [[ -n ''${profile} ]] || usage
          shift
          ;;
        --profile)
          (($# >= 2)) || usage
          profile=$2
          [[ -n ''${profile} ]] || usage
          shift 2
          ;;
        -h | --help)
          usage
          ;;
        --)
          shift
          positionals+=("$@")
          break
          ;;
        -*)
          usage
          ;;
        *)
          positionals+=("$1")
          shift
          ;;
      esac
    done

    ((''${#positionals[@]} == 1)) || usage
    [[ -z ''${profile} || ''${profile} == ?*#?* ]] || usage
    if [[ ''${subcommand} == launch && -n ''${profile} ]]; then
      usage
    fi

    state_dir=$(realpath -m "''${positionals[0]}")
    runner_link="''${state_dir}/runner"

    if [[ ''${subcommand} == prepare ]]; then
      if [[ -n ''${profile} ]]; then
        export LAMEVM_PROFILE_FLAKE_REF=''${profile%%#*}
        export LAMEVM_PROFILE_ATTRIBUTE=''${profile##*#}
        profile_arg="profile = {
          flakeRef = builtins.getEnv \"LAMEVM_PROFILE_FLAKE_REF\";
          attribute = builtins.getEnv \"LAMEVM_PROFILE_ATTRIBUTE\";
        };"
      else
        profile_arg=""
      fi

      mkdir -p "''${state_dir}"
      echo "lamevm: building vanilla microvm.nix guest"
      runner=$(nix build --impure \
        --out-link "''${runner_link}" \
        --print-out-paths \
        --expr \
        "(builtins.getFlake \"''${LAMEVM_FLAKE}\").lib.lamevm.mkRunner {
           ''${profile_arg}
         }")
      [[ -x ''${runner}/bin/microvm-run ]] ||
        fail "prepared runner is not executable"
      echo "lamevm: prepared ''${runner}"
      exit 0
    fi

    [[ -L ''${runner_link} && -x ''${runner_link}/bin/microvm-run ]] ||
      fail "guest is not prepared; run 'lamevm prepare' first"
    runner=$(readlink -f "''${runner_link}")
    runtime_dir="''${state_dir}/runtime"
    mkdir -p "''${runtime_dir}"

    cleanup() {
      rm -f "''${runtime_dir}/crosvm.sock"
    }
    trap cleanup EXIT

    echo "lamevm: booting"
    cd "''${runtime_dir}"
    "''${runner}/bin/microvm-run"
  '';

  meta.description = "Prepare or boot a vanilla microvm.nix baseline";
}

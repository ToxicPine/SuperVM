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
    usage() {
      cat >&2 <<'USAGE'
    usage: lamevm [flake-ref#nixos-configuration]

      Boots the same guest configuration through vanilla microvm.nix,
      nixpkgs crosvm and a read-only store disk. It has no persistent state.
    USAGE
      exit 2
    }

    [[ $# -le 1 ]] || usage
    case "''${1:-}" in
      -h | --help) usage ;;
      *) ;;
    esac

    guest=''${1:-}
    if [[ -n ''${guest} ]]; then
      guest_arg="guest = (builtins.getFlake \"''${guest%%#*}\").nixosConfigurations.\"''${guest##*#}\";"
    else
      guest_arg=""
    fi

    echo "lamevm: building vanilla microvm.nix guest"
    runner=$(nix build --impure --no-link --print-out-paths --expr \
      "(builtins.getFlake \"${self}\").lib.mkLameRunner {
         ''${guest_arg}
       }")

    runtime_root=''${XDG_RUNTIME_DIR:-/tmp}
    mkdir -p "''${runtime_root}"
    runtime_dir=$(mktemp -d "''${runtime_root}/lamevm.XXXXXXXX")

    cleanup() {
      rm -f "''${runtime_dir}/crosvm.sock"
      rmdir "''${runtime_dir}" 2>/dev/null || true
    }
    trap cleanup EXIT

    echo "lamevm: booting without Snix, DAX or persistent upper state"
    cd "''${runtime_dir}"
    "''${runner}/bin/microvm-run"
  '';

  meta.description = "Boot a vanilla microvm.nix and nixpkgs-crosvm baseline";
}

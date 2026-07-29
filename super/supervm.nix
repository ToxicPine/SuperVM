# The `supervm` command: boot a MicroVM from one directory of persistent state.
#
# The guest configuration is whatever NixOS configuration the caller points at;
# SuperVM merges its template over it with `extendModules` (see super/template.nix),
# so a caller brings a plain NixOS config and does not have to know about
# microvm.nix, Snix or DAX.

{
  lib,
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

writeTextFile {
  name = "supervm";
  destination = "/bin/supervm";
  executable = true;

  checkPhase = ''
    ${stdenv.shellDryRun} "$target"
    ${lib.getExe shellcheck} --enable=all --shell=bash "$target"
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

    usage() {
      cat >&2 <<'USAGE'
    usage: supervm [--dax=MODE] [--profile=FLAKE#CONFIG] <upper-store-dir>

      --dax      DAX policy: never, inode, or always. Defaults to inode.

      --profile  NixOS configuration to boot, as a flake reference and
                  nixosConfigurations attribute. SuperVM merges its guest
                  template over it. Defaults to a minimal configuration.

      upper-store-dir
                  directory holding this VM's persistent private state.
                  Created if absent; reusing one resumes that VM.
    USAGE
      exit 2
    }

    dax_mode=inode
    profile=
    positionals=()
    while (( $# > 0 )); do
      case "''${1}" in
        --dax=*)
          dax_mode=''${1#--dax=}
          shift
          ;;
        --dax)
          (( $# >= 2 )) || usage
          dax_mode=''${2}
          shift 2
          ;;
        --profile=*)
          profile=''${1#--profile=}
          [[ -n ''${profile} ]] || usage
          shift
          ;;
        --profile)
          (( $# >= 2 )) || usage
          profile=''${2}
          [[ -n ''${profile} ]] || usage
          shift 2
          ;;
        -h | --help)
          usage
          ;;
        --)
          shift
          positionals+=("''${@}")
          break
          ;;
        -*)
          usage
          ;;
        *)
          positionals+=("''${1}")
          shift
          ;;
      esac
    done

    case "''${dax_mode}" in
      never | inode | always) ;;
      *) usage ;;
    esac
    (( ''${#positionals[@]} == 1 )) || usage

    upper_store_dir=$(realpath -m "''${positionals[0]}")

    runtime_dir=''${XDG_RUNTIME_DIR:-/tmp}/supervm
    state_dir=''${XDG_STATE_HOME:-''${HOME}/.local/state}/supervm
    castore="''${state_dir}/castore"
    mkdir -p "''${runtime_dir}/leases" "''${castore}/blobs" \
      "''${state_dir}/store" "''${upper_store_dir}"

    dax_args=()
    if [[ ''${dax_mode} != never ]]; then
      mkdir -p "''${state_dir}/dax-backing"
      dax_args=(--dax-backing-dir "''${state_dir}/dax-backing")
    fi

    # One VM per upper directory. Held for the life of the VM and released by
    # the kernel if we die, so a crash does not strand it.
    exec 9>"''${upper_store_dir}/.supervm.lock"
    if ! flock -n 9; then
      echo "supervm: ''${upper_store_dir} is already in use by another VM" >&2
      exit 1
    fi

    upper_store_dir_hash=$(printf '%s' "''${upper_store_dir}" | sha256sum)
    vm_id=''${upper_store_dir_hash:0:16}
    # vsock context ids 0-2 are reserved.
    vsock_cid=$(( (0x''${vm_id:0:4} % 64000) + 3 ))
    vm_runtime_dir="''${runtime_dir}/vms/''${vm_id}"
    mkdir -p "''${vm_runtime_dir}"
    lower_store_fs_socket="''${runtime_dir}/''${vm_id}-lower.sock"
    crosvm_control_socket="''${vm_runtime_dir}/crosvm.sock"
    echo "supervm: vm ''${vm_id} (cid ''${vsock_cid})"

    # sockaddr_un caps a path at 108 bytes including its terminator, and the
    # error a VMM reports for overrunning it names neither the path nor the
    # limit. Check every per-VM socket while their purpose is still visible.
    for socket_path in "''${lower_store_fs_socket}" "''${crosvm_control_socket}"; do
      if (( ''${#socket_path} > 107 )); then
        echo "supervm: socket path is ''${#socket_path} bytes, over the 107 the" \
          "kernel allows:" >&2
        echo "  ''${socket_path}" >&2
        echo "supervm: set XDG_RUNTIME_DIR to something shorter" >&2
        exit 1
      fi
    done

    # A VM orphaned by a killed wrapper keeps its vsock context id, and the
    # next run fails with nothing more informative than "address already in
    # use". Its working directory is derived from the upper directory we hold
    # the lock on, so a crosvm process running there is our own leftover.
    for d in /proc/[0-9]*; do
      pid=''${d#/proc/}
      exe=$(readlink "/proc/''${pid}/exe" 2>/dev/null) || continue
      case "''${exe}" in *crosvm*) ;; *) continue ;; esac
      process_cwd=$(readlink "/proc/''${pid}/cwd" 2>/dev/null) || continue
      [[ "''${process_cwd}" == "''${vm_runtime_dir}" ]] || continue
      echo "supervm: reaping orphaned VM ''${pid} from ''${vm_runtime_dir}"
      kill -9 "''${pid}" 2>/dev/null || true
    done

    wait_for_socket() {
      local i
      for (( i = 0; i < 600; i++ )); do
        [[ -S ''${1} ]] && return 0
        sleep 0.05
      done
      echo "supervm: timed out waiting for ''${1}" >&2
      return 1
    }

    if [[ -n ''${profile} ]]; then
      guest_arg="guest = (builtins.getFlake \"''${profile%%#*}\").nixosConfigurations.\"''${profile##*#}\";"
    else
      guest_arg=""
    fi

    echo "supervm: building guest"
    runner=$(nix build --impure --no-link --print-out-paths --expr \
      "(builtins.getFlake \"${self}\").lib.mkSuperRunner {
         upperStoreDir = \"''${upper_store_dir}\";
         vsockCid = ''${vsock_cid};
         lowerStoreFsSocket = \"''${lower_store_fs_socket}\";
         daxMode = \"''${dax_mode}\";
         ''${guest_arg}
       }")

    lease="''${runtime_dir}/leases/''${vm_id}"

    # Prune leases whose process is gone, so a crash does not pin the services.
    for l in "''${runtime_dir}"/leases/*; do
      [[ -e ''${l} ]] || continue
      lease_pid=$(cat "''${l}")
      kill -0 "''${lease_pid}" 2>/dev/null || rm -f "''${l}"
    done

    store_socket="''${runtime_dir}/store.sock"
    lower_meta_socket="''${runtime_dir}/lower.sock"

    # The castore daemon is the only thing that opens the databases directly.
    # redb is single-writer, so a second VM reaching past it would fail to take
    # the lock; everything downstream goes through this socket instead.
    if [[ ! -S ''${store_socket} ]]; then
      echo "supervm: starting shared castore daemon"
      snix store daemon -l "''${store_socket}" --unix-listen-unlink \
        --blob-service-addr "objectstore+file:''${castore}/blobs" \
        --directory-service-addr "redb:''${castore}/directories.redb" \
        --path-info-service-addr "redb:''${state_dir}/store/pathinfo.redb" \
        >"''${runtime_dir}/store.log" 2>&1 &
      echo $! >"''${runtime_dir}/store.pid"
      wait_for_socket "''${store_socket}"
    fi

    export BLOB_SERVICE_ADDR="grpc+unix:''${store_socket}"
    export DIRECTORY_SERVICE_ADDR="grpc+unix:''${store_socket}"
    export PATH_INFO_SERVICE_ADDR="grpc+unix:''${store_socket}"

    if [[ ! -S ''${lower_meta_socket} ]]; then
      echo "supervm: starting shared lower-store daemon"
      snix nix-daemon -l "''${lower_meta_socket}" --unix-listen-unlink \
        --unix-listen-chmod everybody >"''${runtime_dir}/lower.log" 2>&1 &
      echo $! >"''${runtime_dir}/lower.pid"
      wait_for_socket "''${lower_meta_socket}"

      # Bridge it to vsock, which is how the guest reaches it: a unix socket
      # cannot be reached across virtio-fs, since connect() resolves to an
      # inode and the guest kernel has no listener bound to the host's.
      socat "VSOCK-LISTEN:5000,fork,reuseaddr" \
        "UNIX-CONNECT:''${lower_meta_socket}" \
        >"''${runtime_dir}/bridge.log" 2>&1 &
      echo $! >"''${runtime_dir}/bridge.pid"
    fi

    echo $$ >"''${lease}"

    # The guest execs init= out of the merged store, and on a fresh upper that
    # can only come from the lower, so the closure has to be in the castore
    # before boot. Pushed into the lower rather than seeded into the upper: the
    # lower is shared between VMs and an upper is not, and a private copy per
    # VM is the duplication this design exists to remove.
    echo "supervm: ingesting system closure"
    system=$(readlink -f "''${runner}/share/microvm/system")

    # `copy` wants the closure's metadata, not just a path, so references and
    # hashes survive into the store the guest queries. Content-addressed, so a
    # warm castore makes this close to a no-op.
    #
    # Nix 2.23 and later emit an object keyed by store path, while `copy`
    # expects the older list-of-objects form, hence the reshape.
    refs="''${runtime_dir}/''${vm_id}-refs.json"
    nix path-info --json --recursive "''${system}" |
      jq '[to_entries[] | .value + {path: .key}]' >"''${refs}"
    snix store copy "''${refs}" >/dev/null
    rm -f "''${refs}"

    # Which tag the guest will mount. Crosvm's vhost-user frontend asks the
    # backend for the virtio-fs identity rather than being told it, so the
    # server has to advertise the tag the guest was built to mount, and the
    # mismatch surfaces only as "wrong fs type" in stage 1. microvm.nix records
    # each share as share/microvm/virtiofs/<tag>/socket, so take it from there
    # rather than keeping a second copy of the name in sync by hand.
    lower_store_tag=""
    for share_dir in "''${runner}"/share/microvm/virtiofs/*/; do
      [[ -e "''${share_dir}socket" ]] || continue
      [[ $(<"''${share_dir}socket") == "''${lower_store_fs_socket}" ]] || continue
      lower_store_tag=$(basename "''${share_dir}")
      break
    done
    if [[ -z ''${lower_store_tag} ]]; then
      echo "supervm: no virtio-fs share in the runner uses" \
        "''${lower_store_fs_socket}" >&2
      exit 1
    fi

    # This VM's own view of the lower store. DAX modes use a common backing
    # directory, which lets guests share host pages for paths they have in
    # common. Never mode omits the window and serves ordinary reads.
    echo "supervm: starting lower-store filesystem (tag ''${lower_store_tag})"
    snix store virtiofs "''${dax_args[@]}" \
      --tag "''${lower_store_tag}" \
      "''${lower_store_fs_socket}" >"''${runtime_dir}/''${vm_id}-fs.log" 2>&1 &
    fs_pid=$!
    wait_for_socket "''${lower_store_fs_socket}"

    cleanup() {
      kill "''${fs_pid}" 2>/dev/null || true
      rm -f "''${lease}" "''${lower_store_fs_socket}" "''${crosvm_control_socket}"

      local remaining
      remaining=$(find "''${runtime_dir}/leases" -mindepth 1 -maxdepth 1 -print -quit)
      if [[ -z ''${remaining} ]]; then
        echo "supervm: last VM out, stopping shared services"
        local p pid
        for p in store lower bridge; do
          if [[ -f "''${runtime_dir}/''${p}.pid" ]]; then
            pid=$(cat "''${runtime_dir}/''${p}.pid")
            kill "''${pid}" 2>/dev/null || true
            rm -f "''${runtime_dir}/''${p}.pid"
          fi
        done
        rm -f "''${store_socket}" "''${lower_meta_socket}"
      fi
    }
    trap cleanup EXIT

    echo "supervm: booting"
    cd "''${vm_runtime_dir}"

    # Run in the foreground, not backgrounded and not exec'd. Crosvm owns the
    # terminal for its serial console; retaining this wrapper process is what
    # lets the trap above release the frontend and shared-service lease.
    # A wrapper killed outright still leaves the VM behind, which is what the
    # reaper at startup is for.
    "''${runner}/bin/microvm-run"
  '';

  meta.description = "Boot a NixOS MicroVM from one directory of persistent state";
}

usage() {
  cat >&2 <<'USAGE'
usage: supervm prepare [--dax=MODE] [--profile=FLAKE#CONFIG] <upper-store-dir>
       supervm launch <upper-store-dir>

  prepare   Build the guest and populate the shared store without booting.

  launch    Boot the most recently prepared guest for this state directory.

  --dax     DAX policy: never, inode, or always. Defaults to inode.

  --profile NixOS configuration to boot, as a flake reference and
            nixosConfigurations attribute. SuperVM merges its guest template
            over it. Defaults to a minimal configuration.

  upper-store-dir
            Directory holding this VM's persistent private state. Created if
            absent; reusing one resumes that VM.
USAGE
  exit 2
}

fail() {
  echo "supervm: $*" >&2
  exit 1
}

parse_arguments() {
  (($# > 0)) || usage
  subcommand=$1
  shift
  case ${subcommand} in
    prepare | launch) ;;
    -h | --help) usage ;;
    *) usage ;;
  esac

  dax_mode=inode
  dax_set=false
  profile=
  positionals=()
  while (($# > 0)); do
    case $1 in
      --dax=*)
        dax_mode=${1#--dax=}
        dax_set=true
        shift
        ;;
      --dax)
        (($# >= 2)) || usage
        dax_mode=$2
        dax_set=true
        shift 2
        ;;
      --profile=*)
        profile=${1#--profile=}
        [[ -n ${profile} ]] || usage
        shift
        ;;
      --profile)
        (($# >= 2)) || usage
        profile=$2
        [[ -n ${profile} ]] || usage
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

  case ${dax_mode} in
    never | inode | always) ;;
    *) usage ;;
  esac
  ((${#positionals[@]} == 1)) || usage
  if [[ ${subcommand} == launch &&
    (${dax_set} == true || -n ${profile}) ]]; then
    usage
  fi
}

sync_tree_files() {
  local root=$1

  [[ -e ${root} ]] || return 0
  find -L "${root}" -type f -exec sync {} +
}

evict_tree_cache() {
  local root=$1
  local file

  [[ -e ${root} ]] || return 0
  while IFS= read -r -d '' file; do
    fadvise --advice dontneed "${file}"
  done < <(find -L "${root}" -type f -print0)
}

prepare_instance_artifact() {
  local family=$1
  local index=$2
  local instance="${FAMILY_OUTPUT_DIR}/instances/${index}"
  local guest
  local profile
  local runner
  local upper
  local upper_hash
  local prepare_log="${FAMILY_OUTPUT_DIR}/prepare-logs/${index}.log"
  local -a command_environment=()

  [[ ${INSTANCE_IS_PREPARED[${index}]:-} != true ]] || return 0
  mkdir -p "${instance}/runtime"
  guest=$(benchmark_variant_guest "${index}" "${BENCHMARK_FLAKE}")

  printf 'supervm-bench: preparing %s instance %s\n' \
    "${family}" "${index}" >&2
  if [[ ${family} == lamevm ]]; then
    if [[ ${BENCHMARK_GUESTS_IDENTICAL} == true && ${index} -gt 1 ]]; then
      runner=$(readlink -f "${FAMILY_OUTPUT_DIR}/instances/1/runner")
      ln -s "${runner}" "${instance}/runner"
    else
      profile=${guest##*#}
      runner=$(
        nix build \
          --override-input supervm "${SUPERVM_SOURCE_FLAKE}" \
          --no-write-lock-file \
          --out-link "${instance}/runner" \
          --print-out-paths \
          "${BENCHMARK_FLAKE}#lameRunners.x86_64-linux.${profile}" \
          2>>"${prepare_log}"
      )
    fi
    [[ -x ${runner}/bin/microvm-run ]] ||
      fail "prepared LameVM runner is not executable"
    if [[ ${BENCHMARK_GUESTS_IDENTICAL} != true || ${index} -eq 1 ]]; then
      evict_tree_cache "${runner}"
    fi
  else
    upper=$(realpath -m "${instance}/upper")
    command_environment=(
      "XDG_RUNTIME_DIR=${FAMILY_RUNTIME_DIR}"
      "XDG_STATE_HOME=${FAMILY_OUTPUT_DIR}/state"
    )
    if [[ ${BENCHMARK_GUESTS_IDENTICAL} == true && ${index} -gt 1 ]]; then
      command_environment+=(
        "NIX_CONFIG=${NIX_CONFIG:-}"$'\n''offline = true'
      )
    fi
    env "${command_environment[@]}" "${SUPERVM_LAUNCHER}" prepare \
      --dax=always \
      "--profile=${guest}" \
      "${upper}" >>"${prepare_log}" 2>&1
    upper_hash=$(printf '%s' "${upper}" | sha256sum)
    upper_hash=${upper_hash%% *}
    runner="${FAMILY_OUTPUT_DIR}/state/supervm/prepared/${upper_hash}/runner"
    [[ -L ${runner} && -x ${runner}/bin/microvm-run ]] ||
      fail "SuperVM did not publish its prepared runner"
    if ((index == 1)); then
      sync_tree_files "${FAMILY_OUTPUT_DIR}/state/supervm/castore"
      sync_tree_files "${FAMILY_OUTPUT_DIR}/state/supervm/store"
      evict_tree_cache "${FAMILY_OUTPUT_DIR}/state/supervm/castore"
      evict_tree_cache "${FAMILY_OUTPUT_DIR}/state/supervm/store"
    elif [[ ${BENCHMARK_GUESTS_IDENTICAL} != true ]]; then
      sync_tree_files "${FAMILY_OUTPUT_DIR}/state/supervm/castore/blobs"
      evict_tree_cache "${FAMILY_OUTPUT_DIR}/state/supervm/castore/blobs"
    fi
    evict_tree_cache "${runner}"
  fi
  INSTANCE_IS_PREPARED[${index}]=true
}

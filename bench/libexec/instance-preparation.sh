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

evict_runner_own_cache() {
  local runner
  local file

  runner=$(readlink -f "$1")
  [[ -d ${runner} ]] || return 0
  while IFS= read -r -d '' file; do
    fadvise --advice dontneed "${file}"
  done < <(find "${runner}" -type f -print0)
}

evict_runner_host_cache() {
  local runner=$1
  local launch_script
  local reference
  local file

  launch_script=$(readlink -f "${runner}/bin/microvm-run")
  [[ -f ${launch_script} ]] ||
    fail "prepared runner launch script is not a regular file"

  # microvm-run names the host-side VMM, kernel, initrd, and optional store
  # image through its direct Nix references. Those artifacts live outside the
  # runner directory, so conditioning only the runner leaves cgroup page-cache
  # ownership dependent on earlier runs. Do not follow symlinked directories:
  # the guest system closure behind them is consumed from the store image, not
  # opened directly by the host VMM.
  {
    printf '%s\n' "${launch_script}"
    nix-store --query --references "${launch_script}"
  } | sort -u | while IFS= read -r reference; do
    if [[ -f ${reference} ]]; then
      fadvise --advice dontneed "${reference}"
    elif [[ -d ${reference} ]]; then
      while IFS= read -r -d '' file; do
        fadvise --advice dontneed "${file}"
      done < <(find "${reference}" -maxdepth 2 -type f -print0)
    fi
  done
}

prepare_instance_artifact() {
  local family=$1
  local index=$2
  local instance="${FAMILY_OUTPUT_DIR}/instances/${index}"
  local guest
  local runner
  local upper
  local upper_hash
  local prepare_log="${FAMILY_OUTPUT_DIR}/prepare-logs/${index}.log"
  local -a command_environment=()

  [[ ${INSTANCE_IS_PREPARED[${index}]:-} != true ]] || return 0
  mkdir -p "${instance}/runtime"
  guest=$(benchmark_variant_guest "${index}" "${BENCHMARK_PROFILE_FLAKE}")

  printf 'supervm-bench: preparing %s instance %s\n' \
    "${family}" "${index}" >&2
  if [[ ${family} == lamevm ]]; then
    if [[ ${BENCHMARK_GUESTS_IDENTICAL} == true && ${index} -gt 1 ]]; then
      runner=$(readlink -f "${FAMILY_OUTPUT_DIR}/instances/1/runner")
      ln -s "${runner}" "${instance}/runner"
    else
      "${LAMEVM_LAUNCHER}" prepare \
        "--profile=${guest}" \
        "${instance}" >>"${prepare_log}" 2>&1
      runner=$(readlink -f "${instance}/runner")
    fi
    [[ -x ${runner}/bin/microvm-run ]] ||
      fail "prepared LameVM runner is not executable"
    if [[ ${BENCHMARK_GUESTS_IDENTICAL} != true || ${index} -eq 1 ]]; then
      evict_tree_cache "${runner}"
      evict_runner_host_cache "${runner}"
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
    if [[ ${BENCHMARK_GUESTS_IDENTICAL} != true || ${index} -eq 1 ]]; then
      # Following the runner's system symlink conditions the shared guest
      # closure. Do that once for identical guests; later runners only have a
      # distinct, tiny launch script whose own cache still needs eviction.
      evict_tree_cache "${runner}"
      evict_runner_host_cache "${runner}"
    else
      evict_runner_own_cache "${runner}"
    fi
  fi
  INSTANCE_IS_PREPARED[${index}]=true
}

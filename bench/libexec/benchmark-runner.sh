#!/usr/bin/env bash
set -euo pipefail

BENCHMARK_HAS_LOAD=${BENCHMARK_HAS_LOAD:-}
BENCHMARK_GUESTS_IDENTICAL=${BENCHMARK_GUESTS_IDENTICAL:-false}
MAX_INSTANCE_COUNT=1024

fail() {
  printf 'supervm-bench: %s\n' "$*" >&2
  exit 1
}

show_usage() {
  printf 'usage: %s %s--cpus CPU_ID[,CPU_ID...] --output DIR [--family FAMILY]\n' \
    "${BENCHMARK_PROGRAM_NAME}" "${BENCHMARK_OBJECTIVE_USAGE:-}" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

benchmark_variant_requirements() {
  :
}

benchmark_variant_prepare_host() {
  :
}

benchmark_variant_prepare_instance() {
  INSTANCE_TAP_NAME=
  INSTANCE_IP_ADDRESS=
}

benchmark_variant_guest() {
  fail "benchmark variant did not select a guest"
}

benchmark_variant_wait_ready() {
  :
}

benchmark_variant_load() {
  :
}

benchmark_variant_remove_instance() {
  :
}

benchmark_variant_cleanup_host() {
  :
}

benchmark_objective_prepare_output() {
  :
}

benchmark_objective_environment() {
  :
}

benchmark_objective_record() {
  fail "benchmark objective did not provide a result schema"
}

benchmark_objective_run() {
  fail "benchmark objective did not provide a runner"
}

benchmark_objective_unavailable() {
  :
}

benchmark_objective_prepare_family() {
  :
}

benchmark_objective_prepare_instances() {
  prepare_instance_artifact "$1" 1
}

benchmark_objective_prepare_accounting() {
  :
}

benchmark_objective_finish() {
  :
}

create_family_runtime_path() {
  FAMILY_RUNTIME_DIR="/run/svbench-${BENCHMARK_RUN_ID}-${1}"
  [[ ! -e ${FAMILY_RUNTIME_DIR} && ! -L ${FAMILY_RUNTIME_DIR} ]] ||
    fail "runtime path already exists: ${FAMILY_RUNTIME_DIR}"
  ln -s "${FAMILY_OUTPUT_DIR}/runtime" "${FAMILY_RUNTIME_DIR}"
}

remove_family_runtime_path() {
  [[ -n ${FAMILY_RUNTIME_DIR:-} ]] || return 0
  [[ -L ${FAMILY_RUNTIME_DIR} ]] &&
    unlink "${FAMILY_RUNTIME_DIR}"
  FAMILY_RUNTIME_DIR=
}

read_family_memory_current() {
  printf '%s\n' "$(<"${FAMILY_MEMORY_CURRENT_FILE}")"
}

read_host_available_memory() {
  awk '$1 == "MemAvailable:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo
}

read_pressure_total() {
  local file=$1
  local stall=$2

  awk -v stall="${stall}" '
    $1 == stall {
      for (field = 2; field <= NF; field++) {
        if ($field ~ /^total=/) {
          sub(/^total=/, "", $field)
          print $field
          found = 1
          exit
        }
      }
    }
    END {
      if (!found) print 0
    }
  ' "${file}"
}

median_family_memory_current() {
  local reading
  local value

  : >"${FAMILY_OUTPUT_DIR}/median.tmp"
  for reading in 1 2 3 4 5; do
    read_family_memory_current >>"${FAMILY_OUTPUT_DIR}/median.tmp"
    ((reading == 5)) || sleep 1
  done
  sort -n "${FAMILY_OUTPUT_DIR}/median.tmp" -o "${FAMILY_OUTPUT_DIR}/median.tmp"
  value=$(sed -n '3p' "${FAMILY_OUTPUT_DIR}/median.tmp")
  rm -f "${FAMILY_OUTPUT_DIR}/median.tmp"
  printf '%s\n' "${value}"
}

settled_family_memory_current() {
  local previous
  local current
  local previous_deployment
  local current_deployment
  local difference
  local scale
  local deadline=$((SECONDS + MEMORY_STABILITY_TIMEOUT_SECONDS))

  previous=$(median_family_memory_current)
  while ((SECONDS < deadline)); do
    sleep 30
    current=$(median_family_memory_current)
    previous_deployment=$((previous - FAMILY_CGROUP_BASELINE_BYTES))
    current_deployment=$((current - FAMILY_CGROUP_BASELINE_BYTES))
    ((previous_deployment >= 0)) ||
      previous_deployment=$((-previous_deployment))
    ((current_deployment >= 0)) ||
      current_deployment=$((-current_deployment))
    difference=$((current_deployment - previous_deployment))
    ((difference >= 0)) || difference=$((-difference))
    scale=${current_deployment}
    ((previous_deployment <= scale)) || scale=${previous_deployment}
    ((scale > 0)) || scale=1
    if ((difference * 100 < scale)); then
      printf '%s\n' "${current}"
      return
    fi
    previous=${current}
  done
  fail "memory did not stabilize within ${MEMORY_STABILITY_TIMEOUT_SECONDS} seconds"
}

median_of_three() {
  local a=$1
  local b=$2
  local c=$3
  local swap

  if ((a > b)); then swap=${a}; a=${b}; b=${swap}; fi
  if ((b > c)); then swap=${b}; b=${c}; c=${swap}; fi
  if ((a > b)); then b=${a}; fi
  printf '%s\n' "${b}"
}

list_process_tree() {
  local pid
  local -a children=()
  local -a queue=("$1")

  while ((${#queue[@]} > 0)); do
    pid=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -d /proc/${pid} ]] || continue
    printf '%s\n' "${pid}"
    mapfile -t children < <(pgrep -P "${pid}" || true)
    queue+=("${children[@]}")
  done
}

find_vmm_pid() {
  local pid
  local executable
  local tree

  tree=$(list_process_tree "$1")
  while IFS= read -r pid; do
    executable=$(readlink "/proc/${pid}/exe" 2>/dev/null || true)
    if [[ ${executable} == */crosvm ]]; then
      printf '%s\n' "${pid}"
      return
    fi
  done <<<"${tree}"
}

wait_for_vmm_pid() {
  local launcher_pid=$1
  local deadline=$((SECONDS + 300))
  local pid
  local cwd

  while ((SECONDS < deadline)); do
    kill -0 "${launcher_pid}" 2>/dev/null ||
      fail "launcher ${launcher_pid} exited before crosvm started"
    pid=$(find_vmm_pid "${launcher_pid}")
    if [[ -n ${pid} ]]; then
      cwd=$(readlink "/proc/${pid}/cwd")
      if [[ -S ${cwd}/crosvm.sock ]]; then
        printf '%s\n' "${pid}"
        return
      fi
    fi
    sleep 1
  done
  fail "crosvm startup timed out"
}

snapshot_ksm() {
  KSM_PAGES_SHARED=$(<"${KSM_SYSFS_DIR}/pages_shared")
  KSM_PAGES_SHARING=$(<"${KSM_SYSFS_DIR}/pages_sharing")
  KSM_FULL_SCANS=$(<"${KSM_SYSFS_DIR}/full_scans")
}

snapshot_memory_events() {
  local event
  local value

  MEMORY_HIGH_EVENT_COUNT=0
  MEMORY_OOM_EVENT_COUNT=0
  MEMORY_OOM_KILL_EVENT_COUNT=0
  while read -r event value; do
    case ${event} in
      high) MEMORY_HIGH_EVENT_COUNT=${value} ;;
      oom) MEMORY_OOM_EVENT_COUNT=${value} ;;
      oom_kill) MEMORY_OOM_KILL_EVENT_COUNT=${value} ;;
    esac
  done <"/sys/fs/cgroup${FAMILY_CGROUP_PATH}/memory.events"
}

prepare_ksm_control() {
  local file

  [[ -d ${KSM_SYSFS_DIR} ]] || fail "KSM is unavailable"
  for file in run pages_shared pages_sharing full_scans; do
    [[ -r ${KSM_SYSFS_DIR}/${file} ]] || fail "cannot read KSM ${file}"
  done
  [[ -w ${KSM_SYSFS_DIR}/run ]] ||
    fail "KSM control requires write access to ${KSM_SYSFS_DIR}/run; run with sudo"

  KSM_ORIGINAL_RUN_STATE=$(<"${KSM_SYSFS_DIR}/run")
  case ${KSM_ORIGINAL_RUN_STATE} in
    0 | 1) ;;
    *) fail "KSM run state ${KSM_ORIGINAL_RUN_STATE} is not safe to take over" ;;
  esac
  KSM_CONTROL_ACTIVE=true
  printf '0\n' >"${KSM_SYSFS_DIR}/run"
  snapshot_ksm
}

ksm_pause() {
  [[ ${KSM_CONTROL_ACTIVE} == true ]] || return 0
  printf '0\n' >"${KSM_SYSFS_DIR}/run"
}

ksm_restore() {
  [[ ${KSM_CONTROL_ACTIVE} == true ]] || return 0
  printf '%s\n' "${KSM_ORIGINAL_RUN_STATE}" >"${KSM_SYSFS_DIR}/run"
  KSM_CONTROL_ACTIVE=false
}

ksm_merge_until_stable() {
  local family=$1
  local initial_scans
  local previous
  local current
  local scans
  local difference
  local scale
  local deadline

  [[ ${family} == supervm ]] || return 0
  initial_scans=$(<"${KSM_SYSFS_DIR}/full_scans")
  previous=$(<"${KSM_SYSFS_DIR}/pages_sharing")
  deadline=$((SECONDS + KSM_TIMEOUT_SECONDS))
  printf 'supervm-bench: running KSM after settle\n' >&2
  printf '1\n' >"${KSM_SYSFS_DIR}/run"

  while ((SECONDS < deadline)); do
    sleep 30
    current=$(<"${KSM_SYSFS_DIR}/pages_sharing")
    scans=$(<"${KSM_SYSFS_DIR}/full_scans")
    difference=$((current - previous))
    ((difference >= 0)) || difference=$((-difference))
    scale=${current}
    ((previous <= scale)) || scale=${previous}
    if ((scans > initial_scans)) &&
      ((difference == 0 || (scale > 0 && difference * 100 < scale))); then
      ksm_pause
      snapshot_ksm
      return
    fi
    previous=${current}
  done

  ksm_pause
  fail "KSM did not stabilize within ${KSM_TIMEOUT_SECONDS} seconds"
}

stop_last_instance() {
  local last
  local unit

  last=$((${#LAUNCHER_PIDS[@]} - 1))
  unit=${INSTANCE_UNIT_NAMES[${last}]}
  systemctl stop "${unit}" 2>/dev/null || true
  systemctl kill --kill-whom=all --signal=KILL "${unit}" 2>/dev/null || true
  benchmark_variant_remove_instance "${INSTANCE_TAP_NAMES[${last}]}"
  unset 'LAUNCHER_PIDS[last]' 'VMM_PIDS[last]' 'INSTANCE_IP_ADDRESSES[last]'
  unset 'INSTANCE_TAP_NAMES[last]' 'INSTANCE_UNIT_NAMES[last]'
  LAUNCHER_PIDS=("${LAUNCHER_PIDS[@]}")
  VMM_PIDS=("${VMM_PIDS[@]}")
  INSTANCE_IP_ADDRESSES=("${INSTANCE_IP_ADDRESSES[@]}")
  INSTANCE_TAP_NAMES=("${INSTANCE_TAP_NAMES[@]}")
  INSTANCE_UNIT_NAMES=("${INSTANCE_UNIT_NAMES[@]}")
}

stop_all_instances() {
  while ((${#LAUNCHER_PIDS[@]} > 0)); do
    stop_last_instance
  done
}

cleanup_benchmark() {
  local status=$?

  trap - EXIT INT TERM
  set +e
  ksm_pause
  stop_all_instances
  if [[ -n ${FAMILY_OUTPUT_DIR} ]]; then
    rm -f "${FAMILY_OUTPUT_DIR}/median.tmp"
  fi
  if [[ -n ${PENDING_INSTANCE_UNIT} ]]; then
    systemctl stop "${PENDING_INSTANCE_UNIT}" 2>/dev/null || true
    PENDING_INSTANCE_UNIT=
  fi
  if [[ -n ${PENDING_INSTANCE_TAP_NAME} ]]; then
    benchmark_variant_remove_instance "${PENDING_INSTANCE_TAP_NAME}"
    PENDING_INSTANCE_TAP_NAME=
  fi
  remove_family_cgroup
  remove_family_runtime_path
  benchmark_variant_cleanup_host
  ksm_restore
  exit "${status}"
}

wait_for_unit_main_pid() {
  local unit=$1
  local deadline=$((SECONDS + 30))
  local state
  local pid

  while ((SECONDS < deadline)); do
    state=$(systemctl show --property=ActiveState --value "${unit}")
    pid=$(systemctl show --property=MainPID --value "${unit}")
    if [[ ${pid} =~ ^[1-9][0-9]*$ ]] && kill -0 "${pid}" 2>/dev/null; then
      printf '%s\n' "${pid}"
      return
    fi
    [[ ${state} != failed && ${state} != inactive ]] ||
      fail "VM unit ${unit} failed to start"
    sleep 1
  done
  fail "VM unit ${unit} startup timed out"
}


launch_instance() {
  local family=$1
  local index
  local instance
  local unit
  local main_pid
  local vmm
  local runner
  local -a command=()

  index=$((${#LAUNCHER_PIDS[@]} + 1))
  instance="${FAMILY_OUTPUT_DIR}/instances/${index}"
  [[ ${INSTANCE_IS_PREPARED[${index}]:-} == true ]] ||
    fail "${family} instance ${index} was not prepared"
  INSTANCE_TAP_NAME=
  INSTANCE_IP_ADDRESS=
  benchmark_variant_prepare_instance "${index}"
  PENDING_INSTANCE_TAP_NAME=${INSTANCE_TAP_NAME}

  if [[ ${family} == lamevm ]]; then
    runner=$(readlink -f "${instance}/runner")
    command+=("${runner}/bin/microvm-run")
  else
    command+=(
      "${SUPERVM_LAUNCHER}"
      launch
      "${instance}/upper"
    )
  fi

  unit="svbench${BENCHMARK_RUN_ID}${family}vm${index}.service"
  PENDING_INSTANCE_UNIT=${unit}
  systemd-run \
    --quiet \
    --no-block \
    --collect \
    --service-type=exec \
    --unit="${unit%.service}" \
    --slice="${FAMILY_CGROUP_SLICE}" \
    --setenv="PATH=${PATH}" \
    --setenv="XDG_RUNTIME_DIR=${FAMILY_RUNTIME_DIR}" \
    --setenv="XDG_STATE_HOME=${FAMILY_OUTPUT_DIR}/state" \
    --property=KillMode=control-group \
    --property=TimeoutStopSec=20s \
    --property="WorkingDirectory=${instance}/runtime" \
    --property=StandardInput=null \
    --property="StandardOutput=append:${FAMILY_OUTPUT_DIR}/logs/${index}.log" \
    --property="StandardError=append:${FAMILY_OUTPUT_DIR}/logs/${index}.log" \
    "${command[@]}"
  main_pid=$(wait_for_unit_main_pid "${unit}")
  assert_process_in_family_cgroup "${main_pid}" "launcher"
  LAUNCHER_PIDS+=("${main_pid}")
  INSTANCE_UNIT_NAMES+=("${unit}")
  INSTANCE_TAP_NAMES+=("${INSTANCE_TAP_NAME}")
  INSTANCE_IP_ADDRESSES+=("${INSTANCE_IP_ADDRESS}")
  PENDING_INSTANCE_TAP_NAME=
  PENDING_INSTANCE_UNIT=
  vmm=$(wait_for_vmm_pid "${main_pid}")
  assert_process_in_family_cgroup "${vmm}" "VMM"
  VMM_PIDS+=("${vmm}")
  benchmark_variant_wait_ready "${INSTANCE_IP_ADDRESS}"
}

record_process_memory() {
  local count=${#LAUNCHER_PIDS[@]}
  local position
  local mappings

  for position in "${!LAUNCHER_PIDS[@]}"; do
    mappings=$(
      "${PROCESS_MEMORY_REPORTER}" "${LAUNCHER_PIDS[${position}]}"
    )
    printf '%s\t%s\t%s\t%s\n' \
      "${count}" "$((position + 1))" "${VMM_PIDS[${position}]}" \
      "${mappings}" >>"${PROCESS_MEMORY_FILE}"
  done
}

record_checkpoint() {
  local family=$1
  local unmerged_idle
  local idle
  local unmerged_post
  local post
  local unmerged_peak
  local available
  local host_pressure_some
  local host_pressure_full
  local cgroup_pressure_some
  local cgroup_pressure_full

  unmerged_idle=$(settled_family_memory_current)
  idle=${unmerged_idle}
  if [[ ${family} == supervm ]]; then
    ksm_merge_until_stable "${family}"
    idle=$(settled_family_memory_current)
  fi

  unmerged_post=${idle}
  post=${idle}
  benchmark_variant_load
  if [[ ${BENCHMARK_HAS_LOAD} == true ]]; then
    unmerged_post=$(settled_family_memory_current)
    post=${unmerged_post}
    if [[ ${family} == supervm ]]; then
      ksm_merge_until_stable "${family}"
      post=$(settled_family_memory_current)
    fi
  fi

  UNMERGED_IDLE_TOTAL_BYTES=$((unmerged_idle - FAMILY_CGROUP_BASELINE_BYTES))
  IDLE_TOTAL_BYTES=$((idle - FAMILY_CGROUP_BASELINE_BYTES))
  UNMERGED_POST_LOAD_TOTAL_BYTES=$((unmerged_post - FAMILY_CGROUP_BASELINE_BYTES))
  POST_LOAD_TOTAL_BYTES=$((post - FAMILY_CGROUP_BASELINE_BYTES))
  ((UNMERGED_IDLE_TOTAL_BYTES >= 0)) || UNMERGED_IDLE_TOTAL_BYTES=0
  ((IDLE_TOTAL_BYTES >= 0)) || IDLE_TOTAL_BYTES=0
  ((UNMERGED_POST_LOAD_TOTAL_BYTES >= 0)) ||
    UNMERGED_POST_LOAD_TOTAL_BYTES=0
  ((POST_LOAD_TOTAL_BYTES >= 0)) || POST_LOAD_TOTAL_BYTES=0

  unmerged_peak=${unmerged_idle}
  ((unmerged_post <= unmerged_peak)) || unmerged_peak=${unmerged_post}
  UNMERGED_PEAK_TOTAL_BYTES=$((unmerged_peak - FAMILY_CGROUP_BASELINE_BYTES))
  ((UNMERGED_PEAK_TOTAL_BYTES >= 0)) || UNMERGED_PEAK_TOTAL_BYTES=0
  TOTAL_BYTES=${POST_LOAD_TOTAL_BYTES}
  available=$(read_host_available_memory)
  host_pressure_some=$(read_pressure_total /proc/pressure/memory some)
  host_pressure_full=$(read_pressure_total /proc/pressure/memory full)
  cgroup_pressure_some=$(read_pressure_total "${FAMILY_MEMORY_PRESSURE_FILE}" some)
  cgroup_pressure_full=$(read_pressure_total "${FAMILY_MEMORY_PRESSURE_FILE}" full)
  snapshot_ksm
  snapshot_memory_events
  if [[ ${BENCHMARK_HAS_LOAD} == true ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${#LAUNCHER_PIDS[@]}" "${UNMERGED_IDLE_TOTAL_BYTES}" \
      "${IDLE_TOTAL_BYTES}" "${UNMERGED_POST_LOAD_TOTAL_BYTES}" \
      "${POST_LOAD_TOTAL_BYTES}" "${UNMERGED_PEAK_TOTAL_BYTES}" \
      "${available}" "${host_pressure_some}" "${host_pressure_full}" \
      "${cgroup_pressure_some}" "${cgroup_pressure_full}" \
      "${KSM_PAGES_SHARED}" "${KSM_PAGES_SHARING}" \
      "${KSM_FULL_SCANS}" "${MEMORY_HIGH_EVENT_COUNT}" \
      "${MEMORY_OOM_EVENT_COUNT}" "${MEMORY_OOM_KILL_EVENT_COUNT}" \
      >>"${CHECKPOINTS_FILE}"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${#LAUNCHER_PIDS[@]}" "${UNMERGED_IDLE_TOTAL_BYTES}" \
      "${IDLE_TOTAL_BYTES}" "${available}" \
      "${host_pressure_some}" "${host_pressure_full}" \
      "${cgroup_pressure_some}" "${cgroup_pressure_full}" \
      "${KSM_PAGES_SHARED}" "${KSM_PAGES_SHARING}" "${KSM_FULL_SCANS}" \
      "${MEMORY_HIGH_EVENT_COUNT}" "${MEMORY_OOM_EVENT_COUNT}" \
      "${MEMORY_OOM_KILL_EVENT_COUNT}" >>"${CHECKPOINTS_FILE}"
  fi
  record_process_memory
}

launch_instance_batch() {
  local family=$1
  local amount=$2
  local headroom=${LAUNCH_HEADROOM_BYTES}
  local added
  local available

  LAUNCHED_INSTANCE_COUNT=0
  LAUNCH_BLOCKED_BY_HOST_RESERVE=false
  ((headroom > 0)) || headroom=$((512 * 1024 * 1024))
  for ((added = 0; added < amount; added++)); do
    available=$(read_host_available_memory)
    if ((available < HOST_RESERVE_BYTES + headroom)); then
      LAUNCH_BLOCKED_BY_HOST_RESERVE=true
      break
    fi
    prepare_instance_artifact \
      "${family}" "$((${#LAUNCHER_PIDS[@]} + 1))"
    launch_instance "${family}"
    LAUNCHED_INSTANCE_COUNT=$((LAUNCHED_INSTANCE_COUNT + 1))
  done
}

record_family_summary() {
  benchmark_objective_record "$1"
}

run_family() {
  local family=$1
  local baseline_host_pressure_some
  local baseline_host_pressure_full
  local baseline_cgroup_pressure_some
  local baseline_cgroup_pressure_full

  benchmark_objective_prepare_family
  FAMILY_OUTPUT_DIR="${OUTPUT_DIR}/${family}"
  CHECKPOINTS_FILE="${FAMILY_OUTPUT_DIR}/checkpoints.tsv"
  PROCESS_MEMORY_FILE="${FAMILY_OUTPUT_DIR}/process-memory.tsv"
  mkdir -p "${FAMILY_OUTPUT_DIR}"/{instances,logs,prepare-logs,runtime,state}
  create_family_runtime_path "${family}"
  LAUNCHER_PIDS=()
  VMM_PIDS=()
  INSTANCE_IP_ADDRESSES=()
  INSTANCE_TAP_NAMES=()
  INSTANCE_UNIT_NAMES=()
  INSTANCE_IS_PREPARED=()
  benchmark_objective_prepare_instances "${family}"
  create_family_cgroup "${family}"
  benchmark_objective_prepare_accounting
  if [[ ${BENCHMARK_HAS_LOAD} == true ]]; then
    printf 'instance_count\tunmerged_idle_bytes\tidle_bytes\tunmerged_post_load_bytes\tpost_load_bytes\tpeak_unmerged_bytes\thost_available_bytes\thost_memory_psi_some_total_us\thost_memory_psi_full_total_us\tcgroup_memory_psi_some_total_us\tcgroup_memory_psi_full_total_us\tksm_pages_shared\tksm_pages_sharing\tksm_full_scans\tmemory_high_events\tmemory_oom_events\tmemory_oom_kill_events\n' \
      >"${CHECKPOINTS_FILE}"
  else
    printf 'instance_count\tunmerged_bytes\tsettled_bytes\thost_available_bytes\thost_memory_psi_some_total_us\thost_memory_psi_full_total_us\tcgroup_memory_psi_some_total_us\tcgroup_memory_psi_full_total_us\tksm_pages_shared\tksm_pages_sharing\tksm_full_scans\tmemory_high_events\tmemory_oom_events\tmemory_oom_kill_events\n' \
      >"${CHECKPOINTS_FILE}"
  fi
  printf 'instance_count\tinstance_index\tvmm_pid\tguest_memfd_pss_bytes\tdax_pss_bytes\tother_crosvm_pss_bytes\tcrosvm_pss_bytes\tprocess_tree_pss_bytes\n' \
    >"${PROCESS_MEMORY_FILE}"

  FAMILY_CGROUP_BASELINE_BYTES=$(median_family_memory_current)
  baseline_host_pressure_some=$(read_pressure_total /proc/pressure/memory some)
  baseline_host_pressure_full=$(read_pressure_total /proc/pressure/memory full)
  baseline_cgroup_pressure_some=$(
    read_pressure_total "${FAMILY_MEMORY_PRESSURE_FILE}" some
  )
  baseline_cgroup_pressure_full=$(
    read_pressure_total "${FAMILY_MEMORY_PRESSURE_FILE}" full
  )
  {
    printf 'cgroup=%s\n' "${FAMILY_CGROUP_PATH}"
    printf 'effective_cpu_ids=%s\n' "${EFFECTIVE_CPU_IDS}"
    printf 'cgroup_memory_current_bytes=%s\n' \
      "${FAMILY_CGROUP_BASELINE_BYTES}"
    printf 'host_memory_psi_some_total_us=%s\n' \
      "${baseline_host_pressure_some}"
    printf 'host_memory_psi_full_total_us=%s\n' \
      "${baseline_host_pressure_full}"
    printf 'cgroup_memory_psi_some_total_us=%s\n' \
      "${baseline_cgroup_pressure_some}"
    printf 'cgroup_memory_psi_full_total_us=%s\n' \
      "${baseline_cgroup_pressure_full}"
  } >"${FAMILY_OUTPUT_DIR}/baseline.txt"
  TOTAL_BYTES=0
  IDLE_TOTAL_BYTES=0
  POST_LOAD_TOTAL_BYTES=0
  UNMERGED_IDLE_TOTAL_BYTES=0
  UNMERGED_POST_LOAD_TOTAL_BYTES=0
  UNMERGED_PEAK_TOTAL_BYTES=0
  FIRST_INSTANCE_TOTAL_BYTES=0
  FIRST_INSTANCE_IDLE_BYTES=0
  FIRST_INSTANCE_UNMERGED_PEAK_BYTES=0
  MARGINAL_BYTES=0
  LAUNCH_HEADROOM_BYTES=0
  launch_instance_batch "${family}" 1
  if ((LAUNCHED_INSTANCE_COUNT == 0)); then
    STOP_REASON=host_safety_reserve
    benchmark_objective_unavailable
    record_family_summary "${family}"
    return
  fi
  record_checkpoint "${family}"
  FIRST_INSTANCE_TOTAL_BYTES=${TOTAL_BYTES}
  FIRST_INSTANCE_IDLE_BYTES=${IDLE_TOTAL_BYTES}
  FIRST_INSTANCE_UNMERGED_PEAK_BYTES=${UNMERGED_PEAK_TOTAL_BYTES}
  MARGINAL_BYTES=${TOTAL_BYTES}
  LAUNCH_HEADROOM_BYTES=${UNMERGED_PEAK_TOTAL_BYTES}
  benchmark_objective_run "${family}"
}

validate_cpu_selection() {
  local cpu
  local path
  local core
  local package
  local class
  local expected=
  local -a selected=()
  local -A cpus=()
  local -A cores=()

  [[ ${TARGET_CPU_IDS} =~ ^[0-9]+(,[0-9]+)*$ ]] ||
    fail "--cpus requires comma-separated Linux CPU IDs"
  IFS=, read -r -a selected <<<"${TARGET_CPU_IDS}"
  for cpu in "${selected[@]}"; do
    path=/sys/devices/system/cpu/cpu"${cpu}"
    [[ -z ${cpus[${cpu}]+set} && -d ${path} ]] ||
      fail "invalid CPU ${cpu}"
    cpus[${cpu}]="set"
    if [[ -r ${path}/online ]]; then
      [[ $(<"${path}/online") == 1 ]] || fail "CPU ${cpu} is offline"
    fi
    core=$(<"${path}/topology/core_id")
    package=$(<"${path}/topology/physical_package_id")
    [[ -z ${cores["${package}:${core}"]+set} ]] ||
      fail "selected CPUs contain SMT siblings"
    cores["${package}:${core}"]="set"
    class=unknown
    if [[ -r ${path}/cpu_capacity ]]; then
      class=$(<"${path}/cpu_capacity")
    elif [[ -r ${path}/cpufreq/cpuinfo_max_freq ]]; then
      class=$(<"${path}/cpufreq/cpuinfo_max_freq")
    fi
    if [[ -z ${expected} ]]; then
      expected=${class}
    elif [[ ${class} != "${expected}" ]]; then
      fail "selected CPUs are not homogeneous"
    fi
  done
}

run_benchmark() {
  BENCHMARK_PROGRAM_NAME=${BENCHMARK_PROGRAM_NAME:-$0}
  [[ -n ${BENCHMARK_MODE:-} ]] ||
    fail "benchmark variant did not set BENCHMARK_MODE"
  [[ ${BENCHMARK_HAS_LOAD:-} == true ||
    ${BENCHMARK_HAS_LOAD:-} == false ]] ||
    fail "benchmark variant did not set BENCHMARK_HAS_LOAD"
  [[ ${BENCHMARK_GUESTS_IDENTICAL} == true ||
    ${BENCHMARK_GUESTS_IDENTICAL} == false ]] ||
    fail "benchmark variant set an invalid BENCHMARK_GUESTS_IDENTICAL"
  [[ -n ${BENCHMARK_OBJECTIVE:-} ]] ||
    fail "benchmark objective did not set BENCHMARK_OBJECTIVE"
  local libexec_dir
  local benchmark_dir
  local supervm_package
  local command
  local family
  local -a families=()

  libexec_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  benchmark_dir=$(cd -- "${libexec_dir}/.." && pwd)
  TARGET_CPU_IDS=
  OUTPUT_DIR=
  SELECTED_FAMILY=both
  while (($# > 0)); do
    case $1 in
      --cpus) (($# > 1)) || show_usage; TARGET_CPU_IDS=$2; shift 2 ;;
      --output) (($# > 1)) || show_usage; OUTPUT_DIR=$2; shift 2 ;;
      --family) (($# > 1)) || show_usage; SELECTED_FAMILY=$2; shift 2 ;;
      -h | --help) show_usage ;;
      *) show_usage ;;
    esac
  done
  [[ -n ${TARGET_CPU_IDS} && -n ${OUTPUT_DIR} ]] || show_usage
  case ${SELECTED_FAMILY} in
    both) families=(lamevm supervm) ;;
    lamevm | supervm) families=("${SELECTED_FAMILY}") ;;
    *) show_usage ;;
  esac

  for command in \
    awk env fadvise find flock ln nix pgrep readlink realpath sed sha256sum sort \
    sync systemctl systemd-run tr uname unlink; do
    require_command "${command}"
  done
  [[ -r /proc/pressure/memory ]] ||
    fail "kernel memory pressure accounting is unavailable"
  benchmark_variant_requirements
  validate_cpu_selection

  OUTPUT_DIR=$(realpath -m "${OUTPUT_DIR}")
  case ${OUTPUT_DIR}/ in
    "${benchmark_dir}/"*)
      fail "--output must be outside the benchmark flake directory"
      ;;
  esac
  mkdir -p "${OUTPUT_DIR}"
  [[ ! -e ${OUTPUT_DIR}/lamevm && ! -e ${OUTPUT_DIR}/supervm ]] ||
    fail "output already contains benchmark data"
  BENCHMARK_FLAKE=${SUPERVM_BENCH_FLAKE:-path:${benchmark_dir}}
  SUPERVM_SOURCE_FLAKE=${SUPERVM_SOURCE_FLAKE:-path:${benchmark_dir}/..}
  PROCESS_MEMORY_REPORTER="${libexec_dir}/process-memory-report.sh"
  HOST_RESERVE_BYTES=$((2 * 1024 * 1024 * 1024))
  KSM_SYSFS_DIR=/sys/kernel/mm/ksm
  KSM_TIMEOUT_SECONDS=600
  MEMORY_STABILITY_TIMEOUT_SECONDS=180

  supervm_package=$(
    nix build \
      --override-input supervm "${SUPERVM_SOURCE_FLAKE}" \
      --no-write-lock-file \
      --no-link \
      --print-out-paths \
      "${BENCHMARK_FLAKE}#supervm"
  )
  SUPERVM_LAUNCHER="${supervm_package}/bin/supervm"
  [[ -x ${SUPERVM_LAUNCHER} ]] || fail "SuperVM launcher build failed"

  declare -ga LAUNCHER_PIDS=()
  declare -ga VMM_PIDS=()
  declare -ga INSTANCE_IP_ADDRESSES=()
  declare -ga INSTANCE_TAP_NAMES=()
  declare -ga INSTANCE_UNIT_NAMES=()
  declare -ga INSTANCE_IS_PREPARED=()
  INSTANCE_TAP_NAME=
  INSTANCE_IP_ADDRESS=
  PENDING_INSTANCE_TAP_NAME=
  PENDING_INSTANCE_UNIT=
  FAMILY_OUTPUT_DIR=
  FAMILY_RUNTIME_DIR=
  CHECKPOINTS_FILE=
  PROCESS_MEMORY_FILE=
  FAMILY_CGROUP_BASELINE_BYTES=0
  TOTAL_BYTES=0
  IDLE_TOTAL_BYTES=0
  POST_LOAD_TOTAL_BYTES=0
  UNMERGED_IDLE_TOTAL_BYTES=0
  UNMERGED_POST_LOAD_TOTAL_BYTES=0
  UNMERGED_PEAK_TOTAL_BYTES=0
  MARGINAL_BYTES=0
  LAUNCH_HEADROOM_BYTES=0
  STOP_REASON=
  LAUNCHED_INSTANCE_COUNT=0
  LAUNCH_BLOCKED_BY_HOST_RESERVE=false
  KSM_CONTROL_ACTIVE=false
  KSM_ORIGINAL_RUN_STATE=
  KSM_PAGES_SHARED=0
  KSM_PAGES_SHARING=0
  KSM_FULL_SCANS=0
  MEMORY_HIGH_EVENT_COUNT=0
  MEMORY_OOM_EVENT_COUNT=0
  MEMORY_OOM_KILL_EVENT_COUNT=0
  FIRST_INSTANCE_TOTAL_BYTES=0
  FIRST_INSTANCE_IDLE_BYTES=0
  FIRST_INSTANCE_UNMERGED_PEAK_BYTES=0
  BENCHMARK_RUN_ID=$$
  FAMILY_CGROUP_SLICE=
  FAMILY_CGROUP_PATH=
  FAMILY_MEMORY_CURRENT_FILE=
  FAMILY_MEMORY_PRESSURE_FILE=
  FAMILY_CPUSET_EFFECTIVE_FILE=
  EFFECTIVE_CPU_IDS=

  trap cleanup_benchmark EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 9>/run/lock/supervm-bench-ksm.lock
  flock --nonblock 9 || fail "another benchmark owns host KSM control"
  prepare_ksm_control

  {
    printf 'mode=%s\n' "${BENCHMARK_MODE}"
    printf 'objective=%s\n' "${BENCHMARK_OBJECTIVE}"
    printf 'family_selection=%s\n' "${SELECTED_FAMILY}"
    benchmark_objective_environment
    printf 'target_cpu_ids=%s\n' "${TARGET_CPU_IDS}"
    if [[ -r /sys/devices/system/cpu/isolated ]]; then
      printf 'kernel_isolated_cpu_ids=%s\n' \
        "$(< /sys/devices/system/cpu/isolated)"
    fi
    if [[ -r /sys/devices/system/cpu/nohz_full ]]; then
      printf 'kernel_nohz_full_cpu_ids=%s\n' \
        "$(< /sys/devices/system/cpu/nohz_full)"
    fi
    printf 'ksm_original_run=%s\n' "${KSM_ORIGINAL_RUN_STATE}"
    for command in pages_to_scan sleep_millisecs advisor_mode smart_scan; do
      if [[ -r ${KSM_SYSFS_DIR}/${command} ]]; then
        printf 'ksm_%s=%s\n' "${command}" "$(<"${KSM_SYSFS_DIR}/${command}")"
      fi
    done
    printf 'kernel='
    uname -r
    awk '$1 == "MemTotal:" { print "mem_total_bytes=" $2 * 1024 }' /proc/meminfo
    awk '$1 == "SwapTotal:" { print "swap_total_bytes=" $2 * 1024 }' /proc/meminfo
    if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
      printf 'transparent_hugepage=%s\n' \
        "$(< /sys/kernel/mm/transparent_hugepage/enabled)"
    fi
    printf 'supervm=%s\n' "${SUPERVM_LAUNCHER}"
  } >"${OUTPUT_DIR}/environment.txt"

  benchmark_objective_prepare_output
  benchmark_variant_prepare_host
  for family in "${families[@]}"; do
    run_family "${family}"
    remove_family_cgroup
    remove_family_runtime_path
  done
  benchmark_objective_finish
}

#!/usr/bin/env bash
set -euo pipefail

if (($# != 5)); then
  printf 'usage: %s CGROUP_ROOT DAX_BACKING_DIR INSTANCE_COUNT CGROUP_OUTPUT PROCESS_OUTPUT\n' \
    "$0" >&2
  exit 2
fi

fail() {
  printf 'process-memory-report: %s\n' "$*" >&2
  exit 1
}

read_frozen_state() {
  local name
  local value

  while read -r name value; do
    if [[ ${name} == frozen ]]; then
      printf '%s\n' "${value}"
      return
    fi
  done <"${CGROUP_ROOT}/cgroup.events"
  printf '0\n'
}

thaw_cgroup() {
  [[ ${CGROUP_IS_FROZEN} == true ]] || return 0
  printf '0\n' >"${CGROUP_ROOT}/cgroup.freeze"
  CGROUP_IS_FROZEN=false
}

freeze_cgroup() {
  local attempt
  local frozen_state

  [[ -w ${CGROUP_ROOT}/cgroup.freeze && -r ${CGROUP_ROOT}/cgroup.events ]] ||
    fail "cgroup freezer is unavailable at ${CGROUP_ROOT}"
  printf '1\n' >"${CGROUP_ROOT}/cgroup.freeze"
  CGROUP_IS_FROZEN=true
  for ((attempt = 0; attempt < 100; attempt++)); do
    frozen_state=$(read_frozen_state)
    if [[ ${frozen_state} == 1 ]]; then
      return
    fi
    sleep 0.01
  done
  fail "cgroup did not freeze: ${CGROUP_ROOT}"
}

list_cgroup_pids() {
  local procs_file
  local pid
  local procs_files_output
  local -a procs_files=()
  local -A seen=()

  procs_files_output=$(find "${CGROUP_ROOT}" -type f -name cgroup.procs -print)
  mapfile -t procs_files <<<"${procs_files_output}"
  for procs_file in "${procs_files[@]}"; do
    while read -r pid; do
      [[ ${pid} =~ ^[1-9][0-9]*$ ]] || continue
      seen["${pid}"]="set"
    done <"${procs_file}"
  done

  printf '%s\n' "${!seen[@]}" | sort -n
}

read_cgroup_memory_stat() {
  awk '
    $1 == "anon" { anon = $2 }
    $1 == "file" { file = $2 }
    $1 == "shmem" { shmem = $2 }
    $1 == "kernel" { kernel = $2 }
    $1 == "slab" { slab = $2 }
    $1 == "pagetables" { pagetables = $2 }
    $1 == "sock" { sock = $2 }
    END {
      printf "%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n",
        anon, file, shmem, kernel, slab, pagetables, sock
    }
  ' "${CGROUP_ROOT}/memory.stat"
}

read_mapping_memory() {
  local smaps=$1

  awk -v dax_backing_dir="${DAX_BACKING_DIR}" '
    /^[[:xdigit:]]+-[[:xdigit:]]+ / {
      kind = "other"
      if ($0 ~ /memfd:crosvm_guest/) {
        kind = "guest"
      } else if (dax_backing_dir != "" && index($0, dax_backing_dir) != 0) {
        kind = "dax"
      }
      next
    }
    $1 == "Rss:" { rss[kind] += $2 * 1024 }
    $1 == "Pss:" { pss[kind] += $2 * 1024 }
    END {
      printf "%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n",
        rss["guest"], pss["guest"], rss["dax"], pss["dax"],
        rss["other"], pss["other"]
    }
  ' "${smaps}"
}

classify_process() {
  local executable=$1
  local command_line=$2

  if [[ ${executable} == */crosvm ]]; then
    PROCESS_ROLE=vmm
  elif [[ ${command_line} == *"snix store virtiofs"* ]]; then
    PROCESS_ROLE=virtiofs
  elif [[ ${command_line} == *"snix store daemon"* ]]; then
    PROCESS_ROLE=shared-store-daemon
  elif [[ ${command_line} == *"snix nix-daemon"* ]]; then
    PROCESS_ROLE=shared-nix-daemon
  elif [[ ${executable} == */socat ]]; then
    PROCESS_ROLE=shared-metadata-bridge
  elif [[ ${command_line} == *"/bin/supervm"* ||
    ${command_line} == *"/bin/lamevm"* ]]; then
    PROCESS_ROLE=launcher
  else
    PROCESS_ROLE=other
  fi
}

classify_scope() {
  local process_cgroup=$1

  INSTANCE_INDEX=0
  PROCESS_SCOPE=family-shared
  if [[ ${process_cgroup} =~ vm([1-9][0-9]*)\.service($|/) ]]; then
    INSTANCE_INDEX=${BASH_REMATCH[1]}
    PROCESS_SCOPE=instance
  fi
  case ${PROCESS_ROLE} in
    shared-*)
      INSTANCE_INDEX=0
      PROCESS_SCOPE=family-shared
      ;;
    *) ;;
  esac
}

CGROUP_ROOT=$1
DAX_BACKING_DIR=$2
INSTANCE_COUNT=$3
CGROUP_MEMORY_FILE=$4
PROCESS_MEMORY_FILE=$5
CGROUP_IS_FROZEN=false
PROCESS_ROLE=
PROCESS_SCOPE=
INSTANCE_INDEX=0
self_cgroup=
self_cgroup_root=
declare -a process_rows=()

[[ ${INSTANCE_COUNT} =~ ^[1-9][0-9]*$ ]] ||
  fail "invalid instance count: ${INSTANCE_COUNT}"
[[ -f ${CGROUP_MEMORY_FILE} && -w ${CGROUP_MEMORY_FILE} ]] ||
  fail "invalid cgroup output file: ${CGROUP_MEMORY_FILE}"
[[ -f ${PROCESS_MEMORY_FILE} && -w ${PROCESS_MEMORY_FILE} ]] ||
  fail "invalid process output file: ${PROCESS_MEMORY_FILE}"
self_cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)
self_cgroup_root="/sys/fs/cgroup${self_cgroup}"

[[ -d ${CGROUP_ROOT} && -r ${CGROUP_ROOT}/memory.current &&
  -r ${CGROUP_ROOT}/memory.peak &&
  -r ${CGROUP_ROOT}/memory.stat ]] ||
  fail "invalid cgroup root: ${CGROUP_ROOT}"
CGROUP_ROOT=${CGROUP_ROOT%/}
[[ ${self_cgroup_root} != "${CGROUP_ROOT}" &&
  ${self_cgroup_root} != "${CGROUP_ROOT}/"* ]] ||
  fail "reporter must run outside the cgroup it measures"

trap thaw_cgroup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
freeze_cgroup

cgroup_memory_current_bytes=$(<"${CGROUP_ROOT}/memory.current")
cgroup_memory_peak_bytes=$(<"${CGROUP_ROOT}/memory.peak")
cgroup_memory_stat=$(read_cgroup_memory_stat)
pids=$(list_cgroup_pids)

while read -r pid; do
  [[ -n ${pid} ]] || continue
  [[ -r /proc/${pid}/smaps && -r /proc/${pid}/cgroup ]] ||
    fail "cannot inspect process ${pid} in frozen cgroup"
  executable=$(readlink "/proc/${pid}/exe" 2>/dev/null || true)
  [[ -n ${executable} ]] || executable='[unavailable]'
  command_line=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
  process_cgroup=$(awk -F: '$1 == "0" { print $3 }' "/proc/${pid}/cgroup")
  classify_process "${executable}" "${command_line}"
  classify_scope "${process_cgroup}"
  row=$(read_mapping_memory "/proc/${pid}/smaps")
  IFS=$'\t' read -r \
    guest_rss_bytes guest_pss_bytes dax_rss_bytes dax_pss_bytes \
    other_rss_bytes other_pss_bytes <<<"${row}"

  printf -v process_row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${INSTANCE_COUNT}" "${pid}" "${INSTANCE_INDEX}" \
    "${PROCESS_SCOPE}" "${PROCESS_ROLE}" \
    "${process_cgroup}" "${executable}" \
    "${guest_rss_bytes}" "${guest_pss_bytes}" \
    "${dax_rss_bytes}" "${dax_pss_bytes}" \
    "${other_rss_bytes}" "${other_pss_bytes}"
  process_rows+=("${process_row}")
done <<<"${pids}"

thaw_cgroup
printf '%s\t%s\t%s\t%s\n' \
  "${INSTANCE_COUNT}" "${cgroup_memory_current_bytes}" \
  "${cgroup_memory_peak_bytes}" "${cgroup_memory_stat}" \
  >>"${CGROUP_MEMORY_FILE}"
if ((${#process_rows[@]} > 0)); then
  printf '%s\n' "${process_rows[@]}" >>"${PROCESS_MEMORY_FILE}"
fi

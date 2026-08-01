validate_effective_cpuset() {
  local cpuset=$1
  local segment
  local first
  local last
  local cpu
  local -a selected=()
  local -a segments=()
  local -A effective=()

  IFS=, read -r -a segments <<<"${cpuset}"
  for segment in "${segments[@]}"; do
    if [[ ${segment} =~ ^([0-9]+)-([0-9]+)$ ]]; then
      first=$((10#${BASH_REMATCH[1]}))
      last=$((10#${BASH_REMATCH[2]}))
      ((first <= last)) || fail "invalid effective CPU range ${segment}"
      for ((cpu = first; cpu <= last; cpu++)); do
        effective[${cpu}]=set
      done
    elif [[ ${segment} =~ ^[0-9]+$ ]]; then
      effective[$((10#${segment}))]=set
    else
      fail "invalid effective CPU set ${cpuset}"
    fi
  done

  IFS=, read -r -a selected <<<"${TARGET_CPU_IDS}"
  ((${#effective[@]} == ${#selected[@]})) ||
    fail "family cgroup effective CPUs are ${cpuset}, expected ${TARGET_CPU_IDS}"
  for cpu in "${selected[@]}"; do
    [[ -n ${effective[${cpu}]+set} ]] ||
      fail "CPU ${cpu} is absent from family cgroup effective CPUs ${cpuset}"
  done
}

create_family_cgroup() {
  local family=$1
  local initialization_unit

  FAMILY_CGROUP_SLICE="svbench${BENCHMARK_RUN_ID}${family}.slice"
  initialization_unit="svbench${BENCHMARK_RUN_ID}${family}init"
  systemd-run \
    --quiet \
    --wait \
    --collect \
    --service-type=exec \
    --unit="${initialization_unit}" \
    --slice="${FAMILY_CGROUP_SLICE}" \
    true
  systemctl set-property \
    --runtime \
    "${FAMILY_CGROUP_SLICE}" \
    "AllowedCPUs=${TARGET_CPU_IDS}" \
    MemoryAccounting=yes \
    TasksAccounting=yes
  FAMILY_CGROUP_PATH=$(
    systemctl show --property=ControlGroup --value "${FAMILY_CGROUP_SLICE}"
  )
  FAMILY_MEMORY_CURRENT_FILE="/sys/fs/cgroup${FAMILY_CGROUP_PATH}/memory.current"
  FAMILY_MEMORY_PEAK_FILE="/sys/fs/cgroup${FAMILY_CGROUP_PATH}/memory.peak"
  FAMILY_MEMORY_PRESSURE_FILE="/sys/fs/cgroup${FAMILY_CGROUP_PATH}/memory.pressure"
  FAMILY_CPUSET_EFFECTIVE_FILE="/sys/fs/cgroup${FAMILY_CGROUP_PATH}/cpuset.cpus.effective"
  [[ -n ${FAMILY_CGROUP_PATH} && -r ${FAMILY_MEMORY_CURRENT_FILE} &&
    -r ${FAMILY_MEMORY_PEAK_FILE} && -w ${FAMILY_MEMORY_PEAK_FILE} &&
    -r ${FAMILY_MEMORY_PRESSURE_FILE} &&
    -r ${FAMILY_CPUSET_EFFECTIVE_FILE} ]] ||
    fail "cgroup v2 memory and cpuset accounting is unavailable"
  EFFECTIVE_CPU_IDS=$(<"${FAMILY_CPUSET_EFFECTIVE_FILE}")
  validate_effective_cpuset "${EFFECTIVE_CPU_IDS}"
}

remove_family_cgroup() {
  [[ -n ${FAMILY_CGROUP_SLICE:-} ]] || return 0
  systemctl stop "${FAMILY_CGROUP_SLICE}" 2>/dev/null || true
  systemctl revert "${FAMILY_CGROUP_SLICE}" 2>/dev/null || true
  FAMILY_CGROUP_SLICE=
  FAMILY_CGROUP_PATH=
  FAMILY_MEMORY_CURRENT_FILE=
  FAMILY_MEMORY_PEAK_FILE=
  FAMILY_MEMORY_PRESSURE_FILE=
  FAMILY_CPUSET_EFFECTIVE_FILE=
  EFFECTIVE_CPU_IDS=
}

assert_process_in_family_cgroup() {
  local pid=$1
  local description=$2
  local process_cgroup

  process_cgroup=$(
    awk -F: '$1 == "0" { print $3 }' "/proc/${pid}/cgroup"
  )
  [[ ${process_cgroup} == "${FAMILY_CGROUP_PATH}/"* ]] ||
    fail "${description} ${pid} escaped family cgroup ${FAMILY_CGROUP_PATH}"
}

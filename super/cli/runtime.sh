process_start_time() {
  local stat

  process_start_time_result=
  [[ -r /proc/${1}/stat ]] || return 0
  stat=$(<"/proc/${1}/stat")
  # Remove pid and the parenthesized command name, which may contain spaces.
  stat=${stat##*) }
  process_start_time_result=$(awk '{ print $20 }' <<<"${stat}")
}

process_matches() {
  local pid=$1
  local started=$2
  local needle=$3
  local current
  local cmdline

  process_matches_result=false
  process_start_time "${pid}"
  current=${process_start_time_result}
  [[ -n ${current} && ${current} == "${started}" ]] || return 0
  [[ -r /proc/${pid}/cmdline ]] || return 0
  cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
  if [[ ${cmdline} == *"${needle}"* ]]; then
    process_matches_result=true
  fi
}

write_pid_file() {
  local name=$1
  local pid=$2
  local started
  local temporary

  process_start_time "${pid}"
  started=${process_start_time_result}
  [[ -n ${started} ]] ||
    fail "could not inspect newly started ${name} process ${pid}"
  temporary="${runtime_dir}/.${name}.pid.$$"
  printf '%s %s\n' "${pid}" "${started}" >"${temporary}"
  mv -f "${temporary}" "${runtime_dir}/${name}.pid"
}

service_healthy() {
  local name=$1
  local needle=$2
  local socket=$3
  local pid
  local started

  service_healthy_result=false
  [[ -r ${runtime_dir}/${name}.pid ]] || return 0
  read -r pid started <"${runtime_dir}/${name}.pid" || return 0
  [[ ${pid} =~ ^[1-9][0-9]*$ && ${started} =~ ^[0-9]+$ ]] || return 0
  process_matches "${pid}" "${started}" "${needle}"
  [[ ${process_matches_result} == true ]] || return 0
  if [[ -z ${socket} || -S ${socket} ]]; then
    service_healthy_result=true
  fi
}

stop_service() {
  local name=$1
  local socket=$2
  local pid=
  local started=
  local current
  local attempt

  if [[ -r ${runtime_dir}/${name}.pid ]]; then
    read -r pid started <"${runtime_dir}/${name}.pid" || true
  fi
  if [[ ${pid} =~ ^[1-9][0-9]*$ && ${started} =~ ^[0-9]+$ ]]; then
    process_start_time "${pid}"
    current=${process_start_time_result}
    if [[ -n ${current} && ${current} == "${started}" ]]; then
      kill "${pid}" 2>/dev/null || true
      for ((attempt = 0; attempt < 100; attempt++)); do
        process_start_time "${pid}"
        [[ ${process_start_time_result} == "${started}" ]] || break
        sleep 0.05
      done
      process_start_time "${pid}"
      if [[ ${process_start_time_result} == "${started}" ]]; then
        kill -KILL "${pid}" 2>/dev/null || true
      fi
      wait "${pid}" 2>/dev/null || true
    fi
  fi
  rm -f "${runtime_dir}/${name}.pid"
  [[ -z ${socket} ]] || rm -f "${socket}"
}

wait_for_service() {
  local name=$1
  local needle=$2
  local socket=$3
  local attempt

  for ((attempt = 0; attempt < 600; attempt++)); do
    service_healthy "${name}" "${needle}" "${socket}"
    [[ ${service_healthy_result} == true ]] && return
    sleep 0.05
  done
  stop_service "${name}" "${socket}"
  fail "timed out starting shared ${name} service"
}

ensure_castore() {
  local identity="redb:${castore}/directories.redb"

  service_healthy store "${identity}" "${store_socket}"
  if [[ ${service_healthy_result} == true ]]; then
    return
  fi

  stop_service store "${store_socket}"
  echo "supervm: starting shared castore daemon"
  # Immediate purging returns memory retained after boot bursts. Worker
  # threads stay unrestricted: this daemon is shared, so throughput matters
  # more than one instance's thread cost.
  MIMALLOC_PURGE_DELAY=0 \
    snix store daemon -l "${store_socket}" --unix-listen-unlink \
    --blob-service-addr "objectstore+file:${castore}/blobs" \
    --directory-service-addr "redb:${castore}/directories.redb" \
    --path-info-service-addr "redb:${state_dir}/store/pathinfo.redb" \
    >"${runtime_dir}/store.log" 2>&1 &
  write_pid_file store "$!"
  wait_for_service store "${identity}" "${store_socket}"
}

ensure_lower_store() {
  service_healthy lower "${lower_meta_socket}" "${lower_meta_socket}"
  if [[ ${service_healthy_result} != true ]]; then
    stop_service lower "${lower_meta_socket}"
    echo "supervm: starting shared lower-store daemon"
    MIMALLOC_PURGE_DELAY=0 \
      snix nix-daemon -l "${lower_meta_socket}" --unix-listen-unlink \
      --unix-listen-chmod everybody >"${runtime_dir}/lower.log" 2>&1 &
    write_pid_file lower "$!"
    wait_for_service lower "${lower_meta_socket}" "${lower_meta_socket}"
  fi

  service_healthy bridge VSOCK-LISTEN:5000 ""
  if [[ ${service_healthy_result} != true ]]; then
    stop_service bridge ""
    socat "VSOCK-LISTEN:5000,fork,reuseaddr" \
      "UNIX-CONNECT:${lower_meta_socket}" \
      >"${runtime_dir}/bridge.log" 2>&1 &
    write_pid_file bridge "$!"
    wait_for_service bridge VSOCK-LISTEN:5000 ""
  fi
}

lease_valid() {
  local candidate=$1
  local pid
  local started
  local current

  lease_valid_result=false
  read -r pid started <"${candidate}" || return 0
  [[ ${pid} =~ ^[1-9][0-9]*$ && ${started} =~ ^[0-9]+$ ]] || return 0
  process_start_time "${pid}"
  current=${process_start_time_result}
  if [[ -n ${current} && ${current} == "${started}" ]]; then
    lease_valid_result=true
  fi
}

prune_leases() {
  local candidate

  for candidate in "${leases_dir}"/*; do
    [[ -e ${candidate} ]] || continue
    lease_valid "${candidate}"
    [[ ${lease_valid_result} == true ]] || rm -f "${candidate}"
  done
}

create_lease() {
  local started
  local temporary

  process_start_time "$$"
  started=${process_start_time_result}
  [[ -n ${started} ]] || fail "could not inspect the SuperVM process"
  temporary="${lease}.tmp.$$"
  printf '%s %s\n' "$$" "${started}" >"${temporary}"
  mv -f "${temporary}" "${lease}"
  lease_active=true
}

stop_shared_services_if_idle() {
  local remaining

  prune_leases
  remaining=$(find "${leases_dir}" -mindepth 1 -maxdepth 1 -print -quit)
  [[ -z ${remaining} ]] || return 0
  echo "supervm: last operation out, stopping shared services"
  stop_service bridge ""
  stop_service lower "${lower_meta_socket}"
  stop_service store "${store_socket}"
}

bind_runtime_state() {
  local active_state=
  local remaining
  local temporary

  if [[ -r ${runtime_state_file} ]]; then
    active_state=$(<"${runtime_state_file}")
  fi
  if [[ -n ${active_state} && ${active_state} != "${state_dir}" ]]; then
    remaining=$(find "${leases_dir}" -mindepth 1 -maxdepth 1 -print -quit)
    [[ -z ${remaining} ]] ||
      fail "the shared runtime is active with a different XDG_STATE_HOME"
    stop_shared_services_if_idle
  fi
  if [[ ${active_state} != "${state_dir}" ]]; then
    temporary="${runtime_state_file}.tmp.$$"
    printf '%s\n' "${state_dir}" >"${temporary}"
    mv -f "${temporary}" "${runtime_state_file}"
  fi
}

stop_matching_process() {
  local pid=$1
  local started=$2
  local needle=$3
  local attempt

  [[ -n ${pid} && -n ${started} ]] || return 0
  process_matches "${pid}" "${started}" "${needle}"
  [[ ${process_matches_result} == true ]] || return 0
  kill "${pid}" 2>/dev/null || true
  for ((attempt = 0; attempt < 100; attempt++)); do
    process_matches "${pid}" "${started}" "${needle}"
    [[ ${process_matches_result} == true ]] || break
    sleep 0.05
  done
  process_matches "${pid}" "${started}" "${needle}"
  if [[ ${process_matches_result} == true ]]; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null || true
}

cleanup() {
  local status=$?

  trap - EXIT INT TERM
  set +o errexit
  if [[ ${runtime_active} == true ]]; then
    stop_matching_process "${vm_pid}" "${vm_started}" crosvm.sock
    stop_matching_process "${fs_pid}" "${fs_started}" \
      "${lower_store_fs_socket}"
    rm -f "${lower_store_fs_socket}" "${crosvm_control_socket}"
  fi
  [[ -z ${refs} ]] || rm -f "${refs}"
  rm -f "${temporary_runner_root}"
  if [[ ${lease_active} == true ]]; then
    flock 8
    rm -f "${lease}"
    lease_active=false
    stop_shared_services_if_idle
    flock -u 8
  fi
  exit "${status}"
}

initialize() {
  upper_store_dir=$(realpath -m "${positionals[0]}")
  runtime_dir=${XDG_RUNTIME_DIR:-/tmp}/supervm
  state_dir=${XDG_STATE_HOME:-${HOME}/.local/state}/supervm
  castore="${state_dir}/castore"
  leases_dir="${runtime_dir}/leases"
  store_socket="${runtime_dir}/store.sock"
  lower_meta_socket="${runtime_dir}/lower.sock"
  services_lock="${runtime_dir}/services.lock"
  runtime_state_file="${runtime_dir}/state-dir"
  mkdir -p "${leases_dir}" "${castore}/blobs" \
    "${state_dir}/store" "${state_dir}/dax-backing" "${upper_store_dir}"

  exec 9>"${upper_store_dir}/.supervm.lock"
  flock -n 9 ||
    fail "${upper_store_dir} is already in use by another SuperVM operation"

  upper_store_dir_hash=$(printf '%s' "${upper_store_dir}" | sha256sum)
  upper_store_dir_hash=${upper_store_dir_hash%% *}
  vm_id=${upper_store_dir_hash:0:16}
  # vsock context ids 0-2 are reserved.
  vsock_cid=$(((0x${vm_id:0:4} % 64000) + 3))
  vm_runtime_dir="${runtime_dir}/vms/${vm_id}"
  lower_store_fs_socket="${runtime_dir}/${vm_id}-lower.sock"
  crosvm_control_socket="${vm_runtime_dir}/crosvm.sock"
  lease="${leases_dir}/${vm_id}"
  prepared_dir="${state_dir}/prepared/${upper_store_dir_hash}"
  prepared_runner_root="${prepared_dir}/runner"
  temporary_runner_root="${prepared_dir}/runner.tmp.$$"
  mkdir -p "${vm_runtime_dir}" "${prepared_dir}"

  for socket_path in "${lower_store_fs_socket}" "${crosvm_control_socket}"; do
    if ((${#socket_path} > 107)); then
      fail "socket path is ${#socket_path} bytes, over the kernel's 107-byte limit: ${socket_path}"
    fi
  done

  lease_active=false
  runtime_active=false
  vm_pid=
  vm_started=
  fs_pid=
  fs_started=
  refs=

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 8>"${services_lock}"
}

start_shared_services() {
  local include_lower=$1

  flock 8
  prune_leases
  bind_runtime_state
  create_lease
  ensure_castore
  if [[ ${include_lower} == true ]]; then
    ensure_lower_store
  fi
  flock -u 8

  export BLOB_SERVICE_ADDR="grpc+unix:${store_socket}"
  export DIRECTORY_SERVICE_ADDR="grpc+unix:${store_socket}"
  export PATH_INFO_SERVICE_ADDR="grpc+unix:${store_socket}"
}

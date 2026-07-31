load_prepared_runner() {
  [[ -L ${prepared_runner_root} && -e ${prepared_runner_root} ]] ||
    fail "guest is not prepared; run 'supervm prepare' first"
  runner=$(readlink -f "${prepared_runner_root}")
}

reap_orphaned_runtime() {
  local process_dir
  local pid
  local executable
  local started
  local process_cwd
  local process_cmdline

  for process_dir in /proc/[0-9]*; do
    pid=${process_dir#/proc/}
    executable=$(readlink "/proc/${pid}/exe" 2>/dev/null) || continue
    process_start_time "${pid}"
    started=${process_start_time_result}
    [[ -n ${started} ]] || continue
    case ${executable} in
      *crosvm*)
        process_cwd=$(readlink "/proc/${pid}/cwd" 2>/dev/null) || continue
        [[ ${process_cwd} == "${vm_runtime_dir}" ]] || continue
        echo "supervm: reaping orphaned VM ${pid} from ${vm_runtime_dir}"
        stop_matching_process "${pid}" "${started}" crosvm
        ;;
      *snix*)
        [[ -r /proc/${pid}/cmdline ]] || continue
        process_cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
        [[ ${process_cmdline} == *"${lower_store_fs_socket}"* ]] || continue
        echo "supervm: reaping orphaned filesystem ${pid}"
        stop_matching_process "${pid}" "${started}" \
          "${lower_store_fs_socket}"
        ;;
    esac
  done
  rm -f "${lower_store_fs_socket}" "${crosvm_control_socket}"
  runtime_active=true
}

find_lower_store_tag() {
  local share_dir

  lower_store_tag=
  for share_dir in "${runner}"/share/microvm/virtiofs/*/; do
    [[ -e ${share_dir}socket ]] || continue
    [[ $(<"${share_dir}socket") == "${lower_store_fs_socket}" ]] || continue
    lower_store_tag=$(basename "${share_dir}")
    break
  done
  [[ -n ${lower_store_tag} ]] ||
    fail "no virtio-fs share in the runner uses ${lower_store_fs_socket}"
}

start_vm_filesystem() {
  local attempt

  echo "supervm: starting lower-store filesystem (tag ${lower_store_tag})"
  # This daemon runs once per VM, so its idle footprint multiplies. Two
  # runtime workers are plenty for one guest's request stream, and immediate
  # purging stops the allocator from retaining boot-burst memory.
  MIMALLOC_PURGE_DELAY=0 TOKIO_WORKER_THREADS=2 \
    snix store virtiofs \
    --dax-backing-dir "${state_dir}/dax-backing" \
    --tag "${lower_store_tag}" \
    "${lower_store_fs_socket}" >"${runtime_dir}/${vm_id}-fs.log" 2>&1 &
  fs_pid=$!
  process_start_time "${fs_pid}"
  fs_started=${process_start_time_result}
  [[ -n ${fs_started} ]] ||
    fail "could not inspect lower-store filesystem process ${fs_pid}"

  for ((attempt = 0; attempt < 600; attempt++)); do
    kill -0 "${fs_pid}" 2>/dev/null ||
      fail "lower-store filesystem exited during startup"
    [[ -S ${lower_store_fs_socket} ]] && break
    sleep 0.05
  done
  [[ -S ${lower_store_fs_socket} ]] ||
    fail "timed out starting lower-store filesystem"
}

run_launch() {
  local status

  load_prepared_runner
  start_shared_services true

  echo "supervm: vm ${vm_id} (cid ${vsock_cid})"
  reap_orphaned_runtime
  find_lower_store_tag
  start_vm_filesystem

  echo "supervm: booting"
  cd "${vm_runtime_dir}"

  # An explicit stdin duplication keeps the serial console attached when the
  # child runs asynchronously. Waiting in the shell lets INT and TERM run the
  # cleanup trap immediately instead of being deferred until crosvm exits.
  "${runner}/bin/microvm-run" 0<&0 &
  vm_pid=$!
  process_start_time "${vm_pid}"
  vm_started=${process_start_time_result}
  [[ -n ${vm_started} ]] ||
    fail "could not inspect VM process ${vm_pid}"

  set +o errexit
  wait "${vm_pid}"
  status=$?
  set -o errexit
  return "${status}"
}

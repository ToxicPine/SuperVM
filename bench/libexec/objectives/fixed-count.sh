BENCHMARK_OBJECTIVE=fixed-count
BENCHMARK_OBJECTIVE_USAGE='N '
TARGET_INSTANCE_COUNT=0
FIXED_COUNT_INCOMPLETE=false
IDLE_MARGINAL_BYTES=0
POST_LOAD_MARGINAL_BYTES=0
MARGINAL_CALCULATION=

benchmark_objective_environment() {
  printf 'requested_instance_count=%s\n' "${TARGET_INSTANCE_COUNT}"
  printf 'marginal_calculation=%s\n' "${MARGINAL_CALCULATION}"
}

benchmark_objective_prepare_output() {
  if [[ ${BENCHMARK_HAS_LOAD} == true ]]; then
    printf 'family\tinstance_count\tidle_total_bytes\tidle_marginal_bytes\tpost_load_total_bytes\tpost_load_marginal_bytes\tstop_reason\n' \
      >"${OUTPUT_DIR}/summary.tsv"
  else
    printf 'family\tinstance_count\ttotal_bytes\tmarginal_bytes\tstop_reason\n' \
      >"${OUTPUT_DIR}/summary.tsv"
  fi
}

benchmark_objective_record() {
  if [[ ${BENCHMARK_HAS_LOAD} == true ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "${#LAUNCHER_PIDS[@]}" "${IDLE_TOTAL_BYTES}" \
      "${IDLE_MARGINAL_BYTES}" "${POST_LOAD_TOTAL_BYTES}" \
      "${POST_LOAD_MARGINAL_BYTES}" "${STOP_REASON}" \
      >>"${OUTPUT_DIR}/summary.tsv"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$1" "${#LAUNCHER_PIDS[@]}" "${IDLE_TOTAL_BYTES}" \
      "${IDLE_MARGINAL_BYTES}" "${STOP_REASON}" \
      >>"${OUTPUT_DIR}/summary.tsv"
  fi
}

benchmark_objective_unavailable() {
  FIXED_COUNT_INCOMPLETE=true
}

benchmark_objective_prepare_family() {
  IDLE_MARGINAL_BYTES=0
  POST_LOAD_MARGINAL_BYTES=0
}

benchmark_objective_prepare_instances() {
  local family=$1
  local index

  for ((index = 1; index <= TARGET_INSTANCE_COUNT; index++)); do
    prepare_instance_artifact "${family}" "${index}"
  done
}

benchmark_objective_run() {
  local family=$1
  local remaining_count=$((TARGET_INSTANCE_COUNT - 1))
  local instance_count
  local denominator
  local unmerged_marginal_bytes

  if ((remaining_count > 0)); then
    launch_instance_batch "${family}" "${remaining_count}"
    if ((LAUNCHED_INSTANCE_COUNT > 0)); then
      record_checkpoint "${family}"
    fi
  fi

  instance_count=${#LAUNCHER_PIDS[@]}
  if ((instance_count == 1)); then
    IDLE_MARGINAL_BYTES=${FIRST_INSTANCE_IDLE_BYTES}
    POST_LOAD_MARGINAL_BYTES=${FIRST_INSTANCE_TOTAL_BYTES}
    unmerged_marginal_bytes=${FIRST_INSTANCE_UNMERGED_PEAK_BYTES}
  else
    denominator=$((instance_count - 1))
    IDLE_MARGINAL_BYTES=$((
      (IDLE_TOTAL_BYTES - FIRST_INSTANCE_IDLE_BYTES) / denominator
    ))
    POST_LOAD_MARGINAL_BYTES=$((
      (POST_LOAD_TOTAL_BYTES - FIRST_INSTANCE_TOTAL_BYTES) / denominator
    ))
    unmerged_marginal_bytes=$((
      (UNMERGED_PEAK_TOTAL_BYTES - FIRST_INSTANCE_UNMERGED_PEAK_BYTES) /
      denominator
    ))
  fi
  MARGINAL_BYTES=${POST_LOAD_MARGINAL_BYTES}
  LAUNCH_HEADROOM_BYTES=${unmerged_marginal_bytes}
  ((LAUNCH_HEADROOM_BYTES >= MARGINAL_BYTES)) ||
    LAUNCH_HEADROOM_BYTES=${MARGINAL_BYTES}

  if ((instance_count == TARGET_INSTANCE_COUNT)); then
    STOP_REASON=target_reached
  else
    STOP_REASON=host_safety_reserve
    FIXED_COUNT_INCOMPLETE=true
  fi
  record_family_summary "${family}"
  stop_all_instances
  sleep 30
}

benchmark_objective_finish() {
  [[ ${FIXED_COUNT_INCOMPLETE} == false ]] ||
    fail "host safety reserve prevented the requested fixed instance count"
}

run_fixed_count() {
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]] || show_usage
  TARGET_INSTANCE_COUNT=$((10#$1))
  ((TARGET_INSTANCE_COUNT <= MAX_INSTANCE_COUNT)) ||
    fail "N cannot exceed ${MAX_INSTANCE_COUNT}"
  if ((TARGET_INSTANCE_COUNT == 1)); then
    MARGINAL_CALCULATION=first_instance_total
  else
    MARGINAL_CALCULATION=slope_from_first_to_fleet
  fi
  shift
  run_benchmark "$@"
}

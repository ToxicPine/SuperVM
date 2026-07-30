BENCHMARK_OBJECTIVE=max-count
BENCHMARK_OBJECTIVE_USAGE='MEMORY_LIMIT '
MEMORY_LIMIT_BYTES=0

benchmark_objective_environment() {
  printf 'memory_limit_bytes=%s\n' "${MEMORY_LIMIT_BYTES}"
}

benchmark_objective_prepare_accounting() {
  systemctl set-property \
    --runtime \
    "${FAMILY_CGROUP_SLICE}" \
    "MemoryHigh=${MEMORY_LIMIT_BYTES}"
}

benchmark_objective_prepare_output() {
  printf 'family\tinstance_count\ttotal_bytes\tmarginal_bytes\tstop_reason\n' \
    >"${OUTPUT_DIR}/summary.tsv"
}

benchmark_objective_record() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$1" "${#LAUNCHER_PIDS[@]}" "${TOTAL_BYTES}" "${MARGINAL_BYTES}" \
    "${STOP_REASON}" \
    >>"${OUTPUT_DIR}/summary.tsv"
}

benchmark_objective_run() {
  local family=$1
  local instance_count
  local previous_instance_count
  local previous_total_bytes
  local remaining_bytes
  local estimated_additional_instance_count
  local batch_size
  local batch_marginal_bytes
  local unmerged_batch_marginal_bytes
  local removal_count
  local launch_one_at_a_time=false
  local -a marginal_samples_bytes=()
  local -a unmerged_marginal_samples_bytes=()

  STOP_REASON=estimated_capacity
  if ((TOTAL_BYTES > MEMORY_LIMIT_BYTES)); then
    STOP_REASON=first_instance_exceeds_limit
    stop_last_instance
    TOTAL_BYTES=0
    record_family_summary "${family}"
    return
  fi

  while ((${#LAUNCHER_PIDS[@]} < MAX_INSTANCE_COUNT)); do
    remaining_bytes=$((MEMORY_LIMIT_BYTES - TOTAL_BYTES))
    ((remaining_bytes > 0 && MARGINAL_BYTES > 0)) || break
    estimated_additional_instance_count=$((remaining_bytes / MARGINAL_BYTES))
    ((estimated_additional_instance_count > 0)) || break
    if [[ ${launch_one_at_a_time} == true ]] ||
      ((estimated_additional_instance_count < 4)); then
      batch_size=1
    else
      batch_size=$((2 * estimated_additional_instance_count / 3))
    fi
    instance_count=${#LAUNCHER_PIDS[@]}
    if ((instance_count + batch_size > MAX_INSTANCE_COUNT)); then
      batch_size=$((MAX_INSTANCE_COUNT - instance_count))
    fi
    previous_instance_count=${instance_count}
    previous_total_bytes=${TOTAL_BYTES}
    launch_instance_batch "${family}" "${batch_size}"
    batch_size=${LAUNCHED_INSTANCE_COUNT}
    if ((batch_size == 0)); then
      STOP_REASON=host_safety_reserve
      break
    fi
    record_checkpoint "${family}"
    instance_count=${#LAUNCHER_PIDS[@]}

    if ((TOTAL_BYTES > MEMORY_LIMIT_BYTES)); then
      removal_count=${batch_size}
      while ((removal_count > 0)); do
        stop_last_instance
        removal_count=$((removal_count - 1))
      done
      launch_one_at_a_time=true
      if ((batch_size == 1)); then
        STOP_REASON=measured_limit
        TOTAL_BYTES=${previous_total_bytes}
        break
      fi
      record_checkpoint "${family}"
      continue
    fi

    batch_marginal_bytes=$((
      (TOTAL_BYTES - previous_total_bytes) /
      (instance_count - previous_instance_count)
    ))
    if ((batch_marginal_bytes > 0)); then
      marginal_samples_bytes+=("${batch_marginal_bytes}")
      if ((${#marginal_samples_bytes[@]} < 3)); then
        MARGINAL_BYTES=${batch_marginal_bytes}
      else
        MARGINAL_BYTES=$(
          median_of_three \
            "${marginal_samples_bytes[-1]}" \
            "${marginal_samples_bytes[-2]}" \
            "${marginal_samples_bytes[-3]}"
        )
      fi
    fi

    unmerged_batch_marginal_bytes=$((
      (UNMERGED_PEAK_TOTAL_BYTES - previous_total_bytes) /
        (instance_count - previous_instance_count)
    ))
    if ((unmerged_batch_marginal_bytes > 0)); then
      unmerged_marginal_samples_bytes+=("${unmerged_batch_marginal_bytes}")
      if ((${#unmerged_marginal_samples_bytes[@]} < 3)); then
        LAUNCH_HEADROOM_BYTES=${unmerged_batch_marginal_bytes}
      else
        LAUNCH_HEADROOM_BYTES=$(
          median_of_three \
            "${unmerged_marginal_samples_bytes[-1]}" \
            "${unmerged_marginal_samples_bytes[-2]}" \
            "${unmerged_marginal_samples_bytes[-3]}"
        )
      fi
    fi
    ((LAUNCH_HEADROOM_BYTES >= MARGINAL_BYTES)) ||
      LAUNCH_HEADROOM_BYTES=${MARGINAL_BYTES}

    if [[ ${LAUNCH_BLOCKED_BY_HOST_RESERVE} == true ]]; then
      STOP_REASON=host_safety_reserve
      break
    fi
  done

  ((${#LAUNCHER_PIDS[@]} < MAX_INSTANCE_COUNT)) ||
    STOP_REASON=max_instances
  record_family_summary "${family}"
  stop_all_instances
  sleep 30
}

run_max_count() {
  local value
  local unit
  local multiplier

  [[ ${1:-} =~ ^([1-9][0-9]*)(B|KiB|MiB|GiB)$ ]] || show_usage
  value=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]}
  case ${unit} in
    B) multiplier=1 ;;
    KiB) multiplier=1024 ;;
    MiB) multiplier=$((1024 * 1024)) ;;
    GiB) multiplier=$((1024 * 1024 * 1024)) ;;
  esac
  MEMORY_LIMIT_BYTES=$((10#${value} * multiplier))
  ((MEMORY_LIMIT_BYTES > 0)) || fail "MEMORY_LIMIT is too large"
  shift
  run_benchmark "$@"
}

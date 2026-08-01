BENCHMARK_MODE=idle
BENCHMARK_HAS_LOAD=false
BENCHMARK_GUESTS_IDENTICAL=true

benchmark_variant_guest() {
  printf '%s#idle\n' "$2"
}

benchmark_variant_wait_ready() {
  local index=${#LAUNCHER_PIDS[@]}
  local log="${FAMILY_OUTPUT_DIR}/logs/${index}.log"
  local deadline=$((SECONDS + 300))

  while ((SECONDS < deadline)); do
    if grep --quiet --fixed-strings 'nixos login:' "${log}"; then
      return
    fi
    sleep 1
  done
  fail "idle VM ${index} did not reach its login prompt"
}

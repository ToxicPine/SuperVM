BENCHMARK_MODE=idle
BENCHMARK_HAS_LOAD=false
BENCHMARK_GUESTS_IDENTICAL=true

benchmark_variant_guest() {
  printf '%s#idle\n' "$2"
}

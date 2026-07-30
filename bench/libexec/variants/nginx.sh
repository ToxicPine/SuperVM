BENCHMARK_MODE=nginx
BENCHMARK_HAS_LOAD=true
BENCHMARK_GUESTS_IDENTICAL=false
BENCHMARK_BRIDGE_CREATED=false

instance_ip_address() {
  printf '10.231.%s.%s\n' "$((($1 - 1) / 254))" "$((($1 - 1) % 254 + 1))"
}

instance_tap_name() {
  printf 'svb%s\n' "$1"
}

benchmark_variant_requirements() {
  require_command curl
  require_command ip
  [[ ${EUID} -eq 0 ]] || fail "nginx mode requires root"
}

benchmark_variant_prepare_host() {
  [[ ! -e /sys/class/net/svbench0 ]] || fail "svbench0 already exists"
  ip link add svbench0 type bridge
  BENCHMARK_BRIDGE_CREATED=true
  ip address add 10.231.255.254/16 dev svbench0
  ip link set svbench0 up
}

benchmark_variant_prepare_instance() {
  local index=$1

  INSTANCE_TAP_NAME=$(instance_tap_name "${index}")
  INSTANCE_IP_ADDRESS=$(instance_ip_address "${index}")
  [[ ! -e /sys/class/net/${INSTANCE_TAP_NAME} ]] ||
    fail "TAP ${INSTANCE_TAP_NAME} already exists"
  ip tuntap add dev "${INSTANCE_TAP_NAME}" mode tap
  PENDING_INSTANCE_TAP_NAME=${INSTANCE_TAP_NAME}
  ip link set "${INSTANCE_TAP_NAME}" master svbench0
  ip link set "${INSTANCE_TAP_NAME}" up
}

benchmark_variant_guest() {
  printf '%s#load-%s\n' "$2" "$1"
}

benchmark_variant_wait_ready() {
  local ip=$1
  local deadline=$((SECONDS + 300))
  local body

  while ((SECONDS < deadline)); do
    body=$(curl --fail --silent --max-time 2 "http://${ip}/health" || true)
    [[ ${body} == ready ]] && return
    sleep 1
  done
  fail "nginx startup timed out at ${ip}"
}

benchmark_variant_load() {
  local ip

  for ip in "${INSTANCE_IP_ADDRESSES[@]}"; do
    curl --fail --silent --show-error --max-time 10 \
      --output /dev/null "http://${ip}/payload.bin"
  done
}

benchmark_variant_remove_instance() {
  local tap=$1

  [[ -n ${tap} && -e /sys/class/net/${tap} ]] || return 0
  ip link delete "${tap}" 2>/dev/null || true
}

benchmark_variant_cleanup_host() {
  if [[ ${BENCHMARK_BRIDGE_CREATED} == true &&
    -e /sys/class/net/svbench0 ]]; then
    ip link delete svbench0 2>/dev/null || true
  fi
}

#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=libexec/benchmark-runner.sh
source "${script_dir}/libexec/benchmark-runner.sh"
# shellcheck source=libexec/family-cgroup.sh
source "${script_dir}/libexec/family-cgroup.sh"
# shellcheck source=libexec/instance-preparation.sh
source "${script_dir}/libexec/instance-preparation.sh"
# shellcheck source=libexec/variants/idle.sh
source "${script_dir}/libexec/variants/idle.sh"
# shellcheck source=libexec/objectives/max-count.sh
source "${script_dir}/libexec/objectives/max-count.sh"

BENCHMARK_PROGRAM_NAME=$0
run_max_count "$@"

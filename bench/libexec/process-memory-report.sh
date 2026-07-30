#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  printf 'usage: %s LAUNCHER_PID\n' "$0" >&2
  exit 2
fi

list_process_tree() {
  local pid
  local -a children=()
  local -a queue=("$1")

  while ((${#queue[@]} > 0)); do
    pid=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -d /proc/${pid} ]] || continue
    printf '%s\n' "${pid}"
    mapfile -t children < <(pgrep -P "${pid}" || true)
    queue+=("${children[@]}")
  done
}

read_crosvm_mapping_pss() {
  awk '
    /^[0-9a-f]+-[0-9a-f]+ / {
      kind = "other"
      if ($0 ~ /memfd:crosvm_guest/) kind = "guest"
      if ($0 ~ /dax-backing/) kind = "dax"
      next
    }
    $1 == "Pss:" { bytes[kind] += $2 * 1024 }
    END {
      printf "%.0f\t%.0f\t%.0f\n",
        bytes["guest"], bytes["dax"], bytes["other"]
    }
  ' "$1"
}

launcher_pid=$1
process_tree=$(list_process_tree "${launcher_pid}")
guest_memfd_pss_bytes=0
dax_pss_bytes=0
other_crosvm_pss_bytes=0
process_tree_pss_bytes=0

while IFS= read -r pid; do
  if [[ -r /proc/${pid}/smaps_rollup ]]; then
    pss=$(awk '$1 == "Pss:" { print $2 * 1024 }' "/proc/${pid}/smaps_rollup")
    process_tree_pss_bytes=$((process_tree_pss_bytes + ${pss:-0}))
  fi

  executable=$(readlink "/proc/${pid}/exe" 2>/dev/null || true)
  [[ ${executable} == */crosvm ]] || continue
  row=$(read_crosvm_mapping_pss "/proc/${pid}/smaps")
  IFS=$'\t' read -r \
    mapped_guest_memfd_pss_bytes mapped_dax_pss_bytes \
    mapped_other_crosvm_pss_bytes <<<"${row}"
  guest_memfd_pss_bytes=$((
    guest_memfd_pss_bytes + mapped_guest_memfd_pss_bytes
  ))
  dax_pss_bytes=$((dax_pss_bytes + mapped_dax_pss_bytes))
  other_crosvm_pss_bytes=$((
    other_crosvm_pss_bytes + mapped_other_crosvm_pss_bytes
  ))
done <<<"${process_tree}"

printf '%s\t%s\t%s\t%s\t%s\n' \
  "${guest_memfd_pss_bytes}" "${dax_pss_bytes}" \
  "${other_crosvm_pss_bytes}" \
  "$((guest_memfd_pss_bytes + dax_pss_bytes + other_crosvm_pss_bytes))" \
  "${process_tree_pss_bytes}"

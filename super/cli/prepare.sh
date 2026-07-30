build_prepared_runner() {
  local guest_arg

  if [[ -n ${profile} ]]; then
    guest_arg="guest = (builtins.getFlake \"${profile%%#*}\").nixosConfigurations.\"${profile##*#}\";"
  else
    guest_arg=
  fi

  echo "supervm: building guest"
  rm -f "${temporary_runner_root}"
  runner=$(nix build --impure \
    --out-link "${temporary_runner_root}" \
    --print-out-paths \
    --expr \
    "(builtins.getFlake \"${SUPERVM_FLAKE}\").lib.mkSuperRunner {
       upperStoreDir = \"${upper_store_dir}\";
       vsockCid = ${vsock_cid};
       lowerStoreFsSocket = \"${lower_store_fs_socket}\";
       daxMode = \"${dax_mode}\";
       ${guest_arg}
     }")
  system=$(readlink -f "${runner}/share/microvm/system")
}

run_prepare() {
  build_prepared_runner
  start_shared_services false

  echo "supervm: ingesting system closure"
  refs="${runtime_dir}/${vm_id}-refs.json"
  nix path-info --json --recursive "${system}" |
    jq '[to_entries[] | .value + {path: .key}]' >"${refs}"
  snix store copy "${refs}" >/dev/null
  rm -f "${refs}"
  refs=

  # The GC root is also the preparation record. Publish it only after the
  # exact runner's system closure has reached the shared store.
  mv -Tf "${temporary_runner_root}" "${prepared_runner_root}"
  echo "supervm: prepared ${system}"
}

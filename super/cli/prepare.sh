build_prepared_runner() {
  local profile_arg

  if [[ -n ${profile} ]]; then
    export SUPERVM_PROFILE_FLAKE_REF=${profile%%#*}
    export SUPERVM_PROFILE_ATTRIBUTE=${profile##*#}
    profile_arg="profile = {
      flakeRef = builtins.getEnv \"SUPERVM_PROFILE_FLAKE_REF\";
      attribute = builtins.getEnv \"SUPERVM_PROFILE_ATTRIBUTE\";
    };"
  else
    profile_arg=
  fi

  echo "supervm: building guest"
  rm -f "${temporary_runner_root}"
  export SUPERVM_UPPER_STORE_DIR=${upper_store_dir}
  export SUPERVM_LOWER_STORE_FS_SOCKET=${lower_store_fs_socket}
  export SUPERVM_VSOCK_CID=${vsock_cid}
  export SUPERVM_DAX_MODE=${dax_mode}
  runner=$(nix build --impure \
    --out-link "${temporary_runner_root}" \
    --print-out-paths \
    --expr \
    "(builtins.getFlake \"${SUPERVM_FLAKE}\").lib.supervm.mkRunner {
       upperStoreDir = builtins.getEnv \"SUPERVM_UPPER_STORE_DIR\";
       vsockCid = builtins.fromJSON (builtins.getEnv \"SUPERVM_VSOCK_CID\");
       lowerStoreFsSocket = builtins.getEnv \"SUPERVM_LOWER_STORE_FS_SOCKET\";
       daxMode = builtins.getEnv \"SUPERVM_DAX_MODE\";
       ${profile_arg}
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

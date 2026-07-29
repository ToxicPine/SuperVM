{
  guestKernel,
  python3,
  runCommand,
}:

runCommand "guest-kernel-image-ranges"
  {
    nativeBuildInputs = [ python3 ];
  }
  ''
    out="''${out:?Nix did not set the output path}"
    mkdir -p "''${out}"
    ln -s ${guestKernel}/bzImage "''${out}/kernel-image"
    python3 ${./emit.py} \
      --vmlinux ${guestKernel.dev}/vmlinux \
      --kernel-image "''${out}/kernel-image" \
      --system-map ${guestKernel}/System.map \
      --config ${guestKernel.configfile} \
      --output "''${out}/ranges.json"
  ''

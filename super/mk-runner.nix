# Turn a NixOS configuration into a runnable SuperVM.
#
# `extendModules` layers the template over the caller's configuration without
# the original having to anticipate it, so a caller brings a plain NixOS config
# and keeps their own settings.

{
  lib,
  templateModules,
  defaultGuestFor,
  guestKernelFor,
  vmPackagesModule,
}:

{
  # Host directory holding this VM's upper store.
  upperStoreDir,

  # Host-side socket the wrapper serves this VM's lower-store contents on.
  lowerStoreFsSocket,

  # Context id for the vsock carrying lower-store metadata. Unique per VM.
  vsockCid,

  # Whether DAX is disabled, selected per inode, or forced for every file.
  daxMode ? "inode",

  system ? "x86_64-linux",

  # The guest defaults to the same system as its kernel, so the two cannot
  # drift apart.
  guest ? defaultGuestFor system,
}:

let
  # `upperStoreDir` is host-side state owned by this API, not a NixOS option.
  # Reject a relative path here, before it is interpolated into microvm.volumes
  # and microvm.nix silently resolves it relative to its own state directory.
  upperStoreDirIsAbsolute = builtins.isString upperStoreDir && lib.hasPrefix "/" upperStoreDir;
  upperStoreDirDescription =
    if builtins.isString upperStoreDir then
      "'${upperStoreDir}'"
    else
      "a ${builtins.typeOf upperStoreDir}";

  sys = guest.extendModules {
    modules = [
      vmPackagesModule
    ]
    ++ templateModules {
      inherit
        daxMode
        upperStoreDir
        lowerStoreFsSocket
        vsockCid
        ;
      guestKernel = guestKernelFor system;
    };
  };
in

lib.throwIfNot upperStoreDirIsAbsolute
  "supervm: upperStoreDir must be an absolute path string, got ${upperStoreDirDescription}"
  (
    lib.throwIfNot
      (builtins.elem daxMode [
        "never"
        "inode"
        "always"
      ])
      "supervm: daxMode must be one of never, inode, or always; got '${daxMode}'"
      sys.config.microvm.declaredRunner
  )

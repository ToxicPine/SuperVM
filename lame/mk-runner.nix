# A deliberately ordinary microvm.nix+crosvm baseline for SuperVM.
#
# It uses mainline microvm.nix and its unmodified nixpkgs crosvm package, but
# pins the same guest kernel as SuperVM for a like-for-like comparison. The
# guest closure is built into microvm.nix's read-only store disk.

{
  microvm,
  defaultGuestFor,
  guestKernelFor,
}:

{
  system ? "x86_64-linux",

  # As with SuperVM, callers supply a plain NixOS configuration. The
  # microvm.nix module and baseline policy are layered over it here.
  guest ? defaultGuestFor system,
}:

let
  guestKernel = guestKernelFor system;
  sys = guest.extendModules {
    modules = [
      microvm.nixosModules.microvm
      (
        { lib, pkgs, ... }:
        {
          boot = {
            kernelPackages = lib.mkForce (pkgs.linuxPackagesFor guestKernel);
            kernelPatches = lib.mkForce [ ];
            kernel.features = lib.mkForce { };
            kernel.randstructSeed = lib.mkForce "";
          };

          microvm = {
            hypervisor = "crosvm";
            socket = "crosvm.sock";
            balloon = true;

            # This is the vanilla microvm.nix store path: a read-only image
            # containing the guest closure. There is deliberately no writable
            # overlay, state volume, share or external service.
            storeOnDisk = lib.mkForce true;
            writableStoreOverlay = lib.mkForce null;
          };
        }
      )
    ];
  };
in
sys.config.microvm.declaredRunner

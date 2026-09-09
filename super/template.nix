# The template SuperVM merges over a caller's NixOS configuration.
#
# A caller brings a plain NixOS configuration and does not have to know about
# microvm.nix, Snix or DAX; this is what turns one into a SuperVM guest. Kept
# here rather than in the wrapper script so the policy it encodes is
# reviewable as Nix and can be evaluated on its own.

{
  microvm,
  overlayStoreModule,
}:

{
  # Host directory holding this VM's upper store: the paths it writes, their
  # database, and its profiles. The counterpart to the shared castore that
  # backs the lower store. Its contents are our business, not the caller's -
  # the command-line contract is only that the directory holds one VM's state
  # as a unit.
  upperStoreDir,

  # Host-side socket serving this VM's view of the lower store's contents.
  lowerStoreFsSocket,

  # Kernel built with CONFIG_FUSE_DAX. Without it the guest cannot mount
  # virtio-fs with `-o dax` and quietly falls back to copying reads, so this is
  # not something to leave to the caller's configuration.
  guestKernel,

  # Context id for the vsock carrying lower-store metadata. Unique per VM.
  vsockCid,

  # DAX policy selected by the wrapper.
  daxMode,
}:

[
  microvm.nixosModules.microvm
  overlayStoreModule
  (
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      isX86_64 = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      guestKernelImageRanges = pkgs.callPackage ./kernel-image-ranges {
        guestKernel = config.microvm.kernel;
      };
    in
    {
      supervm = {
        enable = true;

        # The share itself is declared by the guest module; all this supplies
        # is where to reach the server the wrapper is running.
        inherit lowerStoreFsSocket;

        # Crosvm asks the vhost-user backend for its shared-memory window.
        # Supplying the VMM-sized Alioth value is rejected by its runner.
        dax = {
          mode = daxMode;
          window = null;
        };
      };

      # mkForce: the caller may well have set a kernel, but DAX is the reason
      # this VM exists and a kernel without it fails silently.
      boot = {
        kernelPackages = lib.mkForce (pkgs.linuxPackagesFor guestKernel);
        # NixOS applies these modifiers after `kernelPackages`; force them empty
        # so the range artifact and the kernel actually booted remain identical.
        kernelPatches = lib.mkForce [ ];
        kernel.features = lib.mkForce { };
        kernel.randstructSeed = lib.mkForce "";
      };

      # The virtual hardware is fixed and its drivers are built into the guest
      # kernel, so the stock initrd module set (SATA, USB, keyboards, LVM) is
      # dead weight that is unpacked into guest RAM on every boot. The same
      # goes for microvm.nix's own list: virtio, virtio-fs and overlayfs are
      # built in, and 9p is not used. A module loaded at boot costs every guest
      # its own copy of the text in vmalloc, where built-in text is shared
      # through the kernel image ranges; dropping these took a guest from
      # 13.7 MiB to 4.7 MiB of vmalloc. Callers needing initrd modules of
      # their own still have `boot.initrd.availableKernelModules`.
      boot.initrd.includeDefaultModules = lib.mkDefault false;
      boot.initrd.kernelModules = lib.mkForce [ ];

      # A microVM has no radio. cfg80211 (with rfkill in tow) is autoloaded
      # regardless and is the largest module an idle guest carried.
      boot.blacklistedKernelModules = [ "cfg80211" ];

      # Free page reporting only returns free blocks of at least this order to
      # the host. The default, the 2 MiB pageblock, leaves every smaller free
      # fragment resident on the host: about 15 MiB on an idle 512 MiB guest,
      # since post-boot free memory is fragmented. Order 0 reports everything;
      # reporting is batched and delayed, so an idle guest pays nothing for it.
      boot.kernelParams = [ "page_reporting.page_reporting_order=0" ];

      microvm = {
        hypervisor = "crosvm";
        # Free page reporting is what lets a guest's freed memory leave the
        # host; a balloon device alone only lets the host take memory back by
        # asking. Reporting is on by default for the same reason DAX is: a
        # guest that keeps every page it ever touched defeats the point.
        balloon = true;
        # The wrapper starts each runner in a private per-VM runtime directory,
        # making this relative control-socket name unique without embedding a
        # host runtime path in the Nix derivation.
        socket = "crosvm.sock";

        crosvm.extraArgs = [ "--balloon-page-reporting" ]
        ++ lib.optionals isX86_64 [
          "--disable-sandbox"
          "--private-ram-map"
          "${guestKernelImageRanges}/ranges.json"
          "--private-ram-mergeable"
        ];

        # Carries the Nix daemon protocol to the shared lower store. A unix
        # socket cannot be reached across virtio-fs, since connect() resolves
        # to an inode and the guest kernel has no listener bound to the host's.
        vsock.cid = vsockCid;

        # The overlay's upper layer, on a real filesystem. OverlayFS needs an
        # upper supporting trusted.*/user.* xattrs and valid d_type, which
        # rules out handing it over virtio-fs. microvm.nix creates and formats
        # the image if absent, so a fresh directory needs no preparation.
        volumes = [
          {
            image = "${upperStoreDir}/state.img";
            mountPoint = config.supervm.dataDir;
            size = 4096;
          }
        ];
      };
    }
  )
]

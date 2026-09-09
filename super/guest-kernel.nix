# Guest kernel able to mount virtio-fs with `-o dax`, with a deterministic
# core image whose shareable ranges can be derived from the exact build.
#
# CONFIG_FUSE_DAX depends on CONFIG_FS_DAX, which nixpkgs ships unset, so no
# stock kernel can do this. FS_DAX itself needs only MMU and ZONE_DEVICE, both
# already enabled, so turning it on is enough.
#
# Core text is writable and unmerged during initialization. The patched kernel
# requests a one-way VMM seal before userspace. Only after KVM and host write
# protection are applied may crosvm enable KSM. Runtime static-call trampolines
# are excluded by the range producer; other text-patching paths are disabled.
#
# Worth checking the built config rather than assuming: where DAX is
# unavailable the guest falls back to ordinary reads instead of failing, so a
# missing option is invisible at boot.

{
  lib,
  linux_latest,
}:

linux_latest.override {
  kernelPatches = [
    {
      name = "supervm-direct-boot-sealing";
      patch = ./guest-kernel-patches/0003-supervm-direct-boot-sealing.patch;
    }
    {
      name = "fuse-dax-configurable-range-size";
      patch = ./guest-kernel-patches/0001-fuse-dax-make-the-mapping-range-size-configurable.patch;
    }
    {
      name = "virtiofs-dynamic-dax-memmap";
      patch = ./guest-kernel-patches/0002-virtiofs-populate-DAX-memmap-on-demand.patch;
    }
  ];

  structuredExtraConfig = with lib.kernel; {
    # VIRTIO_FS cannot be `y` while FUSE_FS is `m`; kconfig re-asks and the
    # generator aborts on the repeated question. Building both in also means
    # the guest can mount virtio-fs without loading modules.
    FUSE_FS = yes;
    VIRTIO_FS = yes;

    FS_DAX = yes;
    FUSE_DAX = yes;

    # The DAX window is handed out in ranges of this size, one range per file
    # at minimum. A store closure is mostly small files, so 2 MiB ranges need
    # a window many times the mapped data. 64 KiB ranges pack small files
    # into fewer live memmap chunks. Unused chunks carry no struct pages;
    # the dynamic-memmap patch releases them when their last range is freed.
    FUSE_DAX_SHIFT = freeform "16";

    # Drivers every SuperVM guest loads at boot. Built in, their text sits in
    # the kernel image ranges that are shared between guests; as modules each
    # guest would hold its own copy in vmalloc, and the initrd would have to
    # carry and load them.
    VIRTIO_PCI = yes;
    VIRTIO_MMIO = yes;
    VIRTIO_BLK = yes;
    VIRTIO_BALLOON = yes;
    VIRTIO_CONSOLE = yes;
    VSOCKETS = yes;
    VIRTIO_VSOCKETS = yes;
    EXT4_FS = yes;
    OVERLAY_FS = yes;

    # Keep the core executable and read-only data out of ordinary writable
    # mappings. Kernel-controlled text-patching paths can still create
    # temporary aliases for the excluded static-call trampoline pages.
    STRICT_KERNEL_RWX = yes;
    STRICT_MODULE_RWX = yes;
    DEBUG_WX = yes;

    # Keep linked addresses stable for the direct ELF boot manifest.
    RANDOMIZE_BASE = lib.mkForce no;

    # Remove facilities which generate or deliberately rewrite executable
    # kernel text after boot. The dependent `unset` entries remove nixpkgs'
    # common-config assertions for options hidden when FTRACE is disabled.
    # Keep runtime text updates outside the immutable core. Static-call
    # trampolines remain patchable and are excluded by the range producer.
    SUPERVM_BOOT_SEAL = yes;
    JUMP_LABEL = lib.mkForce unset;
    KGDB = lib.mkForce no;
    # Optional retbleed=stuff uses lazily generated core call thunks. The
    # immutable profile does not support it; other CPU mitigations remain enabled.
    MITIGATION_CALL_DEPTH_TRACKING = lib.mkForce no;
    FTRACE = lib.mkForce no;
    KPROBES = lib.mkForce no;
    BPF_JIT = lib.mkForce no;

    BPF_EVENTS = lib.mkForce unset;
    BPF_JIT_ALWAYS_ON = lib.mkForce unset;
    BPF_LSM = lib.mkForce unset;
    FTRACE_SYSCALLS = lib.mkForce unset;
    FUNCTION_GRAPH_RETVAL = lib.mkForce unset;
    FUNCTION_PROFILER = lib.mkForce unset;
    FUNCTION_TRACER = lib.mkForce unset;
    HID_BPF = lib.mkForce unset;
    NET_SCH_BPF = lib.mkForce unset;
    NET_DROP_MONITOR = lib.mkForce unset;
    RING_BUFFER_BENCHMARK = lib.mkForce unset;
    SCHED_CLASS_EXT = lib.mkForce unset;
    SCHED_TRACER = lib.mkForce unset;
    STACK_TRACER = lib.mkForce unset;
    UPROBE_EVENTS = lib.mkForce unset;

    # LIVEPATCH is not visible once its tracing dependencies are gone. Disable
    # both kexec entry points and crash-kernel support as well.
    CRASH_DUMP = lib.mkForce unset;
    KEXEC = lib.mkForce no;
    KEXEC_FILE = lib.mkForce no;
    KEXEC_HANDOVER = lib.mkForce no;
    KEXEC_JUMP = lib.mkForce unset;
    LIVEUPDATE = lib.mkForce unset;
    PROC_VMCORE = lib.mkForce unset;
    HIBERNATION = lib.mkForce no;

    # Modules remain enabled because the NixOS initrd and arbitrary caller
    # configurations rely on them. Their text lies outside the core ranges
    # emitted by kernel-image-ranges and remains protected by
    # STRICT_MODULE_RWX.
  };

  ignoreConfigErrors = false;
}

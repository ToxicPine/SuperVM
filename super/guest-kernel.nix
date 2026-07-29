# Guest kernel able to mount virtio-fs with `-o dax`, with a deterministic
# core image whose shareable ranges can be derived from the exact build.
#
# CONFIG_FUSE_DAX depends on CONFIG_FS_DAX, which nixpkgs ships unset, so no
# stock kernel can do this. FS_DAX itself needs only MMU and ZONE_DEVICE, both
# already enabled, so turning it on is enough.
#
# Selective host-side KSM does not require these pages to be immutable: KSM
# gives a writer a private copy. Disabling boot relocation makes the linked
# guest-physical addresses stable. The ranges become KSM-eligible before boot;
# early text patching therefore writes private pages, and KSM can merge only
# the pages whose final contents are identical.
#
# Worth checking the built config rather than assuming: where DAX is
# unavailable the guest falls back to ordinary reads instead of failing, so a
# missing option is invisible at boot.

{
  lib,
  linux_latest,
}:

linux_latest.override {
  structuredExtraConfig = with lib.kernel; {
    # VIRTIO_FS cannot be `y` while FUSE_FS is `m`; kconfig re-asks and the
    # generator aborts on the repeated question. Building both in also means
    # the guest can mount virtio-fs without loading modules.
    FUSE_FS = yes;
    VIRTIO_FS = yes;

    FS_DAX = yes;
    FUSE_DAX = yes;

    # Keep the core executable and read-only data out of ordinary writable
    # mappings. Kernel-controlled text-patching paths can still create
    # temporary aliases; KSM copy-on-write keeps those updates correct.
    STRICT_KERNEL_RWX = yes;
    STRICT_MODULE_RWX = yes;
    DEBUG_WX = yes;

    # The generated map records linked physical addresses. The x86 bzImage
    # decompressor uses those output addresses only when KASLR is disabled.
    RANDOMIZE_BASE = lib.mkForce no;

    # Remove facilities which generate or deliberately rewrite executable
    # kernel text after boot. The dependent `unset` entries remove nixpkgs'
    # common-config assertions for options hidden when FTRACE is disabled.
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

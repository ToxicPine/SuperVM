# Kernel image ranges

This package derives page-aligned core kernel text and read-only-data ranges
from the exact `vmlinux`, `System.map`, and effective kernel configuration
produced by `guestKernel`. Its output contains `$out/ranges.json` and an exact
`$out/kernel-image` symlink to the bzImage described by that map.

The derivation does not alter or hook the kernel build. It consumes the normal
build outputs afterward and fails unless it can verify the x86-64 load-address
calculation and the selected guest-kernel policy:

- the bzImage runtime-address calculation for crosvm's x86 load address
  resolves to the first `vmlinux` PT_LOAD address;
- the decompressed kernel occupies the physical addresses recorded in the
  `vmlinux` PT_LOAD headers;
- every emitted page belongs to a non-writable `PT_LOAD` segment;
- kernel address randomization is disabled;
- strict kernel W^X is enabled; and
- live patching, kexec, and hibernation are disabled.

Applying the map before boot is safe: private anonymous backing and KSM
eligibility are not guest read-only state. Early kernel writes simply populate
or copy private pages. KSM can merge pages later only when their final contents
are identical.

Consumers should boot the sibling `kernel-image` when applying `ranges.json`.
That pairing belongs in the launcher: the crosvm range-map interface remains
generic and deliberately does not interpret Linux or bzImage metadata.
Kernel-controlled text patching remains valid and receives normal
copy-on-write pages. If two VMs settle on different contents, KSM simply does
not merge those pages.

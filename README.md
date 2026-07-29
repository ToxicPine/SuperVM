# SuperVM

> [!WARNING] Experimental Demo, Not Audited! Works on x86_64.

SuperVM is an aggressively memory-optimized runner for heterogeneous VMs.
SuperVM VMs can run different packages, services, etc, but must use NixOS. Any
software packages from public Nix caches are stored exactly once on disk and
cached once in shared memory across all guests; private state remains private.

```console
nix run .#supervm -- ./my-vm
```

Yet, each guest retains its own kernel, distinct writable Nix store, and state
that is invisible to every other guest.

## Why this exists

SuperVM asks how far VM memory efficiency can be pushed under production
constraints. It demonstrates that we can exercise granular control over what
enters shared memory, avoiding broad cache-side-channel exposure. The same
mechanism has near-zero discovery cost at runtime: known pages are mapped
directly rather than found by scanning memory for duplicates, so the safer
approach is also faster than scan-based deduplication.

## Why it is so efficient

Firstly, SuperVM makes the core kernel text and rodata in each guest's memory
KSM-mergeable, so VMs running the same kernel share one physical copy of those
pages. Notably, no other guest memory is eligible. This cuts the overhead of the
read-only kernel image without scanning changeable or secret data, where
copy-on-write churn would hurt performance and merging could create side
channels.

Secondly, Nix packages can annotate which files, including binaries, are safe to
share; unmarked files never enter the shared cache. SuperVM applies that policy
file by file, serving annotated files from one common cache instead of copying
them into every VM. This captures most of the memory savings without exposing
secret-handling code to cross-guest cache side-channel attacks.

SuperVM is built around a patched crosvm, which provides the memory mappings
these mechanisms need. Its stripped build has Firecracker-class overhead: 6.7
MiB of measured host memory per VM outside guest RAM, versus 2.8 MiB for
Firecracker.

## Run it

Use a Linux host with Nix flakes and KVM.

Start two VMs in two terminals, each with its own state folder:

```console
nix run .#supervm -- ./vm-a
nix run .#supervm -- ./vm-b
```

An optional second argument selects a NixOS configuration, so the VMs can run
different systems:

```console
nix run .#supervm -- ./vm-web ./machines#web
nix run .#supervm -- ./vm-worker ./machines#worker
```

SuperVM builds each guest, adds its packages to the shared store, and boots it
with the state folder as its private layer.

Select `--dax=never`, `--dax=inode` (the default), or `--dax=always`:

```console
nix run .#supervm -- --dax=always ./vm-a
```

## Compare with vanilla crosvm

`lamevm` runs the same NixOS guest with mainline microvm.nix and nixpkgs crosvm:

```console
nix run .#lamevm
nix run .#lamevm -- ./machines#web
```

For a fair comparison, run multiple instances of each, since SuperVM's benefit
comes from sharing common pages between guests. If you just want to see how much
performance SuperVM can achieve, pass `--dax=always` so every common store page
is shared. Alternatively, to test the production-style fine-grained sharing
policy used to avoid cross-guest cache side channels, use the default
`--dax=inode` mode and add an `$out/nix-support/fsmeta` file to packages whose
files should be shared. Each line in `fsmeta` has the form
`snix.dax <path-relative-to-the-package-root>`, for example
`snix.dax bin/example`; listed files enter the shared cache, whereas unlisted
files stay out.

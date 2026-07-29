# crosvm private RAM maps

This flake packages a crosvm patch set intended to make KSM mergeability safe
and explicit for selected guest pages. It maps chosen guest-physical ranges as
private anonymous memory and, on request, marks them `MADV_MERGEABLE`; the rest
of guest RAM stays descriptor-backed for out-of-process devices.

The intended producer selects stable kernel text and rodata. KSM retains normal
copy-on-write semantics: the pages are neither frozen nor read-only, and the
host must still enable and tune its KSM scanner.

The source is pinned to nixpkgs crosvm revision
`ffbf0df34699f9670db015962bac83d0d417d7e7`.

## Behavior

- `--private-ram-map PATH` makes only the listed ranges private and omits them
  from vhost-user memory tables.
- `--private-ram-mergeable` applies `MADV_MERGEABLE`; a map alone does not opt
  pages into KSM.
- Private ranges receive `MADV_DONTFORK`, preventing divergent child COW state
  for descriptorless memory.
- crosvm handles reads, writes, loading, and balloon discard across mapping
  boundaries transparently.
- With `--disable-sandbox`, built-in virtio-fs remains in-process.

Vhost-user virtio-fs works provided descriptor chains do not reference private
ranges. Normal kernels allocate virtio buffers from writable memory, but an
unprotected VM has no IOMMU enforcement of that rule. A malicious driver can
therefore submit a private text or rodata address; the backend cannot service it
through the vhost-user memory table, and its failure behavior is
implementation-specific.

## Overlay use

```nix
{
  inputs.crosvm-super.url = "path:./flakes/crosvm";

  outputs = { nixpkgs, crosvm-super, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        {
          nixpkgs.overlays = [ crosvm-super.overlays.default ];
        }
      ];
    };
  };
}
```

The overlay replaces `pkgs.crosvm` and exposes the same derivation as
`pkgs.crosvm-super`.

## Running

```sh
crosvm run \
  --disable-sandbox \
  --private-ram-map /nix/store/...-guest-kernel-image-ranges/ranges.json \
  --private-ram-mergeable \
  [other crosvm arguments] \
  /nix/store/...-guest-kernel-image-ranges/kernel-image
```

The map contains absolute guest-physical ranges and is independent of kernel and
architecture metadata. The companion x86-64 artifact bundles the kernel image
described by its map; boot that image so its linked addresses match. Other
producers, such as an arm64 load-relative-to-absolute converter, can emit the
same schema.

Private RAM maps currently require KVM and `--disable-sandbox`. They reject
protected VMs, vmm-swap, file-backed RAM, VFIO, `pmem-ext2`, huge pages, locked
guest memory, GPU udmabuf, virtio-video, virtio-media, and non-filesystem
vhost-user frontends. In-process devices and vhost-user filesystem frontends
remain supported.

Schema version 1 requires only a page size and absolute GPA ranges:

```json
{
  "schemaVersion": 1,
  "pageSize": 4096,
  "ranges": [
    {
      "guestPhysicalStart": 16777216,
      "length": 1048576
    }
  ]
}
```

Ranges must be non-empty, page-aligned, non-overlapping, and contained within
one ordinary guest RAM region. Unknown fields are ignored for forward
compatibility.

## Patch set

1. `base: add private anonymous memory mappings`
2. `vm_memory: support private anonymous RAM regions`
3. `vm_memory: span adjacent guest memory regions`
4. `x86_64: coalesce adjacent E820 entries`
5. `crosvm: keep virtio-fs in-process without sandboxing`
6. `crosvm: add selective private RAM maps`

The patches come from the adjacent crosvm checkout's `private-ram-regions`
branch. Each builds independently; adjacent-region support precedes the RAM
layout splitting.

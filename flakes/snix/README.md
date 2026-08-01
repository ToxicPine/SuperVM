# Snix virtio-fs DAX

This flake packages a pinned Snix with virtio-fs DAX support. It is intended to
share only selected Nix store files across VMs: marked files are materialized
by content digest and mapped from one host cache, while unmarked files continue
through ordinary reads.

The default build uses crosvm's standard vhost-user shared-memory protocol,
per-inode DAX, and a shared, mmapable metadata index. The source is pinned to
Snix revision
`efbc95558ac72105dce13ee7bef679b766d0c69a`.

## Behavior

- `--dax-backing-dir DIR` gives `snix store virtiofs` and
  `snix castore virtiofs` a host-file cache for DAX mappings.
- Identical blobs use the same cached file, so VMs map the same page-cache
  pages rather than maintaining per-VM copies.
- Store paths can declare DAX eligibility and extended attributes in
  `nix-support/fsmeta`. With a guest mounted using `dax=inode`, only files
  marked `snix.dax` use DAX.
- Missing, invalid, unreadable, or oversized metadata is ignored. Unmarked
  files remain non-DAX.
- `snix store index PATH` builds an immutable index over the served store.
  Virtio-fs daemons read the path from `--metadata-index` or
  `SNIX_METADATA_INDEX` and share its read-only pages through the host page
  cache.
- Without a configured cache, mapping requests return `ENOSYS` and guests fall
  back to normal reads.

Because `nix-support/fsmeta` is part of the store path, its policy travels with
the NAR and is covered by the NAR hash and existing signatures.

## Package

The flake exposes one Snix composition: FUSE inode eviction, crosvm's
`SHMEM_MAP` transport, per-inode DAX, declared attributes, and the shared
metadata index. There are no non-index or alternate-transport package variants.

```sh
nix build ./flakes/snix#snix
```

The flake supports `x86_64-linux` and `aarch64-linux`. It also exposes the Snix
libraries and `lib.depotFor` for consumers that need the full patched depot.

## Overlay use

```nix
{
  inputs.snix-super.url = "path:./flakes/snix";

  outputs = { nixpkgs, snix-super, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        {
          nixpkgs.overlays = [ snix-super.overlays.default ];
        }
      ];
    };
  };
}
```

The overlay replaces `pkgs.snix` with the default package.

## Running

```sh
snix store virtiofs \
  --dax-backing-dir /var/cache/snix/dax \
  --metadata-index /run/user/1000/supervm/metadata.v1.index \
  --tag snix \
  /run/snix-store.sock
```

`SNIX_METADATA_INDEX` supplies the same value without repeating the flag for
each daemon. SuperVM sets it automatically and keeps the generated index on its
runtime tmpfs.

`--tag` applies to the `shmem-map` transport and advertises the virtio-fs tag
that crosvm should mount.

## Declaring per-inode DAX

Each line in `nix-support/fsmeta` has this form:

```text
name[=base64value] <path, to end of line>
```

For example:

```text
snix.dax bin/example
user.example=bWV0YWRhdGE= share/example.data
```

`snix.dax` marks a file for DAX. `user.*` entries are served as extended
attributes; other `snix.*` names are reserved for Snix policy. Blank lines and
`#` comments are ignored, and an empty path refers to the tree root.

See [patches/README.md](patches/README.md) for patch ordering, transport details,
the metadata design, and the patch-development workflow.

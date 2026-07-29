# Snix virtio-fs DAX

This flake packages a pinned Snix with virtio-fs DAX support. It is intended to
share only selected Nix store files across VMs: marked files are materialized
by content digest and mapped from one host cache, while unmarked files continue
through ordinary reads.

The default build uses crosvm's standard vhost-user shared-memory protocol and
supports per-inode DAX. The source is pinned to Snix revision
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
- Without a configured cache, mapping requests return `ENOSYS` and guests fall
  back to normal reads.

Because `nix-support/fsmeta` is part of the store path, its policy travels with
the NAR and is covered by the NAR hash and existing signatures.

## Packages

| Package                 | Mapping transport             | DAX policy  |
| ----------------------- | ----------------------------- | ----------- |
| `snix-fs-map`           | `SHARED_OBJECT_ADD` / `FsMap` | Whole mount |
| `snix-shmem-map`        | `SHMEM_MAP` / `SHMEM_UNMAP`   | Whole mount |
| `snix-fsmeta-fs-map`    | `SHARED_OBJECT_ADD` / `FsMap` | Per inode   |
| `snix-fsmeta-shmem-map` | `SHMEM_MAP` / `SHMEM_UNMAP`   | Per inode   |

`snix` and `default` select `snix-fsmeta-shmem-map`, the variant used by
SuperVM with crosvm.

```sh
nix build ./flakes/snix#snix
nix build ./flakes/snix#snix-fs-map
nix build ./flakes/snix#snix-shmem-map
nix build ./flakes/snix#snix-fsmeta-fs-map
nix build ./flakes/snix#snix-fsmeta-shmem-map
```

The flake supports `x86_64-linux` and `aarch64-linux`. It also exposes the Snix
libraries and `lib.depotsFor` for consumers that need the full patched depot.

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
  --tag snix \
  /run/snix-store.sock
```

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

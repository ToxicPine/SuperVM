# Snix patchsets

Each subdirectory is an ordered patch series on the revision pinned in
`../flake.nix`. The `patchsets` attribute there is authoritative: adding a file
here does nothing until it is listed, and it is also where a series that builds
on another declares that.

| Patchset     | Transport                                      | Adds                                         |
| ------------ | ---------------------------------------------- | -------------------------------------------- |
| `fs-map/`    | `SHARED_OBJECT_ADD` + 8-entry `FsMap`          | DAX for the whole mount                      |
| `shmem-map/` | `GET_SHMEM_CONFIG` + `SHMEM_MAP`/`SHMEM_UNMAP` | DAX for the whole mount                      |
| `fsmeta/`    | either                                         | per-inode DAX and served extended attributes |

`.old/` holds a superseded series, kept for reference and listed nowhere.

`fs-map/` and `shmem-map/` are alternatives: two ways to speak the mapping
protocol, differing only in transport. `fsmeta/` is not an alternative to
either — it is a continuation of one of them, and applies verbatim on top of
both, so it is one series rather than a per-baseline copy. Nothing in it is
transport-specific: per-inode DAX is negotiated in `FUSE_INIT` and communicated
per inode in lookup replies, which is in-band FUSE, so it does not care whether
`setupmapping` reaches the VMM as `SHARED_OBJECT_ADD` or as `SHMEM_MAP`.
`fuse-backend-rs` exposes the same `FsOptions::PERFILE_DAX`, `FUSE_ATTR_DAX`
and `Entry::attr_flags` at both `0.12` and `0.14`, so even the dependency bump
in `shmem-map/` changes nothing.

Those releases also both advertise FUSE protocol minor 7.33, even though they
already implement the extended init reply and the per-inode DAX fields. Linux
only interprets those fields from 7.36 onward. The `fsmeta-*` package variants
therefore apply
`patches/fuse-backend-rs/0001-fix-linux-advertise-FUSE-protocol-7.36.patch`
to that crate through crate2nix's `crateOverrides`. It is deliberately not a
Snix source patch: the compatibility bug and its eventual upstream removal
belong to the dependency.

## Choosing one

```sh
nix build ./flakes/snix#snix-fs-map
nix build ./flakes/snix#snix-shmem-map
nix build ./flakes/snix#snix-fsmeta-fs-map
nix build ./flakes/snix#snix-fsmeta-shmem-map
```

`snix`, `default`, the libraries, and the overlay select `fsmeta-shmem-map`:
crosvm's generic vhost-user frontend is what SuperVM actually drives.

For anything not exposed as a package, `lib.depotsFor <system>.<patchset>`
returns the whole depot tree.

## What the `fsmeta` patches add

`fs-map/` and `shmem-map/` make a mount either wholly mappable or not at all.
That is a blunt instrument: a mapping costs DAX window space and a materialized
host copy, and paying it for a large file read once is worse than reading it.

These four patches let a store path say which of its files are worth mapping,
and teach the daemon to negotiate `FUSE_CAP_PERFILE_DAX` and mark only those.

A tree cannot describe itself in the castore model without changing its own
digests, so it describes itself **in its contents**: a file at
`nix-support/fsmeta`, following the existing Nix convention for out-of-band
metadata about a store path. Each line is

```
name[=base64value] <path, to end of line>
```

with `#` comments, blank lines ignored, and an empty path meaning the tree root.
`user.*` names are served verbatim over virtio-fs as extended attributes;
`snix.*` names are interpreted by snix and not served — currently just
`snix.dax`, the per-inode mapping hint. With a guest mounted `dax=inode`,
unmarked files are non-DAX by default; no inverse marker is needed. Everything
about it is advisory: no such
file, unreadable, unparseable, or larger than 4 MiB all yield an empty
declaration and the filesystem behaves as though the tree said nothing.

Putting it in the tree rather than beside it is what makes the rest fall out for
free:

- **It travels.** It is an ordinary file, so `nix copy`, a binary cache, the Nix
  daemon protocol and a plain CppNix client all carry it without knowing it
  exists. A peer that ignores it reads exactly the same contents.
- **It is already authenticated.** It is inside the NAR, so it is covered by
  `NarHash` and therefore by the existing `Sig:` lines. No parallel fingerprint,
  no second signature, nothing new to verify — which matters if the hints are
  being used to bound shared-cache side channels on executables.
- **It already has an identity.** Two derivations differing only in their
  declaration produce different NARs, so different store paths, with no change
  to path computation. Castore still stores the byte-identical file contents
  once: differentiate at the store-path layer, deduplicate at the castore layer.

Unlike extended attributes or `FS_XFLAG_DAX`, it can also be produced from
inside an ordinary CppNix build. Nix installs a seccomp filter that fails every
`setxattr` with `ENOTSUP` — deliberately, because extended attributes are not
representable in a NAR — and that holds even with `__noChroot` and `sandbox =
relaxed`. Writing a file in `$out/nix-support/` is just a build step.

The series also fixes a latent bug it would otherwise have tripped over: the
inode tracker keyed regular files on their blob digest alone, so a file and an
executable file with identical contents shared an inode, and whichever was
looked up first decided the mode of both. Declared attributes join the mode in
that key for the same reason.

Which path carries a declaration is the caller's convention, not castore's, so
it is `FSSettings::fsmeta_path`. `snix store` sets the Nix one; `snix castore`
passes `None`, and build inputs likewise.

## Why `fs-map` and `shmem-map` differ

Alioth 0.12.0 — the newest release — speaks the older protocol: backend request
`SHARED_OBJECT_ADD` (id 6) carrying `FsMap { fd_offset, cache_offset, len,
flags }`, each an 8-entry `u64` array. Snix pins `vhost 0.6.1`, whose
`SlaveFsCacheReq` emits a byte-identical `VhostUserFSSlaveMsg` as `FS_MAP`
(also id 6), so `fs-map` needs no transport code at all.

The generic crosvm vhost-user frontend instead negotiates the standard
`CONFIG`, `MQ`, `BACKEND_REQ`, `REPLY_ACK`, and `SHMEM_MAP` protocol features.
It obtains the virtio-fs tag and request-queue count through `GET_CONFIG`, the
DAX window through `GET_SHMEM_CONFIG`, and sends mapping work back to the
backend as `SHMEM_MAP`/`SHMEM_UNMAP` requests.

The `shmem-map` series upgrades Snix's compatible rust-vmm stack to `vhost
0.16.0`, `vhost-user-backend 0.22.0`, and `fuse-backend-rs 0.14.0`, then uses
those implementations rather than carrying a private wire-protocol encoder. It
reports one cache region with ID 0 and the same 8 GiB window size as crosvm's
built-in virtio-fs device.

One trap in the older `fs-map` path: Alioth passes mapping flags straight into
`mmap`'s `prot`. `vhost`'s `MAP_R`/`MAP_W` are `0x1`/`0x2`, while
`fuse-backend-rs`'s `SetupmappingFlags` has `WRITE = 0x1`, `READ = 0x2`.
That transport must translate the opposite order explicitly.

## Working on a patchset

The flake consumes a pinned tarball, which is not a convenient place to edit
Rust. Use a scratch clone at the pinned revision and export from it:

```sh
git clone https://git.snix.dev/snix/snix.git && cd snix
git checkout efbc95558ac72105dce13ee7bef679b766d0c69a
git switch -c my-patchset
# ... commits ...
git format-patch --no-signature -o /path/to/supervm/flakes/snix/patches/<name>/ \
  efbc95558ac72105dce13ee7bef679b766d0c69a
```

Then list the files in `../flake.nix`. The scratch clone is a playground; the
patches plus the flake are the deliverable.

`applyPatches` uses `patch -p1`, which has no 3-way fallback — so a series meant
to apply on more than one baseline has to apply to each of them verbatim. Check
that with `git am --no-3way`, not `git am -3`.

## What a patchset has to provide

The two transport series should end up exposing the same surface, so the rest of
SuperVM does not care which is selected:

- `snix store virtiofs --dax-backing-dir <dir>` and the same flag on
  `snix castore virtiofs`
- `setupmapping`/`removemapping` on `SnixStoreFs`, reporting `ENOSYS` when no
  cache is configured so guests fall back to reads

The `shmem-map` series also exposes `--tag` (default `snix`), because crosvm's
generic frontend reads the virtio-fs identity from the backend's configuration.

The `fsmeta` patches add to that surface rather than changing it. Guests that do
not negotiate per-inode DAX, and store paths that declare nothing, behave
exactly as they do without it.

## Why DAX needs a materialization cache

Worth recording, because it constrains any implementation.

Snix serves file content lazily: `open()` resolves an inode to a **blob
digest** and `read()` streams from a chunked `BlobReader`, possibly backed by
remote storage. There is no host file descriptor anywhere in that path, but
mapping a page requires one.

So DAX forces blob content to be materialized into a real host file. That is
not one option among several; it is the only shape that works.

The useful consequence: if the cache is keyed by content digest and shared
host-wide, two VMs mapping the same store path map the same host file and
therefore the same page-cache pages. The "demonstrably shared host pages"
criterion falls out of the addressing scheme, rather than depending on KSM or on merely sharing a backend process.

## Standard

These are integration-branch changes written for upstream review, not a permanent fork. Each patch should solve the root problem for
users other than SuperVM, fit Snix's abstractions, keep SuperVM policy out of
generic code, and carry its own tests and documentation. Backwards
compatibility is not a goal; prefer one canonical path.

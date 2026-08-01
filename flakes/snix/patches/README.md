# Snix patchsets

Each subdirectory is an ordered upstream-review series on the revision pinned
in `../flake.nix`. The single `patches` list there is the authoritative SuperVM
composition: adding a file here does nothing until it is listed in that stack.

| Patchset     | Transport                                      | Adds                                         |
| ------------ | ---------------------------------------------- | -------------------------------------------- |
| `forget/`       | none — the composition base                    | FUSE FORGET refcounting and inode eviction   |
| `fs-map/`       | `SHARED_OBJECT_ADD` + 8-entry `FsMap`          | DAX for the whole mount                      |
| `shmem-map/`    | `GET_SHMEM_CONFIG` + `SHMEM_MAP`/`SHMEM_UNMAP` | DAX for the whole mount                      |
| `fsmeta/`       | either                                         | per-inode DAX and served extended attributes |
| `shared-index/` | either                                         | a shared, mmapable, read-only metadata index |

`.old/` holds a superseded series, kept for reference and listed nowhere.

`forget/` is the base of the supported composition: it makes the castore
inode tracker honour FUSE FORGET, so a long-lived mount stops leaking an inode
for every path a guest ever touches, and turns a request for an unknown or
since-evicted inode into `ESTALE` rather than a panic. It touches only
upstream's existing `fs` module and is a standalone upstream-facing fix in its
own right. Because eviction is what
forces the rest of the stack to cope with a missing inode at all — the tracker's
identity keys, the root-name and directory-child caches, and the DAX resolution
path — it sits underneath the transport and `fsmeta/`, which are rebased on top
of it.

`fs-map/` and `shmem-map/` are alternatives: two ways to speak the mapping
protocol, differing only in transport. Each applies verbatim on pristine and
on top of `forget/`. `fsmeta/` is not an alternative to
either — it is a continuation of one of them, and applies verbatim on top of
both `forget ++ fs-map` and `forget ++ shmem-map`, so it is one series rather
than a per-baseline copy. Where its inode-tracker changes meet `forget/`'s
eviction, `fsmeta/` updates that eviction to the new attribute-aware identity
keys — `evict` and `restore` remove and reinstate entries in the same reverse
maps, under the same points-back-at-this-inode ownership guard. Nothing in it is
transport-specific: per-inode DAX is negotiated in `FUSE_INIT` and communicated
per inode in lookup replies, which is in-band FUSE, so it does not care whether
`setupmapping` reaches the VMM as `SHARED_OBJECT_ADD` or as `SHMEM_MAP`.
`fuse-backend-rs` exposes the same `FsOptions::PERFILE_DAX`, `FUSE_ATTR_DAX`
and `Entry::attr_flags` at both `0.12` and `0.14`, so even the dependency bump
in `shmem-map/` changes nothing.

Those releases also both advertise FUSE protocol minor 7.33, even though they
already implement the extended init reply and the per-inode DAX fields. Linux
only interprets those fields from 7.36 onward. The supported package therefore
applies
`patches/fuse-backend-rs/0001-fix-linux-advertise-FUSE-protocol-7.36.patch`
to that crate through crate2nix's `crateOverrides`. It is deliberately not a
Snix source patch: the compatibility bug and its eventual upstream removal
belong to the dependency.

## Supported composition

```sh
nix build ./flakes/snix#snix
```

`snix`, `default`, the libraries, and the overlay all use
`forget ++ shmem-map ++ fsmeta ++ shared-index`. This is the only packaged
stack: crosvm's generic vhost-user frontend is what SuperVM drives, per-inode
DAX is its policy surface, and sharing the immutable metadata is part of the
design rather than an optional variant. `fs-map/` remains only as an alternate
upstream-review series. `lib.depotFor <system>` returns the patched depot tree.

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

## What the `shared-index` patches add

Serving a store over virtio-fs, castore's `InodeTracker` assigns an inode to
every distinct identity a guest touches and keeps that node's digest, size,
declared attributes and directory listing on its heap. For a large immutable
tree that replica is a few megabytes (measured at ~7–8 MiB per VM), and every
daemon serving the same content builds its own private copy — so N VMs pay it N
times, for identical, immutable data.

These four patches let that metadata be computed once, offline, into a flat file
that many daemons `mmap` read-only and share through the host page cache. An
indexed daemon answers `getattr`, `lookup`, `readdir`/`readdirplus`, the
extended attributes, DAX eligibility and the DAX `setupmapping` resolution
straight from the mapping — touching neither its heap nor the directory service.
The per-VM private metadata cost drops towards zero: one shared index, mapped
once host-wide, exactly as the digest-keyed DAX cache already shares file
*contents*.

The design mirrors the DAX cache's addressing insight. Inode numbers are
assigned **once, at build time — dense, deterministic, no hashing**. The builder
walks the roots through the directory service exactly as the filesystem would,
evaluating the same `fsmeta` declarations, and gives every distinct identity —
keyed on precisely what the tracker keys on: a file's `(digest, executable,
declared-subtree)`, a directory's `(digest, declared-subtree)`, a symlink's
target — one index inode counting up from a fixed base. The walk is
deterministic (roots and children in stored, sorted order; no timestamps, no
randomness), so the same store always produces byte-identical bytes and every
daemon mapping one file agrees on every inode *by construction*, with no
coordination. Determinism is the whole substitute for a shared allocator: the
artifact is the agreement.

The format is flat and zero-copy: a fixed header, a dense per-inode record
table, per-directory child tables sorted by name for binary search, a name/byte
pool, and a deduplicated extended-attribute section — little-endian, explicitly
sized, hand-rolled against the workspace's existing dependencies rather than
adding a serialization crate. Reading deserializes nothing into owned
structures; the file is validated in full on open (every offset, count and
cross-reference, treated as untrusted input, so a truncated or corrupt index is
a clean error, never UB) and the accessors then return small copies of
individual fields or `&[u8]` views into the mapping. The mapping itself is a few
lines of `libc`, since the crate already links it and a read-only file map is
exactly what shares page-cache pages between processes.

It relates to `fsmeta/` and `forget/` the way `fsmeta/` relates to the
transports: a continuation, not an alternative. It builds on `fsmeta`'s
attribute-aware identity — the index splits an inode by declaration exactly as
the tracker does, so `snix.dax` and `user.*` served from the index match the
declared values — and it presupposes `forget`'s lifetime model without needing
it. The `InodeTracker` remains, as an **overlay** for anything the index does
not cover — a root looked up that was not indexed, and its subtree — rebased to
allocate strictly above the index's fixed range, so the two inode spaces never
collide and overlay inodes keep the full forget/evict machinery.

Indexed inodes keep **no per-inode state at all**, and that is the point rather
than an optimisation. Their metadata is immutable and shared between every
daemon over the one file, so there is nothing to evict and nothing a `FORGET`
must draw down: a `FORGET` for an indexed inode is a no-op, and the inode stays
resolvable however many times it is forgotten. Keeping no state is what lets the
metadata be read-only and shared in the first place; the eviction machinery
exists only for the mutable overlay. Nothing in any of this is
transport-specific — the index is in-memory metadata and in-band FUSE replies —
so, like `fsmeta/`, it is one series applying verbatim on both
`forget ++ fs-map ++ fsmeta` and `forget ++ shmem-map ++ fsmeta`.

`snix store index` and `snix castore index` build an index — the former over the
store paths a `PathInfoService` lists, reading the `nix-support/fsmeta`
convention; the latter over a directory's children, which carry none — writing
it atomically. `snix store virtiofs` and `snix castore virtiofs` gain
`--metadata-index PATH`, which attaches one, mirroring how `--dax-backing-dir`
is plumbed. They also accept the same path through `SNIX_METADATA_INDEX`, so a
launcher can establish one shared index for every daemon without repeating the
flag.

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

## Eviction and live DAX mappings

Because `forget/` is the base, a composed stack can evict an inode while a guest
still holds a DAX mapping of it. A well-behaved guest sends `REMOVEMAPPING`
before `FORGET`, but a buggy or malicious one need not, so this has to be safe
regardless — and it is, without any per-inode pinning, because a live mapping
holds no inode-tracker state once it is established.

`setupmapping` resolves the inode to a blob digest exactly once, materializes
that blob into the digest-keyed cache, and hands the resulting descriptor to the
VMM. From then on the mapping is self-contained: the VMM owns a duplicated
descriptor and a position in its DAX window, and the cache owns the open
`fs::File`, keyed by content digest and held for the life of the cache — neither
is reached through the inode. `removemapping` is likewise identified by DAX
window position and forwarded to the VMM with no tracker lookup. `dax.rs` and
`virtiofs.rs` touch the inode tracker nowhere.

So evicting the inode drops only bookkeeping the live mapping never consults:
its `InodeData` and the reverse-map entry. The mapped pages stay mapped, the
cache file stays open, and a later `REMOVEMAPPING` still resolves. The one
observable effect of a `FORGET`-before-`REMOVEMAPPING` guest is that its own
mapping lingers in its own DAX window until it removes it or the VM stops —
bounded by the window size, self-inflicted, and not a backend leak, since the
inode itself is genuinely freed. The only tracker access on the mapping path,
`setupmapping`'s inode lookup, therefore just returns `ESTALE` for an evicted
inode like every other lookup in the stack, rather than pinning anything.

## Standard

These are integration-branch changes written for upstream review, not a permanent fork. Each patch should solve the root problem for
users other than SuperVM, fit Snix's abstractions, keep SuperVM policy out of
generic code, and carry its own tests and documentation. Backwards
compatibility is not a goal; prefer one canonical path.

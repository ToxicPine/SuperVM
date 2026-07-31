{
  description = "Snix with virtio-fs DAX support: pinned upstream plus a selectable patchset.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    snix-src = {
      url = "git+https://git.snix.dev/snix/snix.git?rev=efbc95558ac72105dce13ee7bef679b766d0c69a";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      snix-src,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      # The mapping protocol Alioth 0.12.0 speaks: backend request
      # SHARED_OBJECT_ADD carrying an 8-entry FsMap. Snix's pinned
      # vhost 0.6.1 already emits exactly this, so no transport work.
      fs-map = [
        ./patches/fs-map/0001-feat-castore-fs-add-a-materialization-cache-for-DAX-.patch
        ./patches/fs-map/0002-feat-castore-fs-serve-virtio-fs-DAX-mappings.patch
        ./patches/fs-map/0003-feat-cli-add-dax-backing-dir-to-the-virtiofs-daemons.patch
        ./patches/fs-map/0004-docs-add-a-guide-for-serving-a-store-to-VMs-with-DAX.patch
        ./patches/fs-map/0005-fix-castore-fs-advertise-the-protocol-features-DAX-n.patch
        ./patches/fs-map/0006-fix-castore-fs-complete-failed-virtio-descriptor-cha.patch
      ];

      # The standard vhost-user shared-memory protocol used by crosvm:
      # GET_SHMEM_CONFIG plus backend SHMEM_MAP/SHMEM_UNMAP requests.
      shmem-map = [
        ./patches/shmem-map/0001-feat-castore-fs-add-a-materialization-cache-for-DAX-.patch
        ./patches/shmem-map/0002-feat-castore-fs-serve-DAX-mappings-over-vhost-user-s.patch
        ./patches/shmem-map/0003-feat-cli-configure-virtio-fs-identity-and-DAX-mappin.patch
        ./patches/shmem-map/0004-fix-castore-fs-complete-failed-virtio-descriptor-cha.patch
      ];

      # An upstream-facing fix for snix's FUSE/virtio-fs filesystem: honour
      # FUSE FORGET so the castore inode tracker stops growing without bound
      # for the life of a mount, and return ESTALE (not a panic) for inodes
      # that have since been evicted. Standalone: it touches only upstream's
      # existing `fs` module and shares nothing with the DAX series.
      forget = [
        ./patches/forget/0001-fix-castore-fs-return-ESTALE-for-unknown-inodes.patch
        ./patches/forget/0002-fix-castore-fs-honour-FUSE-FORGET-and-bound-the-inod.patch
      ];

      # Per-inode DAX, driven by attributes a store path declares about itself
      # in a file it carries. Transport-independent: per-inode DAX is
      # negotiated in FUSE_INIT and communicated in lookup replies, so this
      # applies unchanged on top of either mapping transport above.
      fsmeta = [
        ./patches/fsmeta/0001-fix-castore-fs-do-not-share-an-inode-between-files-d.patch
        ./patches/fsmeta/0002-feat-castore-model-attributes-a-tree-declares-about-.patch
        ./patches/fsmeta/0003-feat-castore-fs-serve-the-attributes-a-tree-declares.patch
        ./patches/fsmeta/0004-feat-castore-fs-decide-DAX-per-inode-rather-than-per.patch
        ./patches/fsmeta/0005-fix-castore-fs-open-blob-readers-lazily.patch
      ];

      patchsets = {
        inherit fs-map shmem-map forget;

        # The inode-lifetime fix, a transport, and the metadata work stacked in
        # that order: a continuation rather than an alternative, so each lists
        # its prerequisites first and the order is explicit. `forget` is the
        # base because eviction is what makes the tracker's identity and the
        # DAX resolution paths have to cope with a missing inode at all; both
        # `fsmeta` and the transports are then adapted to it. `fsmeta` itself is
        # one series, shared verbatim, because nothing in it is
        # transport-specific.
        fsmeta-fs-map = forget ++ fs-map ++ fsmeta;
        fsmeta-shmem-map = forget ++ shmem-map ++ fsmeta;
      };

      patchedSource =
        pkgs: patches:
        if patches == [ ] then
          snix-src
        else
          pkgs.applyPatches {
            name = "snix-source-patched";
            src = snix-src;
            inherit patches;
          };

      depotFor =
        system: patches:
        import (patchedSource nixpkgs.legacyPackages.${system} patches) {
          localSystem = system;
        };

      depotsFor = system: lib.mapAttrs (_: patches: depotFor system patches) patchsets;

      libraries = [
        "build"
        "build-glue"
        "castore"
        "castore-http"
        "eval"
        "glue"
        "nar-bridge"
        "nix-compat"
        "nix-compat-derive"
        "nix-daemon"
        "serde"
        "store"
        "tracing"
      ];

      # fuse-backend-rs 0.14.0 already implements the FUSE 7.36 INIT_EXT
      # layout and per-inode DAX bits, but advertises protocol 7.33. Apply the
      # compatibility correction as a patch to that dependency rather than
      # modifying Snix's crate override machinery.
      fuseBackendRsAbiPatch = ./patches/fuse-backend-rs/0001-fix-linux-advertise-FUSE-protocol-7.36.patch;

      withFuseBackendRsAbiPatch =
        package:
        package.override (old: {
          crateOverrides = old.crateOverrides // {
            fuse-backend-rs =
              prev:
              let
                inherited = (old.crateOverrides.fuse-backend-rs or (_: { })) prev;
              in
              inherited
              // {
                patches = (inherited.patches or [ ]) ++ [ fuseBackendRsAbiPatch ];
              };
          };
        });

      snixCliFor =
        depot:
        depot.snix.cli.default-cli.override (old: {
          # Only these two command crates enable the virtiofs feature. Reuse
          # upstream's CLI composition so additions there flow through without
          # duplicating its package list here.
          paths = map (
            package:
            if
              builtins.elem package.crateName [
                "snix-cli-castore"
                "snix-cli-store"
              ]
            then
              withFuseBackendRsAbiPatch package
            else
              package
          ) old.paths;
        });
    in
    {
      packages = forAllSystems (
        system:
        let
          depots = depotsFor system;
          depot = depots.fsmeta-shmem-map;
          snixCli = snixCliFor depot;
        in
        lib.genAttrs libraries (name: depot.snix.${name})
        // lib.mapAttrs' (name: variant: {
          name = "snix-${name}";
          value = if lib.hasPrefix "fsmeta-" name then snixCliFor variant else variant.snix.cli.default-cli;
        }) depots
        // {
          # `virtiofs` is not a default feature of snix-cli-store; the combined
          # CLI is what enables it on Linux, and hence what provides
          # `snix store virtiofs`.
          default = snixCli;
          snix = snixCli;
        }
      );

      overlays.default = _final: prev: {
        inherit (self.packages.${prev.stdenv.hostPlatform.system}) snix;
      };

      lib = {
        inherit patchsets;
        snixSource = snix-src;

        inherit
          depotsFor
          snixCliFor
          withFuseBackendRsAbiPatch
          ;
      };
    };
}

{
  description = "Snix with indexed virtio-fs DAX support for SuperVM.";

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

      # There is one supported stack. SuperVM uses crosvm's standard
      # vhost-user shared-memory transport, per-inode DAX policy, and the
      # immutable shared metadata index. The subdirectories remain separate
      # upstream-review series; their order here is the product composition.
      patches = [
        ./patches/forget/0001-fix-castore-fs-return-ESTALE-for-unknown-inodes.patch
        ./patches/forget/0002-fix-castore-fs-honour-FUSE-FORGET-and-bound-the-inod.patch
        ./patches/shmem-map/0001-feat-castore-fs-add-a-materialization-cache-for-DAX-.patch
        ./patches/shmem-map/0002-feat-castore-fs-serve-DAX-mappings-over-vhost-user-s.patch
        ./patches/shmem-map/0003-feat-cli-configure-virtio-fs-identity-and-DAX-mappin.patch
        ./patches/shmem-map/0004-fix-castore-fs-complete-failed-virtio-descriptor-cha.patch
        ./patches/fsmeta/0001-fix-castore-fs-do-not-share-an-inode-between-files-d.patch
        ./patches/fsmeta/0002-feat-castore-model-attributes-a-tree-declares-about-.patch
        ./patches/fsmeta/0003-feat-castore-fs-serve-the-attributes-a-tree-declares.patch
        ./patches/fsmeta/0004-feat-castore-fs-decide-DAX-per-inode-rather-than-per.patch
        ./patches/fsmeta/0005-fix-castore-fs-open-blob-readers-lazily.patch
        ./patches/shared-index/0001-feat-castore-fs-add-a-flat-mmapable-metadata-index-f.patch
        ./patches/shared-index/0002-feat-castore-fs-build-a-metadata-index-from-a-set-of.patch
        ./patches/shared-index/0003-feat-castore-fs-serve-indexed-inodes-from-a-shared-i.patch
        ./patches/shared-index/0004-feat-cli-build-and-serve-a-shared-metadata-index.patch
      ];

      patchedSource =
        pkgs:
        pkgs.applyPatches {
          name = "snix-source-patched";
          src = snix-src;
          inherit patches;
        };

      depotFor =
        system:
        import (patchedSource nixpkgs.legacyPackages.${system}) {
          localSystem = system;
        };

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
          depot = depotFor system;
          snixCli = snixCliFor depot;
        in
        lib.genAttrs libraries (name: depot.snix.${name})
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
        inherit patches;
        snixSource = snix-src;

        inherit
          depotFor
          snixCliFor
          withFuseBackendRsAbiPatch
          ;
      };
    };
}

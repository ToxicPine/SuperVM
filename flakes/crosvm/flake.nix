{
  description = "crosvm with selectively private guest RAM regions";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/624af665418d3c65d544145b4d34ad696439570e";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      overlay = final: prev: {
        crosvm-super = prev.crosvm.overrideAttrs (
          old:
          assert final.lib.assertMsg (
            (old.src.rev or null) == "ffbf0df34699f9670db015962bac83d0d417d7e7"
          ) "crosvm-super patches require crosvm revision ffbf0df34699f9670db015962bac83d0d417d7e7";
          {
            pname = "crosvm-super";
            # SuperVM uses raw block devices, serial, vsock, and a generic
            # vhost-user virtio-fs frontend. Keep balloon solely because
            # microvm.nix uses its --no-balloon flag when the device is off.
            cargoBuildNoDefaultFeatures = true;
            cargoBuildFeatures = [ "balloon" ];
            cargoCheckNoDefaultFeatures = true;
            cargoCheckFeatures = [ "balloon" ];
            patches = (old.patches or [ ]) ++ [
              ./patches/0001-base-add-private-anonymous-memory-mappings.patch
              ./patches/0002-vm_memory-support-private-anonymous-RAM-regions.patch
              ./patches/0003-vm_memory-span-adjacent-guest-memory-regions.patch
              ./patches/0004-x86_64-coalesce-adjacent-E820-entries.patch
              ./patches/0005-crosvm-keep-virtio-fs-in-process-without-sandboxing.patch
              ./patches/0006-crosvm-add-selective-private-RAM-maps.patch
              ./patches/0007-crosvm-name-private-guest-RAM-regions-for-host-accounting.patch
            ];
          }
        );

        crosvm = final.crosvm-super;
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ overlay ];
          };
        in
        {
          default = pkgs.crosvm-super;
          crosvm = pkgs.crosvm-super;
          inherit (pkgs) crosvm-super;
        }
      );

      checks = forAllSystems (system: {
        build = self.packages.${system}.default;
      });
    };
}

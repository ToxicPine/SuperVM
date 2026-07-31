{
  description = "Boot a NixOS microVM from one directory of persistent state.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    snix.url = "path:./flakes/snix";
    snix.inputs.nixpkgs.follows = "nixpkgs";

    microvm-super.url = "github:ToxicPine/microvm.nix/supervm";
    microvm-super.inputs.nixpkgs.follows = "nixpkgs";

    microvm-lame.url = "github:ToxicPine/microvm.nix/lamevm";
    microvm-lame.inputs.nixpkgs.follows = "nixpkgs";

    crosvm-super.url = "path:./flakes/crosvm";
    crosvm-super.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      snix,
      microvm-super,
      microvm-lame,
      crosvm-super,
    }:
    let
      systems = [
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      defaultGuestFor =
        system:
        import ./super/default-guest.nix {
          inherit nixpkgs system;
        };

      vmPackagesOverlay =
        _final: prev:
        {
          crosvm = crosvm-super.packages.${prev.stdenv.hostPlatform.system}.crosvm-super;
        };

      templateModules = import ./super/template.nix {
        overlayStoreModule = self.nixosModules.overlayStore;
        microvm = microvm-super;
      };

      mkLameRunner = import ./lame/mk-runner.nix {
        inherit defaultGuestFor;
        guestKernelFor = system: self.packages.${system}.guest-kernel;
        microvm = microvm-lame;
      };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          guestKernel = import ./super/guest-kernel.nix {
            inherit (pkgs) lib linux_latest;
          };
        in
        {
          inherit (snix.packages.${system}) snix;

          supervm = pkgs.callPackage ./super/supervm.nix {
            inherit (snix.packages.${system}) snix;
            inherit self;
          };

          lamevm = pkgs.callPackage ./lame/lamevm.nix {
            inherit self;
          };

          # Imported rather than callPackage'd: callPackage would replace the
          # kernel's own `.override` with its own, and NixOS overrides kernels
          # with `features` while evaluating `microvm.kernel`.
          guest-kernel = guestKernel;

          inherit (crosvm-super.packages.${system}) crosvm-super;

          guest-kernel-image-ranges = pkgs.callPackage ./super/kernel-image-ranges {
            inherit guestKernel;
          };
        }
      );

      # The SuperVM-specific guest wiring: the overlay store's lower layer
      # served by Snix, and the transport carrying its metadata. This is policy
      # that deliberately does not belong in microvm.nix, whose equivalent
      # options stay generic.
      nixosModules.overlayStore = ./super/overlay-store.nix;

      overlays.default = vmPackagesOverlay;

      apps = forAllSystems (system: {
        default = self.apps.${system}.supervm;
        supervm = {
          type = "app";
          program = "${self.packages.${system}.supervm}/bin/supervm";
          meta.description = "Boot a SuperVM with persistent private state";
        };
        lamevm = {
          type = "app";
          program = "${self.packages.${system}.lamevm}/bin/lamevm";
          meta.description = "Boot the vanilla microvm.nix baseline";
        };
      });

      # Reachable so `supervm` can evaluate a composed guest at run time
      # against these pinned inputs rather than an ambient nixpkgs. Its
      # arguments are implementation detail and stay in the let above.
      lib.mkSuperRunner = import ./super/mk-runner.nix {
        inherit (nixpkgs) lib;
        inherit templateModules defaultGuestFor;
        guestKernelFor = system: self.packages.${system}.guest-kernel;
        vmPackagesModule =
          { lib, ... }:
          {
            nixpkgs.overlays = lib.mkAfter [ vmPackagesOverlay ];
          };
      };

      lib.mkLameRunner = mkLameRunner;

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          crosvmSuper = crosvm-super.packages.${system}.crosvm-super;
          crosvmSuperCli = pkgs.runCommand "crosvm-super-cli" { } ''
            mkdir -p "$out/bin"
            ln -s ${crosvmSuper}/bin/crosvm "$out/bin/crosvm-super"
          '';
          crosvmLameCli = pkgs.runCommand "crosvm-lame-cli" { } ''
            mkdir -p "$out/bin"
            ln -s ${pkgs.crosvm}/bin/crosvm "$out/bin/crosvm-lame"
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              snix.packages.${system}.snix
              crosvmSuperCli
              crosvmLameCli
            ];
          };
        }
      );
    };
}

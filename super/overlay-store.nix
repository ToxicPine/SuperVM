# Composes the guest's /nix/store as Nix's local-overlay store, with the lower
# layer served by Snix.
#
# The lower store reaches the guest by two different routes, because they carry
# different things:
#
#   file contents  -> virtio-fs, served by `snix store virtiofs`
#   path metadata  -> the Nix daemon protocol, served by `snix nix-daemon`
#
# Both are backed by the same castore, which is what makes them describe one
# immutable store rather than two that happen to agree.
#
# The metadata route needs a transport rather than a share: a unix socket
# cannot be reached across virtio-fs, since `connect()` resolves the path to an
# inode and the guest kernel has no listener bound to the host's inode. We
# bridge it over vsock instead.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.supervm;
in
{
  options.supervm = with lib; {
    enable = mkEnableOption "a /nix/store composed from a Snix lower store";

    dataDir = mkOption {
      type = types.path;
      default = "/data";
      description = ''
        Mount point of this VM's private state volume, holding the overlay's
        upper and work directories along with the Nix database and logs.

        Deliberately outside `/nix`, which is left holding nothing but the
        merged store the guest is meant to use. This is one VM's own disk,
        which happens to supply the overlay's upper layer; the lower store
        lives under `/lower-store`. Each of the three is private, shared, or
        merged, and having one place each makes which is which visible.

        This must be a real filesystem on a volume: OverlayFS requires an upper
        layer supporting `trusted.*`/`user.*` xattrs and valid `d_type`, which
        virtio-fs does not provide.
      '';
    };

    lowerTag = mkOption {
      type = types.str;
      default = "nix-lower";
      description = "virtio-fs tag for the lower store's contents.";
    };

    lowerDir = mkOption {
      type = types.path;
      default = "/lower-store/store";
      description = ''
        Where the lower store's contents are mounted in the guest.

        Kept beside {option}`lowerStoreDaemonSocket` under `/lower-store`, so the two
        routes to one store - its files and its metadata - sit together rather
        than in unrelated parts of the filesystem.
      '';
    };

    lowerStoreFsSocket = mkOption {
      type = types.str;
      description = ''
        Host-side vhost-user socket serving the lower store's contents.

        Whoever runs that server owns its lifetime; microvm.nix only connects
        to the socket. For SuperVM that is the `supervm` wrapper, because the
        castore and DAX cache behind it are shared between VMs and outlive any
        one of them.

        Distinct from {option}`lowerStoreDaemonSocket`, which is inside the guest and
        carries metadata rather than contents.
      '';
    };

    lowerStoreDaemonSocket = mkOption {
      type = types.path;
      default = "/lower-store/socket";
      description = ''
        Guest-side unix socket proxying to the shared Snix Nix daemon, used as
        the local-overlay store's `lower-store`.
      '';
    };

    lowerStoreDaemonPort = mkOption {
      type = types.port;
      default = 5000;
      description = "vsock port on which the host serves the Snix Nix daemon.";
    };

    dax = {
      mode = mkOption {
        type = types.enum [
          "never"
          "inode"
          "always"
        ];
        default = "inode";
        description = ''
          DAX policy for the lower store. `never` uses ordinary virtio-fs
          reads, `inode` maps only files selected by the Snix metadata policy,
          and `always` maps every regular file.

          The active modes require a guest kernel with `CONFIG_FUSE_DAX`,
          which stock nixpkgs kernels do not provide.
        '';
      };

      window = mkOption {
        type = with types; nullOr ints.positive;
        default = 8 * 1024 * 1024 * 1024;
        description = ''
          Size of the DAX window, for hypervisors that expect the VMM to pick
          one. Leave null for those that ask the server instead; see
          {option}`microvm.shares.*.dax.window`.
        '';
      };
    };

  };

  config = lib.mkIf cfg.enable {
    microvm.shares = [
      {
        proto = "virtiofs";
        tag = cfg.lowerTag;
        mountPoint = cfg.lowerDir;
        readOnly = true;
        server.socket = cfg.lowerStoreFsSocket;
        inherit (cfg) dax;
      }
    ];

    microvm.storeOverlay = {
      inherit (cfg) lowerDir;
      upperDir = "${cfg.dataDir}/upper-store";
      workDir = "${cfg.dataDir}/work";
      stateDir = "${cfg.dataDir}/nix-state";
      logDir = "${cfg.dataDir}/log";
      lowerStore = "unix://${cfg.lowerStoreDaemonSocket}";

      # Nix cannot recognise this as an overlay of two local stores: the lower
      # layer is a virtio-fs mount whose metadata lives behind a daemon.
      checkMount = false;
    };

    # The guest end of the metadata transport. Nix speaks `unix://`, so the
    # vsock connection is presented as a socket at the expected path.
    systemd.services.supervm-lower-store = {
      description = "Proxy to the shared Snix lower store";
      before = [ "nix-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.JoinsNamespaceOf = [ ];
      serviceConfig = {
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${builtins.dirOf cfg.lowerStoreDaemonSocket}";
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.socat)
          "UNIX-LISTEN:${cfg.lowerStoreDaemonSocket},fork,unlink-early,mode=0666"
          "VSOCK-CONNECT:2:${toString cfg.lowerStoreDaemonPort}"
        ];
        Restart = "always";
      };
    };

    # The daemon opens the lower store when it starts, so its proxy must already
    # be listening. The socket may listen earlier: ordering this service before
    # sockets.target would cycle through its own default dependency on
    # basic.target.
    systemd.services.nix-daemon = {
      after = [ "supervm-lower-store.service" ];
      requires = [ "supervm-lower-store.service" ];
    };

    # Nix must not be told to garbage collect or optimise a store whose lower
    # layer it does not own.
    nix.optimise.automatic = false;
    nix.settings.auto-optimise-store = false;
  };
}

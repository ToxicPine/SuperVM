{
  address,
  index,
  mac,
  tap,
}:
{
  pkgs,
  ...
}:
let
  webRoot = pkgs.runCommand "supervm-bench-web-root" { } ''
    mkdir -p "$out"
    printf 'ready\n' >"$out/health"
    dd if=/dev/zero of="$out/payload.bin" bs=1048576 count=1 status=none
  '';
in
{
  networking = {
    hostName = "svbench-${toString index}";
    firewall.allowedTCPPorts = [ 80 ];
    useNetworkd = true;
  };

  systemd.network = {
    enable = true;
    networks."10-benchmark" = {
      address = [ "${address}/16" ];
      matchConfig.Name = "e*";
      networkConfig.DHCP = "no";
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts.default = {
      default = true;
      root = webRoot;
    };
  };

  microvm = {
    crosvm.extraArgs = [ "--balloon-page-reporting" ];
    interfaces = [
      {
        id = tap;
        inherit mac;
        type = "tap";
      }
    ];
  };

  system.stateVersion = "24.05";
}

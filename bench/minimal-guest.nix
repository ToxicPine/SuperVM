{
  lib,
  modulesPath,
  ...
}:
{
  imports = [ "${modulesPath}/profiles/minimal.nix" ];

  boot = {
    blacklistedKernelModules = [ "kvm_amd" ];
    kernelModules = [ "virtio_balloon" ];
    kernelParams = [
      "loglevel=3"
      "quiet"
      "reboot=t"
      "systemd.show_status=auto"
    ];
  };

  services = {
    dbus.enable = lib.mkForce false;
    journald = {
      storage = "volatile";
      extraConfig = ''
        RuntimeMaxUse=8M
        ForwardToConsole=no
      '';
    };
    logind.enable = false;
    nscd.enable = false;
    timesyncd.enable = false;
    udisks2.enable = false;
  };

  systemd.oomd.enable = false;
  system.nssModules = lib.mkForce [ ];

  nix = {
    channel.enable = false;
    gc.automatic = false;
    optimise.automatic = false;
    settings.auto-optimise-store = false;
  };

  security = {
    audit.enable = false;
    sudo.enable = false;
  };

  console.enable = false;
  programs.command-not-found.enable = false;

  documentation = {
    enable = false;
    doc.enable = false;
    info.enable = false;
    man.enable = false;
    nixos.enable = false;
  };

  environment = {
    defaultPackages = lib.mkForce [ ];
    systemPackages = [ ];
  };
}

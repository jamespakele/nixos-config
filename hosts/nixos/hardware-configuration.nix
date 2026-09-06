# PLACEHOLDER — nixos-generate-config overwrites this file at install time
# (BOOTSTRAP.md Phase 1). It must stay evaluable on its own:
#   - NO self-import (the old placeholder had
#     `imports = [ ./hardware-configuration.nix ];` — infinite recursion).
#   - Machine-specific hardware config (NVIDIA, kernel params) lives in
#     configuration.nix instead, because this file gets replaced.
{ config, pkgs, lib, ... }: {
  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    # Placeholder value — the installer replaces this whole file with the
    # machine's real generated hardware config before anything mounts.
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
  swapDevices = [ ];
  nixpkgs.hostPlatform = "x86_64-linux";
}
{ config, pkgs, lib, ... }: {
  imports = [ ./hardware-configuration.nix ];

  ############################################################
  # PLACEHOLDER — replaced during install (BOOTSTRAP.md Phase 1.4):
  #   sudo nixos-generate-config --root /mnt
  #   cp /mnt/etc/nixos/hardware-configuration.nix \
  #      ~/nixos-config/hosts/nixos/hardware-configuration.nix
  #
  # The block below matches the documented partition layout
  # (ESP labeled BOOT, root labeled nixos). It will be overwritten
  # by the generated file either way.
  ############################################################

  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
  swapDevices = [ ];
  nixpkgs.hostPlatform = "x86_64-linux";

  # NVIDIA (RTX 4070 Super — Ada, open kernel module)
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  boot.kernelParams = [ "nvidia_drm.fbdev=1" ]; # needed for COSMIC on NVIDIA
  hardware.graphics.enable = true;
}
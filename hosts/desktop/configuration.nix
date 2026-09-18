{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    ../../modules/shared.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  networking.hostName = "nixos-live";

  users.users.pakele = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "changeme";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINwvGkgylG5py9WmplQYFTaDBGph1i03LA9GlcE4Tb4N james@pakele.ai"
    ];
  };

  # live medium convenience
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = true;

  # broad hardware support for live boot on unknown machines
  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "usbhid" "usb_storage" "ahci"
    "amdgpu" "r8169" "e1000e" "virtio_pci" "virtio_blk"
  ];
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.extraModulePackages = [ ];
  # NVIDIA: out-of-tree module; loaded by udev when the GPU is present.
  # Do NOT put "nvidia" in initrd lists — modules-shrunk fails on in-tree-only lookup.
  hardware.nvidia.modesetting.enable = true;

  system.stateVersion = "26.05";
}
{ config, pkgs, ... }: {
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "Pacific/Honolulu";
  i18n.defaultLocale = "en_US.UTF-8";

  # NOTE: pakele is intentionally declared WITHOUT a password. This repo is
  # public — a committed password would be a known credential to
  # anyone who can read it. The bootstrap sets the password at install time
  # (bootstrap.sh runs `nixos-enter --root /mnt -c 'passwd pakele'` after
  # nixos-install; the manual path in BOOTSTRAP.md does the same), and
  # nixos-install sets root's password interactively. Never "fix" a locked
  # account by committing a password here.
  users.users.pakele = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "networkmanager" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINwvGkgylG5py9WmplQYFTaDBGph1i03LA9GlcE4Tb4N james@pakele.ai" ];
  };

  services.openssh.enable = true;

  # The NVIDIA proprietary driver is unfree (unfreeRedistributable) — without
  # this the eval/build refuses at nvidia-x11. Caught by the eval gate
  # 2026-09-05, before it could fail mid-install.
  nixpkgs.config.allowUnfree = true;

  # Desktop sessions — enabled now; COSMIC added later via flake input (Phase 3)
  programs.hyprland.enable = true;

  # NVIDIA (RTX 4070 Super — Ada, open kernel module). Lives here, NOT in
  # hardware-configuration.nix: that file is regenerated at install/rebuild
  # time and would silently drop it.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = true; # boolean in 26.05 (verified against hardware/video/nvidia.nix)
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  boot.kernelParams = [ "nvidia_drm.fbdev=1" ]; # needed for COSMIC on NVIDIA
  hardware.graphics.enable = true;

  # Shared data partition (backups: .ssh, pi-backup). Declared here, not in
  # hardware-configuration.nix — that file is regenerated at install time.
  # nofail: boot proceeds even if the data disk is absent (new machine /
  # recovery scenarios).
  fileSystems."/srv/data" = {
    device = "/dev/disk/by-label/data";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  environment.systemPackages = with pkgs; [
    vim
  ];

  # Keep some room for generations
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "26.05";
}
{ config, pkgs, ... }: {
  imports = [ ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "Pacific/Honolulu";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.pakele = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "networkmanager" ];
    openssh.authorizedKeys.keys = [ ]; # add your pubkey here pre-install
  };

  services.openssh.enable = true;

  # Desktop sessions — enabled now; COSMIC added later via flake input (Phase 3)
  programs.hyprland.enable = true;

  environment.systemPackages = with pkgs; [
    vim
  ];

  # Keep some room for generations
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  system.stateVersion = "25.11";
}
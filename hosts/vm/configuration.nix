{ config, pkgs, ... }:

{
  nix.settings = {
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  networking.hostName = "vm";
  networking.networkmanager.enable = true;

  time.timeZone = "Pacific/Honolulu";
  i18n.defaultLocale = "en_US.UTF-8";

  # niri compositor
  programs.niri.enable = true;

  # noctalia shell (package + recommended services: NetworkManager, BT, UPower, power profiles)
  programs.noctalia = {
    enable = true;
    recommendedServices.enable = true;
    systemd.enable = true;
  };

  # greetd with niri session (noctalia-greeter optional later)
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd niri-session";
        user = "greeter";
      };
    };
  };

  # VM niceties
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;
  services.openssh.enable = true;

  users.users.pakele = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "changeme"; # replace with hashed password after first boot
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINwvGkgylG5py9WmplQYFTaDBGph1i03LA9GlcE4Tb4N james@pakele.ai"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    curl
    foot
  ];

  system.stateVersion = "26.05";
}
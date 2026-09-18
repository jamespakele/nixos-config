{
  description = "NixOS config (niri + noctalia)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
  };

  outputs =
    { self, nixpkgs, noctalia }:
    let
      system = "x86_64-linux";
      sharedModule = import ./modules/shared.nix;
    in
    {
      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/vm/configuration.nix
          noctalia.nixosModules.default
        ];
      };

      # Bootable ISO with the niri+noctalia desktop baked in.
      # Build:  nix build .#iso
      # Result: result/iso/*.iso — dd to USB, boot anywhere, live desktop.
      packages.${system}.iso = (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/desktop/configuration.nix
          noctalia.nixosModules.default
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          { nixpkgs.config.allowUnfree = true; }
        ];
      }).config.system.build.isoImage;
    };
}
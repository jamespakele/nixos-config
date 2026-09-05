{
  description = "Agent-driven NixOS config: pakele@nixos (RTX 4070 Super, Hyprland, COSMIC, pi/omp)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Uncomment when ready for COSMIC (Phase 3 in BOOTSTRAP.md).
    # Run `sudo nixos-rebuild test` once after adding this input, BEFORE
    # enabling COSMIC packages — it sets up binary substituters.
    # nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/nixos/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.pakele = import ./home.nix;
          }
        ];
      };
    };
}
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
    in
    {
      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/vm/configuration.nix
          noctalia.nixosModules.default
        ];
      };
    };
}
# nixos-config

Agent-driven NixOS configuration. One flake, one machine definition, everything declarative.

- `flake.nix` — entry point: nixpkgs 26.05 + home-manager (+ COSMIC via nixos-cosmic)
- `hosts/nixos/configuration.nix` — system config (NVIDIA, Hyprland, base services)
- `hosts/nixos/hardware-configuration.nix` — **placeholder**; replaced from the installer (see BOOTSTRAP.md)
- `home.nix` — user environment: nodejs 22 + bun (pi/omp runtimes), git, tmux
- `BOOTSTRAP.md` — the full migration + agent-bootstrap playbook

## Daily use

```bash
cd ~/nixos-config
# edit flake...
sudo nixos-rebuild switch --flake ~/nixos-config#nixos
git add -A && git commit -m "..." && git push   # after every working switch
```

Rollback: reboot → pick previous generation in the boot menu.

New machine / fresh disk: boot a NixOS ISO and follow `BOOTSTRAP.md` phase 1.
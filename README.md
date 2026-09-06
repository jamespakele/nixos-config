# nixos-config

Agent-driven NixOS configuration for **x86-64 machines with NVIDIA GPUs**
(user `pakele`, host `nixos`, Honolulu time). One flake, one machine
definition, everything declarative — installed from the USB kit in
`bare-metal/`. Different hardware? Adapt `configuration.nix` (the NVIDIA
block) and set your user/timezone — the kit's install process itself is
hardware-agnostic.

- `flake.nix` — entry point: nixpkgs 26.05 + home-manager (+ COSMIC later)
- `hosts/nixos/configuration.nix` — system config (user, NVIDIA, Hyprland,
  data partition, services). Machine-specific settings live HERE.
- `hosts/nixos/hardware-configuration.nix` — placeholder; the installer
  replaces it with the generated file (regenerated every install).
- `home.nix` — user environment: nodejs 22 + bun (pi/omp runtimes), git, tmux
- `bare-metal/` — the install kit: `bootstrap.sh` (ISO installer with
  device-selection menus and safety gates), `first-boot.sh` (restore + switch
  + push), `agent-setup.sh` (pi → omp), `test-parser.sh` (fixture tests)
- `BOOTSTRAP.md` — the full playbook: cut the USB kit, one command, reboot,
  two commands.

## Daily use

```bash
cd ~/nixos-config
# edit flake...
sudo nixos-rebuild build --flake ~/nixos-config#nixos   # build first
sudo nixos-rebuild switch --flake ~/nixos-config#nixos  # then switch
git add -A && git commit -m "..." && git push             # after every working switch
```

Rollback: reboot → pick previous generation in the boot menu.

New machine / fresh disk: see `BOOTSTRAP.md` Phase 1 (USB kit).
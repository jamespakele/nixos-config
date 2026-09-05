# BOOTSTRAP — CachyOS → NixOS, agent-first

Goal: minimal NixOS installed from this repo, pi working within minutes of
first boot, then pi installs omp, then omp builds out the rest of the system
declaratively. Hyprland enabled from phase 1; COSMIC added last (phase 3).

```
edit flake → sudo nixos-rebuild switch --flake ~/nixos-config#nixos → commit+push
```

NixOS makes every `switch` a rollback generation — agent mistakes cost a
reboot, not a reinstall.

## Phase 0 — now, on CachyOS (before you wipe anything)
1. **Back up state to the data partition** — `/srv/data` (ext4, label
   `data`, nvme0n1p4, 489G). It survives the install because we reuse
   nvme0n1's existing partitions (see Phase 1 — never re-partition this disk):
   ```bash
   mkdir -p /srv/data/.ssh /srv/data/pi-backup
   cp -a ~/.ssh/. /srv/data/.ssh/          # DONE 2026-09-05, checksums verified
   cp -a ~/.pi /srv/data/pi-backup/        # extensions/themes/skills/sessions
   ```
   The repo is safe on GitHub; `~/.pi` and `~/.ssh` are not.
2. Skim `hosts/nixos/configuration.nix`: set `time.timeZone` to yours, add
   your SSH pubkey to `users.users.pakele.openssh.authorizedKeys.keys`,
   rename the host (`nixos`) if you want something else — rename means
   updating `flake.nix`, the `hosts/nixos/` dir name, and every
   `--flake ~/nixos-config#<host>` command. Default name works fine.
3. Commit + push (repo is public so the ISO can fetch it without auth):
   ```bash
   cd ~/nixos-config && git add -A && git commit -m "bootstrap" && git push
   ```
4. Download the **minimal** NixOS ISO (25.11) → USB:
   ```bash
   # dd or Ventoy; example:
   sudo dd if=nixos-minimal-25.11*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

## Phase 1 — install (from the ISO)

1. Boot USB (disable Secure Boot if on; CachyOS already left you UEFI).
2. **Reuse the existing nvme0n1 partitions — do NOT run sgdisk on this disk**
   (nvme0n1p4 is the data partition with your backups). CachyOS layout:
   p1 = ESP (vfat, 512M, keep), p2 = ext4 (782G) = **Linux Mint — the stable
   rescue boot, never touched**, p3 = btrfs root (590G, reformat to nixos),
   p4 = ext4 `data` (489G, KEEP — shared by Mint + NixOS, incl. the hermes
   install and `/srv/data/.ssh` backups).
   ```bash
   sudo mkfs.ext4 -L nixos /dev/nvme0n1p3        # wipe old CachyOS root only
   sudo mount /dev/disk/by-label/nixos /mnt
   sudo mkdir -p /mnt/boot && sudo mount /dev/nvme0n1p1 /mnt/boot
   ```
   Note the ESP (p1) is shared with Mint's GRUB. NixOS's systemd-boot will
   coexist — if Mint disappears from the NixOS boot menu, boot it via the
   UEFI firmware boot menu (F8/F11) instead; both stay intact on the ESP.
3. Generate the real hardware config (replaces the repo placeholder with
   actual UUIDs) and install:
   ```bash
   sudo nixos-generate-config --root /mnt
   cp /mnt/etc/nixos/hardware-configuration.nix ~/nixos-config/hosts/nixos/
   sudo nixos-install --flake ~/nixos-config#nixos
   reboot
   ```
   (Clone first on the ISO if you haven't: `nix-shell -p git`, then
   `git clone https://github.com/jamespakele/nixos-config ~/nixos-config`.)

## Phase 2 — agent online (first boot, TTY)

Node 22 + bun + git + tmux are already present — declared in `home.nix`.

```bash
# if you skipped cloning on the ISO:
git clone https://github.com/jamespakele/nixos-config ~/nixos-config
cd ~/nixos-config

npm i -g @mariozechner/pi-coding-agent
pi                       # restore ~/.pi from backup first if you have it
cp -a /srv/data/.ssh/. ~/.ssh/   # restore keys for git push (needs /srv/data mounted — see Phase 1.2 note)
```

**House rules for the agent** (paste once, or drop into `~/.pi` as a skill):

- All system changes go through this flake. Edit files in `~/nixos-config`,
  never `/etc`, never `nix-env`, never `pip install`, never `npm i` system-wide.
- Before any `switch`, run `sudo nixos-rebuild build --flake ~/nixos-config#nixos`
  — only `switch` on a clean build.
- After every working `switch`: `git add -A && git commit && git push`.
  The pushed repo is the only off-machine backup of the config.
- Prefer nixpkgs options over hand-written config files; search options with
  `nix search` / web before inventing paths.
- State uncertainty, don't guess option names — build errors are cheap here.

Then: **use pi to install omp** — prompt it:

> Install @oh-my-pi/pi-coding-agent globally with npm, verify it runs on bun,
> confirm my pi extensions work under it.

Keep pi installed as the rescue harness; omp is the daily driver. The two
share project-local `.pi/` conventions, so extensions carry over.

## Phase 3 — COSMIC (last, flakiest)

1. Uncomment `nixos-cosmic.url` in `flake.nix`, add
   `nixos-cosmic.nixosModules.default` to `modules` in `flake.nix`.
2. **First**: `sudo nixos-rebuild test --flake ~/nixos-config#nixos` — sets up
   its binary substituters so you don't compile the DE.
3. Then enable in `configuration.nix`:
   ```nix
   services.desktopManager.cosmic.enable = true;
   services.displayManager.cosmic-greeter.enable = true;
   ```
4. `sudo nixos-rebuild switch --flake ~/nixos-config#nixos`

Hyprland + NVIDIA notes: if Hyprland misbehaves on the NVIDIA card, add to
`hyprland.conf`:
```
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
```

## Phase 4 — daily driving

```bash
cd ~/nixos-config
# edit...
sudo nixos-rebuild switch --flake ~/nixos-config#nixos
git add -A && git commit -m "..." && git push
```

- Rollback: reboot → previous generation in boot menu.
- Clean old gens: automatic (`nix.gc` weekly, 14d retention, already set).
- Secrets (SSH keys, tokens): never in the repo — `sops-nix` or `agenix`
  when the agent gets there.
  github:jamespakele/nixos-config#nixos`, identical system back.
- Shared data partition (`/srv/data`, by-label `data`): Mint + NixOS both
  mount it (agent adds `fileSystems."/srv/data"` in Phase 2). The hermes
  install there was set up under Mint/CachyOS — expect path/glibc quirks
  under NixOS; if it's an npm/bun project it usually just works, native
  binaries may need rebuilding. Mint is the unaffected fallback.
- Later — deployable agent hosts (business): add a second
  `nixosConfigurations.<name>` to the flake sharing the same modules; same
  repo deploys to podman/VMs/small hardware via `nixos-install --flake` or
  `nixos-rebuild --target-host`.

## Gotchas

- nixpkgs ↔ home-manager must be the same release (both 25.11 here).
- COSMIC in nixpkgs is immature — always via the `nixos-cosmic` flake.
- Agent state (`~/.pi`) is the one non-declarative piece — back it up or
  accept re-running `pi install npm:...` on a fresh machine.
- Don't set `services.displayManager` for Hyprland — it's TTY-launched
  (or add a greeter later); COSMIC brings its own greeter.
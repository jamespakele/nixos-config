# BOOTSTRAP — clean NixOS from a USB kit, agent-first

The process: **cut one USB kit → one command → reboot → one command → one command.**

```
bare-metal/bootstrap.sh   # from the ISO: install NixOS (select root + ESP, gated)
bare-metal/first-boot.sh  # first boot: restore state, rebuild, commit+push
bare-metal/agent-setup.sh # install pi, hand off to omp
```

Every switch is a rollback generation — agent mistakes cost a reboot, not a
reinstall. Everyday recovery: reboot → previous generation in the boot menu.

## The kit

The repo IS the kit — `bare-metal/` lives inside it, so the scripts you
reviewed are exactly what runs (the installer prints its source commit).

1. Write the NixOS **minimal** ISO (26.05) to one USB stick:
   ```bash
   sudo dd if=nixos-minimal-26.05*.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
2. Copy the whole repo to a second stick (or a Ventoy data partition):
   ```bash
   rsync -a ~/nixos-config/ /media/$USER/KIT/nixos-config/
   ```
   The kit must be on a WRITABLE USB — a stick written with `dd` is a
   read-only ISO filesystem, so use a second stick or Ventoy's data
   partition. No GitHub and no data partition are needed for the install.
   On the ISO console, locate the kit with:
   ```bash
   find /run/media /media -path '*/nixos-config/bare-metal/bootstrap.sh' 2>/dev/null
   ```

Cut the kit from a PUSHED commit whenever possible: push first, then copy
that exact tree to the stick, and note the commit hash with the kit (the
installer prints it anyway). first-boot fetches and rebases onto
origin/master before every push, so a kit with stale or missing git history
still lands as a normal fast-forward — conflicts stop the push with exact
recovery commands (never force-pushed).

## Phase 1 — install (from the ISO, at the physical console)

```bash
sudo bash /run/media/*/nixos-config/bare-metal/bootstrap.sh --check-only  # dry run: no root, no writes, offline OK
sudo bash /run/media/*/nixos-config/bare-metal/bootstrap.sh               # the real thing
reboot
```

What the installer does, in order: repo gates (it refuses to run against the
bug classes from the 2026-09-05 audit — missing hardware import, self-import,
placeholder inputs, committed passwords) → clears any stale `/mnt` from a
failed prior run → device menus (you SELECT the root partition to erase and
the ESP; defaults are derived from the target machine's own labels at run
time — the kit embeds no machine-specific IDs) →
typed confirmation (`ERASE /dev/…`) → format → generate real hardware config →
eval gate → nixos-install (sets root's password interactively, and the script
VERIFIES both root's and pakele's passwords before declaring success — it
refuses to let you reboot into a locked account, the failure that started
this) → copies the repo (with git history and the pinned flake.lock) into
`/home/pakele/nixos-config`.

Be clear about what `--check-only` proves: device selection, gates, and the
plan — nothing more. The installer runs a PRELIMINARY eval (placeholder
hardware config) before any disk is touched — config-class bugs, like the
NVIDIA option-type error the eval gate caught on 2026-09-05, are free
fix-and-rerun. The DEFINITIVE eval against the real generated hardware
config necessarily runs after format; a failure there means correcting the
kit and rerunning the install (your data partition and other OSes are still
untouched — only the freshly formatted root is at stake).

On any machine with Nix installed, you can rehearse the config checks
without booting anything:
```bash
nix flake lock
nix flake check
nix eval .#nixosConfigurations.nixos.config.system.build.toplevel.drvPath
```
The installer runs the same eval itself — a flake that cannot evaluate
never gets as far as installing.

Modes:

- **Interactive menus (default).** Mounted partitions, Windows disks (ntfs),
  and anything labeled `data`/`home`/`backup` are never offered (**`--check-only`
  is the exception: it displays mounted candidates read-only, purely for
  inspection**); an UNLABELED root candidate demands a stronger token
  (`ERASE UNLABELED …`). The kit USB can never wipe itself. The ESP is always
  an explicit selection — the root default is only a hint derived from this
  machine's own labels, so read the menu before pressing Enter.
- **`--root DEV --esp DEV`** — non-interactive; same gates. Targeting a
  Windows-disk partition or a data-labeled partition requires additional
  typed confirmations (`I UNDERSTAND …`).
- **`--disk DEV --wipe`** — DESTROYS the whole disk (fresh machine): new
  ESP + root. Requires `WIPE-DISK DEV`.
- **`--check-only`** — full plan, zero changes, no root needed.

Password policy: nothing about passwords is ever committed to this public
repo. root's password is set by `nixos-install`; pakele's by the script's
verified `passwd` step. Change pakele's on first login if you want.

This box's dual-boot notes: the ESP (nvme0n1p1) is shared with Mint's GRUB —
systemd-boot coexists; if Mint drops off the NixOS menu, boot it via the
firmware menu (F8/F11). Nothing touches nvme1n1 (Windows) or Mint's p2.
Warning: Mint's root (nvme0n1p2, ~782G, unlabeled ext4) IS offered in the
root menu whenever Mint isn't booted — the typed `ERASE /dev/…` confirmation
is the protection, and the PARTLABEL=root default is the right pick on this
box. Read the menu before pressing Enter.

**Have a locked install from the old playbook?** Either rerun this installer
for a clean slate (it dogfoods the kit), or recover in place: boot the ISO,
`mount /dev/disk/by-label/nixos /mnt`, then
`nixos-enter --root /mnt -c 'passwd pakele'`.

## Phase 2 — first boot (TTY login as pakele)

```bash
bash ~/nixos-config/bare-metal/first-boot.sh
```

Verifies login works (it must — you're running it), mounts `/srv/data` if
present (optional; declared `nofail` in configuration.nix), restores
`~/.ssh` and `~/.pi` (timestamped backups of anything already there), switches
the real hardware config, verifies the data mount actually happened, then
commits and pushes (push is skipped with instructions if keys are absent).

## Phase 3 — agent online

```bash
bash ~/nixos-config/bare-metal/agent-setup.sh
```

Installs pi into `~/.npm-global` (never system npm, never sudo), verifies
node 22 / bun / git, then hands off: run `pi` and paste the omp prompt it
prints. pi stays as the rescue harness; omp becomes the daily driver.

## Later — COSMIC (flakiest, do it last)

Uncomment `nixos-cosmic.url` in flake.nix, add its module to `modules`,
`sudo nixos-rebuild test` once (sets up substituters), then enable
`services.desktopManager.cosmic` + `services.displayManager.cosmic-greeter`
and `switch`. Hyprland + NVIDIA env vars are in the git history if needed.

## Recovery ladder (worst case first)

Windows (nvme1n1, always boots) → Linux Mint (nvme0n1p2, untouched) →
shared data partition (nvme0n1p4: .ssh, pi-backup) → GitHub flake
(`sudo nixos-install --flake github:jamespakele/nixos-config#nixos`) →
generation rollback (everyday).

## Gotchas

- The repo's branch is `master` (first-boot.sh pushes `master`) — renaming it
  means updating first-boot.sh too.
- nixpkgs ↔ home-manager must be the same release (both 26.05 here).
- Machine-specific hardware config (NVIDIA, kernel params) lives in
  `configuration.nix`, NOT `hardware-configuration.nix` — that file is
  regenerated on every install/rebuild.
- Secrets never go in the repo — sops-nix/agenix later.
- The hermes install on /srv/data was built under Mint/CachyOS — expect
  path/glibc quirks under NixOS; npm/bun projects usually just work.
- Validate script edits with `bash bare-metal/test-parser.sh` (must pass
  with zero stderr) before committing.
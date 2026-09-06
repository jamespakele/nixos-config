# RUNBOOK — ISO-console install (self-verifying; read THIS at the console)

Read this file at the ISO console: `cat $KIT/bare-metal/RUNBOOK-iso-console.md`.
Every step has an EXPECTED result. Do the check, compare, only proceed on a
match. Any mismatch → STOP, reboot back to Mint, report the exact line.

## Rules (read once)

- You are root on the ISO; no sudo needed.
- Device names (`nvme0n1` / `nvme1n1`) **flip between boots** — never match
  them. Identify by LABEL, PARTLABEL, and size only.
- The Ventoy stick's only job: booting this ISO. Nothing is read from it.
- Network is required (nixpkgs fetch). git is already inside the ISO —
  the script will NOT need its nix-shell fallback.

## STEP 1 — orientation

```
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL
```
EXPECTED: exactly one disk holding a ~591G partition labeled `nixos`
(PARTLABEL `root`) plus a ~489G ext4 partition labeled `data` plus a ~512M
vfat PARTLABEL `EFI System Partition` — all on the SAME disk. A second disk
with ntfs `Windows` + `Recovery` partitions. A USB disk with `Ventoy` /
`VTOYEFI`.
STOP if: no `nixos` or `data` label; or ntfs shares a disk with `nixos`.

## STEP 2 — mount the data partition (read-only; NEVER under /mnt)

```
mkdir -p /run/nixos-data
mount -o ro /dev/disk/by-label/data /run/nixos-data
KIT=/run/nixos-data/3-resources/config-notes/nixos/nixos-config
ls $KIT/bare-metal/
```
EXPECTED: `RUNBOOK-iso-console.md agent-setup.sh bootstrap.sh first-boot.sh test-parser.sh`
STOP if mount fails or the listing differs.

## STEP 3 — verify the kit revision against GitHub

```
git -c safe.directory="$KIT" -C "$KIT" rev-parse --short HEAD
git -c safe.directory="$KIT" -C "$KIT" ls-remote https://github.com/jamespakele/nixos-config master
```
(The `safe.directory` flag is REQUIRED: the console runs as root but the kit
is user-owned — plain git refuses with "dubious ownership".)
EXPECTED: the first 7 hex chars of the ls-remote hash match rev-parse.
No network → STOP (the install itself needs network; there is no offline path).

## STEP 4 — dry run

```
bash $KIT/bare-metal/bootstrap.sh --check-only
```
EXPECTED:
- `all repo gates passed`
- `commit:` matches STEP 3
- Plan: ERASE target = the ~591G `root`-labeled partition on the Linux disk;
  ESP = the ~512M `EFI System Partition` on that SAME disk (NOT the ~100M
  `EFI system partition` on the Windows disk); `data` and the Windows disk
  appear ONLY as untouched; the USB never appears as a target.
- Ends with `(check-only: stopping before confirmation)`.
STOP if the erase target is anything but the `root`-labeled partition, or
the ESP is on the Windows disk.

## STEP 5 — the real install

```
bash $KIT/bare-metal/bootstrap.sh
```
- Menus: root = the pre-marked default (Enter); ESP = the ~512M vfat on the
  Linux disk (explicit pick — read the menu).
- Type the `ERASE <dev>` token exactly.
- nixos-install prompts → set ROOT's password.
- The script prompts → set PAKELE's password. It verifies BOTH (status `P`)
  and refuses to let you reboot into a locked account.
- A preliminary eval runs BEFORE any disk is touched; the definitive eval
  runs after format. An eval failure = STOP (nothing lost — rerun is free).
EXPECTED at the end: `Done (commit <hash>). Reboot, log in as pakele, then
run: bash ~/nixos-config/bare-metal/first-boot.sh`

## STEP 6 — first boot

```
reboot        # log in as pakele on the TTY
bash ~/nixos-config/bare-metal/first-boot.sh
```
EXPECTED in order: `OK: logged in as pakele` → data mount ok/warn →
`~/.ssh restored` → `build clean` → `switched — system is live` →
`pushed to GitHub`.
STOP on build/switch failure — the error is printed; report from Mint
(the data partition is untouched by any of this).

## STEP 7 — agent

```
bash ~/nixos-config/bare-metal/agent-setup.sh
```
EXPECTED: node/bun/git versions → `pi installed and runnable` → the omp
handoff prompt (run `pi` and paste it).

## Hard stop conditions (any one → STOP, reboot to Mint, report)

- STEP 2 mount fails, or STEP 3 HEAD ≠ ls-remote
- STEP 4 plan deviates (wrong erase target / ESP on Windows disk / `data`
  or USB offered as target)
- any eval failure
- any password not verifying (the script will refuse — trust it)
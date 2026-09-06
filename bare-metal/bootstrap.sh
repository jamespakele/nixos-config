#!/usr/bin/env bash
# bootstrap.sh — NixOS bare-metal installer, run from the NixOS minimal ISO.
#
#   >>> Run this on the PHYSICAL CONSOLE. `passwd` prompts are interactive;
#       this script is not SSH-friendly by design. <<<
#
# Source of truth is THIS repo copy (the install-USB kit). GitHub and any
# data partition are NOT required — everything needed is right here, and
# what you reviewed is exactly what gets installed.
#
#   sudo bash /path/to/nixos-config/bare-metal/bootstrap.sh --check-only
#       Validate repo + devices, auto-select the defaults, print the full
#       plan, change nothing.
#
#   sudo bash /path/to/nixos-config/bare-metal/bootstrap.sh
#       Interactive mode (default). Scans all disks; you SELECT the root
#       partition to erase and the ESP to install to from numbered menus.
#       Nothing is assumed — on the box this kit was built for the
#       known-good ESP/root are pre-marked defaults, anywhere else you
#       just pick from the list.
#
#   sudo bash /path/to/nixos-config/bare-metal/bootstrap.sh --root /dev/nvme0n1p3 --esp /dev/nvme0n1p1
#       Non-interactive: same gates, plan, and confirmation, menus skipped.
#
#   sudo bash /path/to/nixos-config/bare-metal/bootstrap.sh --disk /dev/nvme1n1 --wipe
#       Fresh-disk mode. DESTROYS THE WHOLE DISK: new ESP + root.
#
# Password policy (public repo — no passwords are ever committed):
#   - nixos-install sets root's password interactively.
#   - This script then sets pakele's password via `nixos-enter ... passwd`
#     and VERIFIES it before declaring success; it refuses to let you
#     reboot into a locked account.
# Re-entrant: failed runs can just be re-run (root is always reformatted).
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

HOSTNAME_FLAKE="nixos"
USER_NAME="pakele"
# No machine-specific identifiers are embedded in this kit — menu defaults
# are derived from the TARGET machine's own labels at run time.
WORK_DIR="/tmp/nixos-config-install-$(id -u)"
MNT="/mnt"

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mSTOP: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }

# Capture ORIGINAL arguments BEFORE the parser loop shifts them away — the
# nix-shell re-exec below must see the user's exact command line.
ORIGINAL_ARGS=("$@")

MODE="preserve"
TARGET_DISK=""
ROOT_DEV=""
ESP_DEV=""
NO_MINT_CHECK=0
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift;;
    --disk) TARGET_DISK="$2"; shift 2;;
    --wipe) MODE="wipe"; shift;;
    --root) ROOT_DEV="$2"; shift 2;;
    --esp)  ESP_DEV="$2"; shift 2;;
    --no-mint-check) NO_MINT_CHECK=1; shift;;
    *) die "unknown arg '$1' (usage: bootstrap.sh [--check-only] [--root DEV --esp DEV | --disk DEV --wipe] [--no-mint-check])";;
  esac
done

# The install path needs root; the dry run deliberately does not.
if [ "$(id -u)" -ne 0 ] && [ "$CHECK_ONLY" = 0 ]; then
  die "must run as root (sudo). For a dry run: bootstrap.sh --check-only (works as any user)"
fi

# base_disk_of DEVICE -> whole disk behind a partition (or the device itself)
base_disk_of() {
  local src="$1" d
  [ -b "$src" ] || return 0
  d="$(lsblk -no PKNAME "$src" 2>/dev/null | tail -1)"
  if [ -n "$d" ]; then echo "/dev/$d"; else echo "$src"; fi
}
mib() { echo $(( $1 / 1024 / 1024 )); }

step "Source repo"
echo "repo:  $REPO_SRC"
[ -f "$REPO_SRC/flake.nix" ] || die "flake.nix not found next to this script — run it from the repo's bare-metal/ directory"
COMMIT="$(git -C "$REPO_SRC" rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ]; then
  echo "commit: $COMMIT"
  echo "remote: $(git -C "$REPO_SRC" remote get-url origin 2>/dev/null || echo none)"
else
  echo "commit: (not a git checkout — first-boot.sh will git init + remote add)"
fi

step "Repo gates (the audit's bug classes — fail before touching any disk)"
if ! grep -q 'hardware-configuration' "$REPO_SRC/hosts/nixos/configuration.nix"; then
  die "hosts/nixos/configuration.nix does not mention ./hardware-configuration.nix — check imports"
fi
if grep -Eq '^[[:space:]]*imports[[:space:]]*=' "$REPO_SRC/hosts/nixos/hardware-configuration.nix"; then
  die "hardware-configuration.nix contains an active imports assignment (self-import recursion) — fix the placeholder"
fi
if grep -Eq 'pi-nix|github:owner/' "$REPO_SRC/flake.nix"; then
  die "flake.nix still contains a placeholder input (pi-nix / github:owner/...)"
fi
# Anchored: an ACTIVE import assignment is required, not a mere mention.
if ! grep -Eq '^[[:space:]]*imports[[:space:]]*=.*\./hardware-configuration\.nix' "$REPO_SRC/hosts/nixos/configuration.nix"; then
  die "hosts/nixos/configuration.nix has no active 'imports = [ ./hardware-configuration.nix ]' — unbootable config"
fi
if grep -q 'herdr' "$REPO_SRC/home.nix"; then
  die "home.nix references 'herdr' — not a real nixpkgs package (use tmux)"
fi
# Anchored: matches only an ACTIVE option assignment, never comments.
if grep -Eq '^[[:space:]]*(initialPassword|hashedPassword)[[:space:]]*=' "$REPO_SRC/hosts/nixos/configuration.nix"; then
  die "configuration.nix commits a password — this repo is PUBLIC; passwords are set at install time only"
fi
echo "all repo gates passed"

step "Network pre-flight (nixpkgs must be fetchable) — BEFORE the nix-shell re-exec, so no-network fails clearly"
if [ "$CHECK_ONLY" = 1 ]; then
  # A dry run must work offline — it never fetches nixpkgs.
  if curl -sfI -m 10 https://github.com >/dev/null 2>&1; then echo "network OK"; else warn "no network (irrelevant for --check-only; the real install requires it)"; fi
elif ! curl -sfI -m 10 https://github.com >/dev/null 2>&1; then
  die "no network. Connect ethernet (or Wi-Fi via the installer's tools), then re-run. Network is required to fetch nixpkgs."
else
  echo "network OK"
fi

step "Tool pre-flight"
# git is NOT on the minimal ISO's PATH; nix-shell (the ISO's own channel)
# provides it. Re-exec so this script AND nix's flake eval can both use git.
if ! command -v git >/dev/null 2>&1; then
  [ "${BOOTSTRAP_IN_NIX_SHELL:-}" = 1 ] && die "git is still missing inside nix-shell — aborting instead of recursing"
  command -v nix-shell >/dev/null 2>&1 || die "git missing and nix-shell unavailable to provide it"
  echo "git not found on PATH — re-executing inside 'nix-shell -p git'"
  exec nix-shell -p git --run "exec env BOOTSTRAP_IN_NIX_SHELL=1 bash $(printf '%q' "$SCRIPT_PATH") $(printf '%q ' "${ORIGINAL_ARGS[@]}")"
fi
# --check-only only inspects: it never formats, mounts, or evaluates.
if [ "$CHECK_ONLY" = 1 ]; then
  for t in curl lsblk findmnt; do
    command -v "$t" >/dev/null || die "missing required tool: $t"
  done
else
  for t in curl nix nixos-install nixos-enter lsblk findmnt mkfs.ext4 udevadm; do
    command -v "$t" >/dev/null || die "missing required tool: $t"
  done
fi
if [ "$MODE" = wipe ] && [ "$CHECK_ONLY" = 0 ]; then
  for t in sgdisk mkfs.fat partprobe; do command -v "$t" >/dev/null || die "missing required tool for --wipe: $t"; done
fi
echo "tools OK"

step "Staging a clean writable copy ($WORK_DIR)"
rm -rf "$WORK_DIR"
cp -r "$REPO_SRC" "$WORK_DIR"
# .git is KEPT: the generated hardware-configuration.nix and flake.lock are
# staged + committed below so the git-tree flake sees them, and the copy
# shipped into the installed system can push to GitHub from first boot.
echo "staged at $WORK_DIR"

if [ "$CHECK_ONLY" = 0 ]; then
  step "Preliminary eval — config bugs caught BEFORE any disk is touched"
  # Runs against the placeholder hardware config (machine-neutral). The
  # definitive eval against the REAL generated config happens after format;
  # this one makes config-class failures a free fix-and-rerun.
  if ! nix --extra-experimental-features 'nix-command flakes' \
        eval "$WORK_DIR#nixosConfigurations.$HOSTNAME_FLAKE.config.system.build.toplevel.drvPath" --raw >/dev/null; then
    die "flake failed to evaluate — read the errors above, fix, re-run (nothing has been touched yet)"
  fi
  echo "flake evaluates clean (preliminary)"
fi

# Clear stale /mnt BEFORE the mounted-device maps are built, so a re-run is
# never blocked by its own leftovers from a failed prior run.
if [ "$CHECK_ONLY" = 1 ]; then
  mountpoint -q "$MNT" && warn "$MNT is currently mounted (dry run leaves it; a live run clears it first)"
else
  while read -r mp; do
    case "$mp" in "$MNT"|"$MNT"/*) echo "unmounting stale $mp"; umount -R "$mp" 2>/dev/null || true;; esac
  done < <(findmnt -rno TARGET 2>/dev/null | sort -r)
  if mountpoint -q "$MNT"; then die "$MNT is still a mountpoint after cleanup — clear it manually"; fi
fi

# Mounted PARTITIONS vs mounted-upon DISKS — kept separate on purpose: a
# mounted sibling (e.g. the data partition, or the disk the script itself
# runs from) must NOT exclude its unmounted neighbors from the menu.
declare -A MOUNTED_DEVICES MOUNTED_DISKS
MOUNTED_SOURCES=""
while IFS=$'\t' read -r src tgt; do
  [ "$tgt" = "$MNT" ] && continue   # stale /mnt from a previous failed run is fine
  src="$(readlink -f "$src" 2>/dev/null || true)"
  [ -b "$src" ] || continue
  MOUNTED_DEVICES["$src"]=1
  MOUNTED_DISKS["$(base_disk_of "$src")"]=1
  MOUNTED_SOURCES+="${MOUNTED_SOURCES:+ }$src"
done < <(findmnt -rno SOURCE,TARGET 2>/dev/null || true)
KIT_SOURCE="$(findmnt -T "$SCRIPT_PATH" -no SOURCE 2>/dev/null || true)"
KIT_SOURCE="$(readlink -f "${KIT_SOURCE:-}" 2>/dev/null || true)"
[ -b "${KIT_SOURCE:-}" ] || KIT_SOURCE=""
KIT_PARTITION="$KIT_SOURCE"
KIT_DISK="$(base_disk_of "${KIT_SOURCE:-}" 2>/dev/null || true)"
# Removability decides HOW protective we are: a removable kit USB never
# offers ANY of its partitions (nothing precious can live there); an
# internal data-partition kit only protects its own partition (its disk
# legitimately holds the install target and data partitions).
KIT_DISK_NAME=""
KIT_REMOVABLE=0
if [ -n "$KIT_DISK" ] && [ "$KIT_DISK" != "$KIT_SOURCE" ]; then
  KIT_DISK_NAME="$(basename "$KIT_DISK")"
  [ "$(cat "/sys/block/$KIT_DISK_NAME/removable" 2>/dev/null || echo 0)" = 1 ] && KIT_REMOVABLE=1
fi
if [ -z "$KIT_SOURCE" ] && [ "$CHECK_ONLY" = 0 ]; then
  if [ "$MODE" = wipe ]; then
    die "--wipe could not identify the device this script runs from — refusing (cannot prove the kit disk is not the target)."
  fi
  warn "could not identify the block device this script runs from (overlay/bind mount?) — kit protection is degraded."
  printf 'Continue anyway? [type YES] '
  read -r a
  [ "$a" = YES ] || die "aborted by user — run this script from a real mounted block device (the install USB)"
fi
if [ "$MODE" = wipe ]; then
  case "$KIT_SOURCE" in
    /dev/loop*|/dev/dm-*)
      if [ "$CHECK_ONLY" = 1 ]; then
        warn "kit runs from $KIT_SOURCE (loop/overlay) — wipe safety cannot be verified"
      else
        die "--wipe with a loop/overlay kit is refused (cannot verify which disk holds the kit). Copy the kit to a writable USB and re-run."
      fi
      ;;
  esac
fi

# One inventory pass; parsed records come from `lsblk -P -b` (quoted
# key="value" pairs — labels contain spaces, so raw lsblk output is unusable).
LSBLK_ALL="$(lsblk -P -b -o NAME,PKNAME,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT 2>/dev/null || true)"

# ---- BEGIN PARSER ---- (fixture-tested; see bare-metal/test-parser.sh)
# Default-resolution helpers exist so the fixture test can override them
# (hermetic: no dependence on this machine's /dev/disk entries).
resolve_root_label() { readlink -f /dev/disk/by-partlabel/root 2>/dev/null || true; }
# parse_record "KEY=\"v\" ..." -> sets NAME PKNAME TYPE SIZE FSTYPE LABEL PARTLABEL MNTPT
parse_record() {
  local rest="$1" k v
  local pair_re='^[[:space:]]*([A-Z_]+)="([^"]*)"'
  NAME=""; PKNAME=""; TYPE=""; SIZE="0"; FSTYPE=""; LABEL=""; PARTLABEL=""; MNTPT=""
  while [[ "$rest" =~ $pair_re ]]; do
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    case "$k" in
      NAME) NAME="$v";; PKNAME) PKNAME="$v";; TYPE) TYPE="$v";; SIZE) SIZE="$v";;
      FSTYPE) FSTYPE="$v";; LABEL) LABEL="$v";; PARTLABEL) PARTLABEL="$v";; MOUNTPOINT) MNTPT="$v";;
    esac
    rest="${rest:${#BASH_REMATCH[0]}}"
  done
}
# NTFS_DISK[<pkname>]=1 for every disk holding an ntfs partition (Windows guard)
declare -A NTFS_DISK
while IFS= read -r rec; do
  parse_record "$rec"
  if [ "$TYPE" = part ] && [ "$FSTYPE" = ntfs ] && [ -n "$PKNAME" ]; then NTFS_DISK["$PKNAME"]=1; fi
done <<<"$LSBLK_ALL"

# build_candidates root|esp -> fills CANDS[] ROWS[] DEFAULT_IDX (0-based idx+1)
build_candidates() {
  local kind="$1" mark=""
  CANDS=(); ROWS=(); DEFAULT_IDX=""
  while IFS= read -r rec; do
    parse_record "$rec"
    [ "$TYPE" = part ] || continue
    [ -n "$PKNAME" ] || continue
    [ -n "${NTFS_DISK[$PKNAME]:-}" ] && continue          # never touch Windows disks
    if [ "$PKNAME" = "$KIT_DISK_NAME" ]; then
      [ "$KIT_REMOVABLE" = 1 ] && continue                # removable kit USB: never offer any of its partitions
      [ "/dev/$NAME" = "$KIT_PARTITION" ] && continue     # internal kit partition: protect it, siblings stay offerable
    fi
    if [ "$kind" = root ]; then
      [ "$FSTYPE" = ext4 ] || [ "$FSTYPE" = btrfs ] || continue
    else
      [ "$FSTYPE" = vfat ] || continue
      [ "$SIZE" -ge 104857600 ] && [ "$SIZE" -le 1073741824 ] || continue  # 100M..1G
    fi
    mark=""
    if [ "$kind" = root ] && [ -z "$DEFAULT_IDX" ] \
       && { [ "$(resolve_root_label)" = "/dev/$NAME" ] || [ "$LABEL" = nixos ]; }; then
      mark="   <-- previous NixOS root on this machine (default)"
      DEFAULT_IDX=$(( ${#CANDS[@]} + 1 ))
    fi
    case "${LABEL,,}" in
      data|home|backup) continue ;;  # deliberate: never OFFER likely-data partitions in the menu — target one with --root (which demands its own typed confirmation)
    esac
    if [ -z "$LABEL" ] && [ -z "$PARTLABEL" ]; then
      mark="$mark   [!] unlabeled partition — verify what this is before selecting it"
    fi
    if [ -n "$MNTPT" ]; then
      [ "$CHECK_ONLY" = 1 ] || continue   # live runs never offer mounted partitions
      mark="$mark   [mounted: $MNTPT — dry-run display only]"
    fi
    CANDS+=("/dev/$NAME")
    ROWS+=("$(printf '%-18s %7sMiB  %-8s label=%-14s partlabel=%s%s' \
      "/dev/$NAME" "$(mib "$SIZE")" "${FSTYPE:-?}" "${LABEL:--}" "${PARTLABEL:--}" "$mark")")
  done <<<"$LSBLK_ALL"
  [ "${#CANDS[@]}" -gt 0 ] || die "no $kind candidates found — inspect with: lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT"
}

# select_part root|esp -> menu UI on STDERR; echoes ONLY the device on STDOUT
select_part() {
  local kind="$1" title input i
  case "$kind" in
    root) title="Select the partition to ERASE for the NixOS root:";;
    esp)  title="Select the EFI System Partition for the bootloader:";;
  esac
  build_candidates "$kind"
  {
    echo
    echo "$title"
    for i in "${!ROWS[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "${ROWS[$i]}"; done
    if [ -n "$DEFAULT_IDX" ]; then
      printf 'Select [1-%d, Enter=default %s]: ' "${#CANDS[@]}" "${CANDS[$((DEFAULT_IDX - 1))]}"
    else
      printf 'Select [1-%d]: ' "${#CANDS[@]}"
    fi
  } >&2
  if [ "$CHECK_ONLY" = 1 ]; then
    if [ -n "$DEFAULT_IDX" ]; then input="$DEFAULT_IDX"; else input=1; fi
    echo "(check-only: auto-selected ${CANDS[$((input - 1))]})" >&2
  else
    read -r input
    [ -z "$input" ] && [ -n "$DEFAULT_IDX" ] && input="$DEFAULT_IDX"
    [[ "$input" =~ ^[0-9]+$ ]] || die "invalid selection: '$input'"
    [ "$input" -ge 1 ] && [ "$input" -le "${#CANDS[@]}" ] || die "selection out of range: $input"
  fi
  echo "${CANDS[$((input - 1))]}"
}
# ---- END PARSER ----

step "Resolve target devices"
if [ "$MODE" = wipe ]; then
  [ -n "$TARGET_DISK" ] || die "--wipe requires --disk DEV"
  TARGET_DISK="$(readlink -f "$TARGET_DISK")"
  [ -b "$TARGET_DISK" ] || die "$TARGET_DISK is not a block device"
  [ "$(lsblk -ndo TYPE "$TARGET_DISK")" = disk ] || die "$TARGET_DISK is not a whole disk — --disk takes a whole device like /dev/nvme1n1"
  echo "script/kit source device: ${KIT_SOURCE:-unknown} (disk: ${KIT_DISK:-unknown})"
  echo "mounted block devices:    ${MOUNTED_SOURCES:-none}"
  [ "$TARGET_DISK" = "$KIT_DISK" ] && die "$TARGET_DISK is this kit USB — refusing"
  [ "${MOUNTED_DISKS[$TARGET_DISK]:-}" ] && die "$TARGET_DISK backs a mounted filesystem — refusing (would destroy the running system)"
  while read -r part; do
    [ -e "$part" ] || continue
    MP="$(findmnt -no TARGET "$part" 2>/dev/null || true)"
    [ -n "$MP" ] && die "$part is mounted at $MP — unmount it or pick another disk"
  done < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}')
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT "$TARGET_DISK" || true
  echo
  echo "Plan: DESTROY ALL DATA on $TARGET_DISK, create ESP(1G)+root, install NixOS."
  if [ "$CHECK_ONLY" = 1 ]; then echo "(check-only: stopping before confirmation)"; exit 0; fi
  printf 'Type WIPE-DISK %s to confirm: ' "$TARGET_DISK"
  read -r a
  [ "$a" = "WIPE-DISK $TARGET_DISK" ] || die "aborted by user"

  step "Partition + format $TARGET_DISK (fresh install)"
  PART="${TARGET_DISK}p"; [[ "$TARGET_DISK" =~ [0-9]$ ]] || PART="${TARGET_DISK}"
  sgdisk --clear "$TARGET_DISK"
  sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:ESP  "$TARGET_DISK"
  sgdisk -n 2:0:0    -t 2:8300 -c 2:root "$TARGET_DISK"
  partprobe "$TARGET_DISK" 2>/dev/null || true
  udevadm settle
  [ -e "${PART}1" ] && [ -e "${PART}2" ] || die "partition nodes ${PART}1/${PART}2 did not appear after sgdisk — inspect with: lsblk $TARGET_DISK"
  mkfs.fat -F 32 -n ESP  "${PART}1"
  mkfs.ext4 -L nixos     "${PART}2"
  udevadm settle
  # Real device nodes — by-label symlinks may lag behind fresh mkfs.
  ROOT_DEV="${PART}2"
  ESP_DEV="${PART}1"
  FST="$(lsblk -no FSTYPE "$ROOT_DEV")"
  [ "$FST" = ext4 ] || die "post-format check failed on $ROOT_DEV: FSTYPE=$FST"
else
  if [ -n "$ROOT_DEV" ] || [ -n "$ESP_DEV" ]; then
    [ -n "$ROOT_DEV" ] && [ -n "$ESP_DEV" ] || die "--root and --esp must be given together (or neither, for the menus)"
    echo "using explicit devices: root=$ROOT_DEV esp=$ESP_DEV"
  else
    # Interactive selection — nothing is assumed.
    ROOT_DEV="$(select_part root)"
    ESP_DEV="$(select_part esp)"
  fi
  ROOT_DEV="$(readlink -f "$ROOT_DEV")"
  ESP_DEV="$(readlink -f "$ESP_DEV")"
  [ -b "$ROOT_DEV" ] || die "root $ROOT_DEV is not a block device"
  [ -b "$ESP_DEV" ]  || die "ESP $ESP_DEV is not a block device"
  [ "$ROOT_DEV" != "$ESP_DEV" ] || die "root and ESP are the same device?!"
  [ "$(base_disk_of "$ROOT_DEV")" != "$ROOT_DEV" ] || die "$ROOT_DEV is a whole disk, not a partition"
  ESP_FS="$(lsblk -no FSTYPE "$ESP_DEV")"
  [ "$ESP_FS" = vfat ] || die "ESP $ESP_DEV is not vfat (got '$ESP_FS')"
  for dev in "$ROOT_DEV" "$ESP_DEV"; do
    [ "$dev" = "$KIT_PARTITION" ] && die "$dev is this kit — refusing"
    if [ "$KIT_REMOVABLE" = 1 ] && [ "$(base_disk_of "$dev")" = "$KIT_DISK" ]; then
      die "$dev is on the removable kit USB ($KIT_DISK) — refusing"
    fi
    if [ "${MOUNTED_DEVICES[$dev]:-}" ]; then
      [ "$CHECK_ONLY" = 1 ] || die "$dev is a mounted filesystem — refusing"
      warn "$dev is mounted right now (dry run continues; a live run refuses mounted targets)"
    fi
    MP="$(findmnt -no TARGET "$dev" 2>/dev/null || true)"
    if [ -n "$MP" ] && [ "$CHECK_ONLY" = 0 ]; then die "$dev is mounted at $MP — unmount it first"; fi
  done
  DISK="$(base_disk_of "$ROOT_DEV")"
  # Windows guard: MENUS never offer partitions on Windows disks. The
  # explicit --root path may target a mixed Windows/Linux disk (single-disk
  # dual-boot is legal — only the selected root is erased) AFTER a typed
  # Windows-awareness confirmation.
  if lsblk -rno FSTYPE "$DISK" 2>/dev/null | grep -q ntfs; then
    warn "$DISK contains ntfs (Windows) partitions. Only $ROOT_DEV will be erased — Windows partitions stay untouched."
    if [ "$CHECK_ONLY" = 1 ]; then
      echo "(check-only: would require typing an explicit Windows-awareness confirmation here)"
    else
      printf 'Type I UNDERSTAND %s CONTAINS WINDOWS to proceed: ' "$DISK"
      read -r a
      [ "$a" = "I UNDERSTAND $DISK CONTAINS WINDOWS" ] || die "aborted by user"
    fi
  fi
  # Data-partition guard (applies even with --root): a data/home/backup
  # label demands its own typed confirmation.
  ROOT_LABEL="$(lsblk -no LABEL "$ROOT_DEV" 2>/dev/null || true)"
  case "${ROOT_LABEL,,}" in
    data|home|backup)
      warn "$ROOT_DEV is labeled '$ROOT_LABEL' — it looks like a data/backup partition."
      if [ "$CHECK_ONLY" = 1 ]; then
        echo "(check-only: would require typing an explicit confirmation here)"
      else
        printf 'Type I UNDERSTAND %s IS LABELED %s to proceed: ' "$ROOT_DEV" "${ROOT_LABEL^^}"
        read -r a
        [ "$a" = "I UNDERSTAND $ROOT_DEV IS LABELED ${ROOT_LABEL^^}" ] || die "aborted by user"
      fi
      ;;
  esac
  ESP_SZ="$(lsblk -bno SIZE "$ESP_DEV")"
  if [ "$ESP_SZ" -lt 268435456 ]; then
    warn "ESP is only $(mib "$ESP_SZ")MiB — NixOS may not fit comfortably"
    [ "$CHECK_ONLY" = 1 ] || { printf 'Continue anyway? [type YES] '; read -r a; [ "$a" = YES ] || die "aborted by user"; }
  fi
  echo "root: $ROOT_DEV   esp: $ESP_DEV   disk: $DISK"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT "$DISK" || true
  echo
  echo "Plan:"
  echo "  ERASE + format ext4 'nixos' : $ROOT_DEV  (clean install — nothing on it survives)"
  echo "  ESP, bootloader only        : $ESP_DEV   (mounted at /mnt/boot; files added, none removed)"
  echo "  all other partitions/disks  : untouched (incl. any Windows and data partitions)"
  echo "  repo staged from            : $REPO_SRC (commit ${COMMIT:-no-git})"
  if [ "$CHECK_ONLY" = 1 ]; then echo "(check-only: stopping before confirmation)"; exit 0; fi
  ROOT_LABEL="$(lsblk -no LABEL "$ROOT_DEV" 2>/dev/null || true)"
  if [ -z "$ROOT_LABEL" ]; then
    printf 'Type ERASE UNLABELED %s to confirm (unlabeled = unverified — check the menu twice): ' "$ROOT_DEV"
    read -r a
    [ "$a" = "ERASE UNLABELED $ROOT_DEV" ] || die "aborted by user"
  else
    printf 'Type ERASE %s to confirm: ' "$ROOT_DEV"
    read -r a
    [ "$a" = "ERASE $ROOT_DEV" ] || die "aborted by user"
  fi

  step "Format root — ALWAYS fresh (this is a clean install)"
  CUR="$(lsblk -no FSTYPE "$ROOT_DEV")"
  case "$CUR" in
    btrfs|ext4) : ;;  # Linux filesystems — expected prior state
    *) die "unexpected FSTYPE '$CUR' on $ROOT_DEV — refusing to format an unknown partition";;
  esac
  mkfs.ext4 -L nixos "$ROOT_DEV"
  FST="$(lsblk -no FSTYPE "$ROOT_DEV")"; LBL="$(lsblk -no LABEL "$ROOT_DEV")"
  [ "$FST" = ext4 ] && [ "$LBL" = nixos ] || die "post-format check failed: FSTYPE=$FST LABEL=$LBL"
fi

step "Mount target"
if mountpoint -q "$MNT"; then die "$MNT is still a mountpoint — clear it manually"; fi
mkdir -p "$MNT"
mount "$ROOT_DEV" "$MNT"
findmnt -no FSTYPE "$MNT" | grep -qx ext4 || die "$MNT did not mount as ext4"
mkdir -p "$MNT/boot"
mount "$ESP_DEV" "$MNT/boot"
findmnt -no FSTYPE "$MNT/boot" | grep -qx vfat || die "$MNT/boot is not vfat — wrong ESP?"
if [ "$MODE" = preserve ]; then
  if [ "$NO_MINT_CHECK" = 1 ]; then
    echo "other-GRUB check skipped (--no-mint-check)"
  else
    echo "ESP EFI entries found: $(ls "$MNT/boot/EFI" 2>/dev/null | tr '\n' ' ' || echo none)"
    if [ -d "$MNT/boot/EFI/ubuntu" ]; then
      echo "shared ESP verified (GRUB entry present — NixOS systemd-boot will coexist)"
      echo "NOTE: NVRAM boot order may shift to NixOS (canTouchEfiVariables); the other OS stays bootable via the firmware menu (F8/F11)."
    else
      warn "EFI/ubuntu missing from the selected ESP — it does not host another Linux GRUB (normal on a fresh disk)."
      [ "$CHECK_ONLY" = 1 ] || { printf 'Is this the ESP you want NixOS to own? [type YES] '; read -r a; [ "$a" = YES ] || die "aborted by user"; }
    fi
  fi
fi

step "Generate real hardware config"
nixos-generate-config --root "$MNT"
[ -f "$MNT/etc/nixos/hardware-configuration.nix" ] || die "nixos-generate-config produced no hardware-configuration.nix"
cp "$MNT/etc/nixos/hardware-configuration.nix" "$WORK_DIR/hosts/nixos/hardware-configuration.nix"
grep -q 'fileSystems."/"' "$WORK_DIR/hosts/nixos/hardware-configuration.nix" \
  || die "generated hardware config has no root fileSystem — inspect manually"
grep -q 'fsType = "ext4"' "$WORK_DIR/hosts/nixos/hardware-configuration.nix" \
  || die "generated hardware config is not ext4 — inspect manually"
echo "real hardware-configuration.nix staged"

step "Pin inputs (flake.lock) — shipped with the installed repo"
nix --extra-experimental-features 'nix-command flakes' flake lock "$WORK_DIR" \
  || die "nix flake lock failed — see errors above"
[ -f "$WORK_DIR/flake.lock" ] || die "flake.lock missing after 'nix flake lock' — refusing to install an unpinned flake"
if [ -d "$WORK_DIR/.git" ]; then
  git -C "$WORK_DIR" add hosts/nixos/hardware-configuration.nix flake.lock
  git -C "$WORK_DIR" config user.name  "James Pakele"
  git -C "$WORK_DIR" config user.email "jamespakele@gmail.com"
  git -C "$WORK_DIR" commit -m "bootstrap: real hardware-configuration.nix + flake.lock (${COMMIT:-no-git})" \
    >/dev/null 2>&1 || echo "(nothing new to commit)"
else
  echo "(kit has no .git — lock file still ships; first-boot.sh will git init + fetch before its first push)"
fi
echo "staged commit: $(git -C "$WORK_DIR" log --oneline -1 2>/dev/null || echo none)"
echo "flake.lock: $([ -f "$WORK_DIR/flake.lock" ] && echo present || echo ABSENT)"

step "Eval gate — a flake that cannot evaluate will never be installed"
if ! nix --extra-experimental-features 'nix-command flakes' \
      eval "$WORK_DIR#nixosConfigurations.$HOSTNAME_FLAKE.config.system.build.toplevel.drvPath" --raw >/dev/null; then
  die "flake failed to evaluate — read the errors above, fix, re-run (nothing has been installed yet)"
fi
echo "flake evaluates clean"

step "Install (the long one; nixos-install sets root's password interactively)"
nixos-install --flake "$WORK_DIR#$HOSTNAME_FLAKE"

step "Login password for $USER_NAME — MANDATORY, verified before reboot"
USER_UID="$(nixos-enter --root "$MNT" -c "id -u $USER_NAME" 2>/dev/null | tr -dc '0-9' || true)"
[ -n "$USER_UID" ] || die "$USER_NAME missing from the installed system — inspect before rebooting"
PW_OK=0
for i in 1 2 3; do
  nixos-enter --root "$MNT" -c "passwd $USER_NAME" || { echo "passwd did not complete (attempt $i/3) — retrying"; continue; }
  PW_STATUS="$(nixos-enter --root "$MNT" -c "passwd -S $USER_NAME" | awk '{print $2}')"
  if [ "$PW_STATUS" = "P" ]; then PW_OK=1; break; fi
  echo "password not registered (status '$PW_STATUS') — retrying (attempt $i/3)"
done
[ "$PW_OK" = 1 ] || die "$USER_NAME has NO working password. DO NOT REBOOT. Fix with: nixos-enter --root $MNT -c 'passwd $USER_NAME'"
echo "$USER_NAME login password set and verified (uid $USER_UID)"

# Root must have a usable password too. nixos-install normally sets it
# interactively — verify rather than assume (invariant: before reboot, BOTH
# root and pakele have working credentials).
ROOT_PW_STATUS="$(nixos-enter --root "$MNT" -c "passwd -S root" | awk '{print $2}')"
if [ "$ROOT_PW_STATUS" != "P" ]; then
  warn "root has no password set (nixos-install's interactive step was skipped?)"
  nixos-enter --root "$MNT" -c "passwd root" || die "could not set root's password — fix before rebooting"
  ROOT_PW_STATUS="$(nixos-enter --root "$MNT" -c "passwd -S root" | awk '{print $2}')"
  [ "$ROOT_PW_STATUS" = "P" ] || die "root still has no usable password (status '$ROOT_PW_STATUS') — DO NOT REBOOT; fix with: nixos-enter --root $MNT -c 'passwd root'"
fi
echo "root password verified"

step "Copy the repo (with git history) into the installed system"
[ "$MNT" != "/" ] || die "sanity: /mnt is not a mountpoint?!"
rm -rf "${MNT}/home/${USER_NAME}/nixos-config"
mkdir -p "$MNT/home/$USER_NAME"
cp -r "$WORK_DIR" "$MNT/home/$USER_NAME/nixos-config"
USER_GID="$(nixos-enter --root "$MNT" -c "id -g $USER_NAME" | tr -dc '0-9')"
chown -R "$USER_UID:$USER_GID" "$MNT/home/$USER_NAME/nixos-config"
echo "repo + real hardware config + flake.lock staged at /home/$USER_NAME/nixos-config"

echo
printf '\033[1;32mDone (commit %s). Reboot, log in as %s, then run:\033[0m\n' "${COMMIT:-no-git}" "$USER_NAME"
echo "  bash ~/nixos-config/bare-metal/first-boot.sh"
echo "Root got its password during nixos-install; $USER_NAME's was set and verified above."
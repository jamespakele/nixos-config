#!/usr/bin/env bash
# test-parser.sh — fixture test for bootstrap.sh's lsblk parser block.
# Runs anywhere (no root, no nix): extracts the BEGIN/END PARSER block and
# feeds it known lsblk -P records, asserting candidate selection logic.
# MUST run CLEAN: any stderr noise from the parser fails the test.
set -euo pipefail
cd "$(dirname "$0")"

ERR_LOG="$(mktemp)"
exec 9>&2          # remember the real stderr
exec 2>"$ERR_LOG"  # capture everything the parser emits

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Extract the parser block (parse_record + NTFS map + build_candidates + select_part).
sed -n '/^# ---- BEGIN PARSER ----/,/^# ---- END PARSER ----/p' bootstrap.sh > /tmp/bootstrap-parser-test.sh
[ -s /tmp/bootstrap-parser-test.sh ] || fail "parser block not found in bootstrap.sh"

# Fixtures: spaces in PARTLABEL, empty fields, mounted sibling, ntfs disk,
# nvme + sda naming, 100M ESP boundary, data-labeled backup partition.
LSBLK_ALL='NAME="nvme0n1p1" PKNAME="nvme0n1" TYPE="part" SIZE="536870912" FSTYPE="vfat" LABEL="" PARTLABEL="EFI System Partition" MOUNTPOINT=""
NAME="nvme0n1p2" PKNAME="nvme0n1" TYPE="part" SIZE="839526400000" FSTYPE="ext4" LABEL="" PARTLABEL="" MOUNTPOINT="/"
NAME="nvme0n1p3" PKNAME="nvme0n1" TYPE="part" SIZE="634041212928" FSTYPE="btrfs" LABEL="old-root" PARTLABEL="root" MOUNTPOINT=""
NAME="nvme0n1p4" PKNAME="nvme0n1" TYPE="part" SIZE="525256215552" FSTYPE="ext4" LABEL="data" PARTLABEL="nvme0n1p4" MOUNTPOINT=""
NAME="sda1" PKNAME="sda" TYPE="part" SIZE="8589934592" FSTYPE="ntfs" LABEL="win-c" PARTLABEL="Basic data partition" MOUNTPOINT=""
NAME="sdb2" PKNAME="sdb" TYPE="part" SIZE="104857600" FSTYPE="vfat" LABEL="ESP" PARTLABEL="EFI System Partition" MOUNTPOINT=""'

# Stubs for variables/functions the parser block expects from its caller.
KNOWN_ESP_PARTUUID="00000000-0000-0000-0000-000000000000"  # overridden by resolve_known_esp below
KIT_PARTITION=""
CHECK_ONLY=0
die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }
mib() { echo $(( $1 / 1024 / 1024 )); }

source /tmp/bootstrap-parser-test.sh

# Hermetic overrides for default-marking — no dependence on real /dev/disk.
resolve_known_esp()  { echo /dev/nvme0n1p1; }
resolve_root_label() { echo /dev/nvme0n1p3; }

# --- parse_record unit checks ---
parse_record 'NAME="sda" PKNAME="" TYPE="disk" SIZE="42" FSTYPE="" LABEL="a b" PARTLABEL="x y" MOUNTPOINT="/mnt/z"'
[ "$NAME" = sda ]          || fail "parse_record NAME (got '$NAME')"
[ "$LABEL" = "a b" ]       || fail "parse_record multi-word LABEL (got '$LABEL')"
[ "$PARTLABEL" = "x y" ]   || fail "parse_record multi-word PARTLABEL"
[ "$MNTPT" = "/mnt/z" ]    || fail "parse_record MOUNTPOINT (got '$MNTPT')"
[ -z "$FSTYPE" ]           || fail "parse_record empty FSTYPE"
pass "parse_record: quoted multi-word values parse intact"

# --- NTFS map ---
[ "${NTFS_DISK[sda]:-}" = 1 ] || fail "NTFS_DISK[sda] not set"
pass "NTFS map: ntfs-holding disk marked"

# --- root candidates: ONLY the old root qualifies ---
# Excluded: p1 (vfat), p2 (mounted), p4 (label=data — never offered), sda (ntfs).
build_candidates root
[ "${#CANDS[@]}" = 1 ]                     || fail "root candidates: expected 1 (p3), got: ${CANDS[*]:-none}"
[ "${CANDS[0]}" = /dev/nvme0n1p3 ]         || fail "root candidate[0]: got '${CANDS[0]:-}'"
[[ "${CANDS[*]}" != *nvme0n1p4* ]]         || fail "data-labeled partition offered in root menu: ${CANDS[*]}"
[[ "${ROWS[0]}" == *partlabel=root* ]]     || fail "root row[0] lost partlabel: '${ROWS[0]}'"
pass "root candidates: mounted sibling (p2), data partition (p4), ntfs disk (sda), vfat (p1) all excluded"

# --- root default-marking (partlabel root) ---
[ "${DEFAULT_IDX:-}" = 1 ]                            || fail "root default-marking broken (DEFAULT_IDX='${DEFAULT_IDX:-unset}')"
[[ "${ROWS[0]}" == *"current 'root' by PARTLABEL"* ]] || fail "root row[0] missing default mark: '${ROWS[0]}'"
pass "root defaults: partlabel-root pre-marked as the Enter default"

# --- kit partition exclusion: kit ON p3 leaves no candidates -> die ---
KIT_PARTITION=/dev/nvme0n1p3
if ( build_candidates root ) 2>/dev/null; then
  fail "kit partition should have been excluded (expected die: no candidates)"
fi
pass "kit partition excluded from root menu (script dies rather than offer it)"
KIT_PARTITION=""

# --- ESP candidates: size window 100M..1G + default-marking ---
build_candidates esp
[ "${#CANDS[@]}" = 2 ]                          || fail "esp candidates: expected 2 (nvme p1, sdb2), got ${CANDS[*]:-none}"
[ "${CANDS[0]}" = /dev/nvme0n1p1 ]              || fail "esp candidate[0]: got '${CANDS[0]:-}'"
[ "${CANDS[1]}" = /dev/sdb2 ]                   || fail "esp candidate[1] (100M boundary): got '${CANDS[1]:-}'"
[[ "${ROWS[0]}" == *"EFI System Partition"* ]]  || fail "esp row lost multi-word PARTLABEL: '${ROWS[0]}'"
[ "${DEFAULT_IDX:-}" = 1 ]                      || fail "esp default-marking broken (DEFAULT_IDX='${DEFAULT_IDX:-unset}')"
[[ "${ROWS[0]}" == *known-good* ]]              || fail "esp row[0] missing known-good default mark: '${ROWS[0]}'"
pass "esp candidates: vfat size window correct (512M + 100M boundary); known-good ESP pre-marked as default"

# --- enforce clean parser output ---
exec 2>&9 9>&-   # restore real stderr
if [ -s "$ERR_LOG" ]; then
  printf 'FAIL: parser emitted stderr noise:\n' >&2
  cat "$ERR_LOG" >&2
  exit 1
fi
echo "PASS: zero stderr noise"

echo
echo "ALL PARSER TESTS PASSED"
#!/usr/bin/env bash
# first-boot.sh — run as pakele on first boot after bootstrap.sh + reboot.
#
#   bash ~/nixos-config/bare-metal/first-boot.sh
#
# If this script runs at all, console login works — the locked-account
# failure mode is gone. Everything optional (data partition, SSH keys,
# pi state) degrades gracefully: absent means SKIP WITH A WARNING, never
# fail. Ends with a build → switch → commit, so the installed system and
# GitHub agree.
set -uo pipefail
# NOTE: not `set -e` — every step below is guarded explicitly so one
# missing optional resource never aborts the chain.

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK: %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; }

step "Preflight"
[ "$(id -u)" -ne 0 ] || { fail "run as pakele, not root"; exit 1; }
grep -qi '^ID=nixos$' /etc/os-release 2>/dev/null || { fail "not running NixOS?"; exit 1; }
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_DIR/flake.nix" ] || { fail "flake.nix not found at $REPO_DIR"; exit 1; }
ok "logged in as $(whoami) on $(hostname); repo at $REPO_DIR"

step "Data partition (optional)"
DATA_READY=0
if mountpoint -q /srv/data; then
  DATA_READY=1; ok "/srv/data mounted"
elif [ -e /dev/disk/by-label/data ]; then
  sudo mkdir -p /srv/data
  if sudo mount /dev/disk/by-label/data /srv/data; then DATA_READY=1; ok "/srv/data mounted manually"
  else warn "data partition exists but would not mount — continuing without it"; fi
else
  warn "no data partition on this machine — continuing without it"
fi

step "Restore ~/.ssh (optional; needed for git push)"
if [ "$DATA_READY" = 1 ] && [ -d /srv/data/.ssh ] && [ -n "$(ls -A /srv/data/.ssh 2>/dev/null)" ]; then
  if [ -e ~/.ssh ]; then
    TS="$(date +%Y%m%d-%H%M%S)"
    mv ~/.ssh ~/.ssh.pre-"$TS" && echo "existing ~/.ssh backed up as ~/.ssh.pre-$TS"
  fi
  install -d -m 700 ~/.ssh
  cp -a /srv/data/.ssh/. ~/.ssh/
  chmod 700 ~/.ssh
  ok "~/.ssh restored"
  # Prefer the SSH remote for push (no credential helper needed) — but only
  # if a private key actually landed and the repo has git metadata yet.
  if [ -f ~/.ssh/id_ed25519 ] || [ -f ~/.ssh/id_ed25519.pub ]; then
    if git -C "$REPO_DIR" remote set-url origin git@github.com:jamespakele/nixos-config.git 2>/dev/null; then
      ok "remote switched to SSH (was https)"
    else
      warn "no .git yet — the git-init step below sets the SSH remote"
    fi
  else
    warn "no id_ed25519 in the restored ~/.ssh — push will need HTTPS + token instead"
  fi
else
  warn "~/.ssh not restored (no data partition / no backup). git push will be skipped later."
fi

step "Restore ~/.pi (optional; pi/omp state, extensions, sessions)"
if [ "$DATA_READY" = 1 ]; then
  PI_SRC=""
  [ -d /srv/data/pi-backup/.pi ] && PI_SRC=/srv/data/pi-backup/.pi
  [ -z "$PI_SRC" ] && [ -d /srv/data/pi-backup ] && [ -n "$(ls -A /srv/data/pi-backup 2>/dev/null)" ] && PI_SRC=/srv/data/pi-backup
  if [ -n "$PI_SRC" ]; then
    if [ -e ~/.pi ]; then
      TS="$(date +%Y%m%d-%H%M%S)"
      mv ~/.pi ~/.pi.pre-"$TS" && echo "existing ~/.pi backed up as ~/.pi.pre-$TS"
    fi
    cp -a "$PI_SRC" ~/.pi && ok "~/.pi restored from $PI_SRC"
  else
    warn "no pi backup found under /srv/data/pi-backup"
  fi
else
  warn "~/.pi not restored (no data partition). Re-run this script after it's available."
fi

step "Rebuild: build first, then switch (house rule)"
cd "$REPO_DIR"
# Real hardware-configuration.nix + flake.lock were staged by bootstrap.sh.
sudo nixos-rebuild build --flake "$REPO_DIR#nixos" \
  || { fail "build failed — fix and re-run this script"; exit 1; }
ok "build clean"
sudo nixos-rebuild switch --flake "$REPO_DIR#nixos" \
  || { fail "switch failed — read the error above"; exit 1; }
ok "switched — system is live"

step "Verify /srv/data actually mounted (nofail can hide a bad fstab entry)"
if [ -e /dev/disk/by-label/data ]; then
  if findmnt -no SOURCE /srv/data >/dev/null 2>&1; then
    ok "/srv/data mounted from $(findmnt -no SOURCE /srv/data)"
  else
    warn "/srv/data NOT mounted — check: systemctl status srv-data.mount (declared nofail, so boot did not block)"
  fi
else
  echo "no data partition on this machine — nothing to verify"
fi

step "Commit + push (the pushed repo is the only off-machine config backup)"
# Plain USB copies ship without .git; bootstrap's staged copy keeps .git only
# when the kit itself was a checkout. Recover either way — WITHOUT force-push:
# sit the local state on top of the fetched remote history so the push is a
# normal fast-forward.
if [ ! -d .git ]; then
  git init -b master
  git remote add origin git@github.com:jamespakele/nixos-config.git
  echo "(initialized fresh git repo)"
  if git fetch origin master 2>/dev/null; then
    # Adopt the remote history without touching the working tree (works from
    # an unborn branch, where `git reset --soft` can fail):
    git update-ref refs/heads/master FETCH_HEAD
    echo "(local tree sits on fetched origin/master — push will fast-forward)"
  else
    warn "could not fetch origin/master (network/keys?). The first push would create an unrelated history and be rejected — once keys work run: git fetch origin master && git update-ref refs/heads/master FETCH_HEAD, then re-run this script."
  fi
fi
git config user.name  "James Pakele"
git config user.email "jamespakele@gmail.com"
echo "branch: $(git branch --show-current 2>/dev/null || echo none)   remote: $(git remote get-url origin 2>/dev/null || echo none)"
git add -A
git commit -m "install: real hardware-configuration.nix + flake.lock (bootstrap $(date +%Y-%m-%d))" \
  || echo "nothing to commit"
if git remote get-url origin 2>/dev/null | grep -q '^git@'; then
  if ! git push -u origin master; then
    warn "push failed (keys/auth, or the remote moved past this kit's history). Recovery: git -C $REPO_DIR fetch origin master && git -C $REPO_DIR rebase origin/master && git -C $REPO_DIR push -u origin master"
  else
    ok "pushed to GitHub"
  fi
else
  warn "remote is not SSH (keys not restored?) — push skipped. Restore ~/.ssh, then: git -C $REPO_DIR push -u origin master"
fi

echo
printf '\033[1;32mNext step:\033[0m bash ~/nixos-config/bare-metal/agent-setup.sh\n'
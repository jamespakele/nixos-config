#!/usr/bin/env bash
# agent-setup.sh — run as pakele after first-boot.sh succeeds.
#
#   bash ~/nixos-config/bare-metal/agent-setup.sh
#
# Installs the pi coding agent into ~/.npm-global (NEVER system-wide npm,
# never sudo) and hands off to omp setup via pi itself.
set -uo pipefail

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK: %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; }

step "Preflight"
[ "$(id -u)" -ne 0 ] || { fail "run as pakele, not root"; exit 1; }

step "Runtimes (declared in home.nix: nodejs_22 + bun + git)"
node --version || { fail "node missing — was home.nix applied? re-run first-boot.sh"; exit 1; }
NODE_MAJOR="$(node --version | sed 's/^v//' | cut -d. -f1)"
[ "$NODE_MAJOR" -ge 22 ] || fail "node >= 22.19 required for pi; found $(node --version)"
bun --version  || warn "bun missing — omp runtime degraded"
git --version  || { fail "git missing"; exit 1; }

step "Install pi into ~/.npm-global (no sudo, never system npm)"
mkdir -p ~/.npm-global
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
npm install -g @mariozechner/pi-coding-agent || { fail "pi install failed"; exit 1; }
export PATH="$HOME/.npm-global/bin:$PATH"
pi --version || { fail "pi not runnable — check ~/.npm-global/bin on PATH"; exit 1; }
ok "pi installed and runnable"

if [ ! -d ~/.pi ]; then
  warn "~/.pi is empty — restore the backup (first-boot.sh) or re-run 'pi install npm:...' for your extensions"
fi

step "Handoff: install omp THROUGH pi (the agent-first step)"
cat <<'EOF'

Run:   pi

Then paste this prompt into pi:

  Install @oh-my-pi/pi-coding-agent globally with npm, verify it runs on
  bun, confirm my pi extensions work under it.

pi stays installed as the rescue harness; omp becomes the daily driver.
They share project-local .pi/ conventions, so extensions carry over.

EOF
ok "agent-setup complete"
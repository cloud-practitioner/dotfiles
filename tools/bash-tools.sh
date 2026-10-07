#!/usr/bin/env bash
# The unpinned agent CLIs that Home Manager installs at switch time on Linux
# (home.nix `home.activation.bashTools`), outside the Nix store, from their
# vendors' curl installers, in both profiles (workstation and container):
#
#   curl -fsSL https://herdr.dev/install.sh | sh                  (herdr)
#   curl -fsSL https://pi.dev/install.sh | sh                     (Pi)
#   curl -fsSL https://gh.io/copilot-install | bash               (GitHub Copilot CLI)
#   curl -fsSL https://claude.ai/install.sh | bash                (Claude Code)
#   Antigravity CLI: see ensure_antigravity below for its download and isolation.
#
# All are unpinned, so their own updaters keep them current. Each launcher
# ends up in ~/.local/bin, which home.nix puts first on PATH, and must answer
# `--version` after it is installed (herdr, pi, copilot, claude, and agy for
# Antigravity). Pi, Copilot, and Antigravity run without a controlling terminal
# (setsid) to prevent prompts; Antigravity's rc-file isolation is described below.
#
# herdr's installer puts its static release binary, checked against the
# SHA-256 in herdr's release manifest, at $HERDR_INSTALL_DIR/herdr, here
# ~/.local/bin/herdr, which `herdr update` replaces in place.
# Pi's installer makes a Pi-managed install (pinned dependencies, updated by
# `pi update`) under ~/.pi/agent/install (or $PI_CODING_AGENT_DIR/install),
# with its launcher in the bin directory beside it linked from ~/.local/bin/pi.
# It needs Node.js (tools/node-tools.sh provides it first), migrates only an
# npm-installed Pi itself, and refuses to replace any other, so it runs
# without pnpm's global bin directories or WSL's Windows PATH (/mnt/*) on its
# PATH.
# Copilot's installer puts its binary in $PREFIX/bin (~/.local/bin, which
# `copilot update` updates in place). Once the new Pi or Copilot answers
# `--version`, a pnpm-installed copy from an older switch is removed, so a
# failed install keeps the old one. Claude Code's native launcher is always
# ~/.local/bin/claude, which its updater re-points in place; a pnpm copy could
# not update itself, since that updater only knows npm and native installs.
#
# Antigravity's installer puts the `agy` binary, checked against the SHA-512
# in its release manifest, at <--dir>/agy, and ends by running `agy install`,
# which appends a PATH export to ~/.zshrc, ~/.bashrc, and ~/.profile (and
# purges shell aliases), with no way to turn that off from the script. So it
# runs with a scratch HOME and `--dir ~/.local/bin`: the binary lands in the
# real ~/.local/bin, and the rc files it edits are the scratch HOME's, which
# is removed afterwards, so the files Home Manager owns stay untouched. `agy`
# updates itself in the background.
#
# Every step skips what is already installed and prints nothing then. A step
# that fails does not stop the others; the script then exits non-zero with
# one clear message per failure, which the Home Manager activation turns into
# a warning so the switch still completes.
#
# Node.js, npm, and pnpm come from tools/node-tools.sh, which runs first: this
# script only adds $NVM_DIR/default/bin (the workstation's nvm default Node.js,
# linked by node-tools.sh) and pnpm's global bin directories to its PATH, and
# without pnpm there is no older pnpm copy of Pi or Copilot to remove.
# Usage: tools/bash-tools.sh
# NVM_DIR (default ~/.nvm), PNPM_HOME (default ${XDG_DATA_HOME:-~/.local/share}/pnpm,
# as pnpm itself), HERDR_INSTALL_URL, PI_INSTALL_URL, COPILOT_INSTALL_URL,
# CLAUDE_INSTALL_URL, and ANTIGRAVITY_INSTALL_URL can be overridden; the tests
# point them at local fixtures.
set -euo pipefail

HERDR_INSTALL_URL=${HERDR_INSTALL_URL:-https://herdr.dev/install.sh}
PI_INSTALL_URL=${PI_INSTALL_URL:-https://pi.dev/install.sh}
COPILOT_INSTALL_URL=${COPILOT_INSTALL_URL:-https://gh.io/copilot-install}
CLAUDE_INSTALL_URL=${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}
ANTIGRAVITY_INSTALL_URL=${ANTIGRAVITY_INSTALL_URL:-https://antigravity.google/cli/install.sh}
# home.nix sets the same defaults for the shells (nodePath).
export NVM_DIR=${NVM_DIR:-$HOME/.nvm}
export PNPM_HOME=${PNPM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}

problems=()

say() {
  printf 'bash-tools: %s\n' "$*"
}

# Reports a failed step on stderr and returns non-zero, so `step` records it.
oops() {
  printf 'bash-tools: %s\n' "$*" >&2
  return 1
}

# Runs install step $1, keeps going after a failure, and remembers it.
step() {
  "$@" || problems+=("$1")
}

# Removes pnpm's global package $2 if it left bin $1 in pnpm's global bin
# directory (an older switch installed Pi and Copilot with pnpm). Without
# pnpm there is nothing to remove.
remove_pnpm_global() {
  local bin=$1 pkg=$2 dir
  command -v pnpm >/dev/null 2>&1 || return 0
  dir=$(pnpm bin -g) || oops "pnpm bin -g failed" || return 1
  [ -e "$dir/$bin" ] || [ -L "$dir/$bin" ] || return 0
  say "pnpm remove -g $pkg"
  pnpm remove -g "$pkg" >/dev/null || oops "pnpm remove -g $pkg failed" || return 1
  [ ! -e "$dir/$bin" ] && [ ! -L "$dir/$bin" ] || oops "pnpm remove -g $pkg left $dir/$bin behind"
}

# The PATH for Pi's installer: ~/.local/bin first, without pnpm's global bin
# directories or WSL's Windows PATH (/mnt/*), whose pi it would refuse to
# replace.
pi_installer_path() {
  local dir dirs path=$HOME/.local/bin
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    case "$dir" in
      "" | "$HOME/.local/bin" | "$PNPM_HOME/bin" | "$PNPM_HOME" | /mnt/*) ;;
      *) path=$path:$dir ;;
    esac
  done
  printf '%s\n' "$path"
}

# Pi from its official installer, unless its launcher is already there, then
# without an older pnpm copy.
ensure_pi() {
  local bin=$HOME/.local/bin/pi script out
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || oops "curl is required to install Pi" || return 1
  command -v setsid >/dev/null 2>&1 || oops "setsid is required to install Pi without prompts" || return 1
  script=$(curl -fsSL --proto-redir '=https' "$PI_INSTALL_URL") \
    || oops "cannot download the Pi installer from $PI_INSTALL_URL (offline?)" || return 1
  say "installing Pi with its official installer"
  out=$(printf '%s\n' "$script" | PATH=$(pi_installer_path) setsid -w sh 2>&1) || {
    printf '%s\n' "$out" >&2
    oops "cannot install Pi from $PI_INSTALL_URL (offline?)" || return 1
  }
  [ -x "$bin" ] || oops "the Pi installer did not create $bin" || return 1
  "$bin" --version >/dev/null 2>&1 </dev/null || oops "$bin --version fails after the Pi installer" || return 1
  remove_pnpm_global pi @earendil-works/pi-coding-agent
}

# The GitHub Copilot CLI from its official installer, unless it is already
# there, then without an older pnpm copy.
ensure_copilot() {
  local bin=$HOME/.local/bin/copilot
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || oops "curl is required to install the GitHub Copilot CLI" || return 1
  command -v setsid >/dev/null 2>&1 || oops "setsid is required to install the GitHub Copilot CLI without prompts" || return 1
  say "installing the GitHub Copilot CLI with its official installer"
  curl -fsSL --proto-redir '=https' "$COPILOT_INSTALL_URL" \
    | PREFIX="$HOME/.local" PATH="$HOME/.local/bin:$PATH" setsid -w bash >/dev/null \
    || oops "cannot install the GitHub Copilot CLI from $COPILOT_INSTALL_URL (offline?)" || return 1
  [ -x "$bin" ] || oops "the GitHub Copilot CLI installer did not create $bin" || return 1
  "$bin" --version >/dev/null 2>&1 </dev/null || oops "$bin --version fails after the GitHub Copilot CLI installer" || return 1
  remove_pnpm_global copilot @github/copilot
}

# herdr from its vendor's installer, unless its binary is already there.
ensure_herdr() {
  local bin=$HOME/.local/bin/herdr
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || oops "curl is required to install herdr" || return 1
  say "installing herdr with its vendor's installer"
  curl -fsSL --proto-redir '=https' "$HERDR_INSTALL_URL" | HERDR_INSTALL_DIR="$HOME/.local/bin" sh >/dev/null \
    || oops "cannot install herdr from $HERDR_INSTALL_URL (offline?)" || return 1
  [ -x "$bin" ] || oops "the herdr installer did not create $bin" || return 1
  "$bin" --version >/dev/null 2>&1 </dev/null || oops "$bin --version fails after the herdr installer" || return 1
}

# Claude Code from its native installer, unless its launcher is already there.
ensure_claude() {
  local bin=$HOME/.local/bin/claude
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || oops "curl is required to install Claude Code" || return 1
  say "installing Claude Code with its native installer"
  curl -fsSL --proto-redir '=https' "$CLAUDE_INSTALL_URL" | bash >/dev/null \
    || oops "cannot install Claude Code from $CLAUDE_INSTALL_URL (offline?)" || return 1
  [ -x "$bin" ] || oops "the Claude Code installer did not create $bin" || return 1
  "$bin" --version >/dev/null 2>&1 </dev/null || oops "$bin --version fails after the Claude Code installer" || return 1
}

# The Antigravity CLI from its installer, unless its binary is already there.
# The installer runs from a scratch HOME (see the header) so that it cannot
# edit the real shell rc files, with its install directory pointing at the real
# ~/.local/bin, from a file in that HOME so that nothing it starts can read the
# script from its stdin.
ensure_antigravity() {
  local dir=$HOME/.local/bin scratch out bin=$HOME/.local/bin/agy
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || oops "curl is required to install the Antigravity CLI" || return 1
  command -v setsid >/dev/null 2>&1 || oops "setsid is required to install the Antigravity CLI without prompts" || return 1
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/antigravity-install.XXXXXX") \
    || oops "cannot create a scratch directory for the Antigravity installer" || return 1
  say "installing the Antigravity CLI with its official installer"
  # --compressed: antigravity.google intermittently answers with a
  # gzip-encoded body even when the request did not offer gzip, which plain
  # curl saves undecoded (bash then fails with "cannot execute binary file").
  curl -fsSL --compressed --proto-redir '=https' "$ANTIGRAVITY_INSTALL_URL" -o "$scratch/install.sh" || {
    rm -rf "$scratch"
    oops "cannot download the Antigravity installer from $ANTIGRAVITY_INSTALL_URL (curl failed: network, DNS, or server error)" || return 1
  }
  mkdir -p "$dir"
  out=$(HOME=$scratch setsid -w bash "$scratch/install.sh" --dir "$dir" </dev/null 2>&1) || {
    printf '%s\n' "$out" >&2
    rm -rf "$scratch"
    oops "the Antigravity installer from $ANTIGRAVITY_INSTALL_URL failed (its output is above)" || return 1
  }
  rm -rf "$scratch"
  [ -x "$bin" ] || oops "the Antigravity installer did not create $bin" || return 1
  "$bin" --version >/dev/null 2>&1 </dev/null || oops "$bin --version fails after the Antigravity installer" || return 1
}

main() {
  local msg
  # pnpm refuses global commands while its global bin directory is not on
  # PATH: $PNPM_HOME/bin for pnpm 11+, $PNPM_HOME for older pnpm. Pi's
  # installer needs Node.js, which tools/node-tools.sh linked at
  # $NVM_DIR/default on the workstation.
  export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
  [ ! -d "$NVM_DIR/default/bin" ] || export PATH="$NVM_DIR/default/bin:$PATH"
  step ensure_herdr
  step ensure_pi
  step ensure_copilot
  step ensure_claude
  step ensure_antigravity
  [ "${#problems[@]}" -eq 0 ] || {
    msg="${problems[*]}"
    printf 'bash-tools: failed: %s\n' "${msg//ensure_/}" >&2
    return 1
  }
}

main "$@"

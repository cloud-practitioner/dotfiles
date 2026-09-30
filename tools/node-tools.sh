#!/usr/bin/env bash
# The unpinned agent CLIs that Home Manager installs at switch time on Linux
# (home.nix `home.activation`), outside the Nix store:
#
# - workstation (WSL2): nvm from its official install script, then Node.js LTS
#   with npm as nvm's default, then pnpm, the way Microsoft's Node.js on WSL
#   guide does it
#   (https://learn.microsoft.com/en-us/windows/dev-environment/javascript/nodejs-on-wsl),
#   then the tools below on that Node.js;
# - container: only the tools below, on the devcontainer image's own Node.js
#   and pnpm.
#
# pnpm installs none of these tools; it only removes the copies that an older
# switch installed with it.
#
# All are unpinned, so their own updaters keep them current:
#   curl -fsSL https://pi.dev/install.sh | sh          (Pi)
#   curl -fsSL https://gh.io/copilot-install | bash    (GitHub Copilot CLI)
#   curl -fsSL https://claude.ai/install.sh | bash     (Claude Code)
# Each launcher ends up in ~/.local/bin, which home.nix puts first on PATH and
# which comes first on the PATH the installers get, and must answer
# `--version` after it is installed. The installers run without a controlling
# terminal (setsid), so they never prompt or edit a shell rc file.
#
# Pi's installer makes a Pi-managed install (pinned dependencies, updated by
# `pi update`) under ~/.pi/agent/install (or $PI_CODING_AGENT_DIR/install),
# with its launcher in the bin directory beside it linked from ~/.local/bin/pi.
# It migrates only an npm-installed Pi itself and refuses to replace any
# other, so a pnpm-installed Pi from an older switch is removed first, as the
# installer asks, once its script has downloaded.
# Copilot's installer puts its binary in $PREFIX/bin (~/.local/bin, which
# `copilot update` updates in place); a pnpm-installed copy from an older
# switch is removed after it. Claude Code's native launcher is always
# ~/.local/bin/claude, which its updater re-points in place; a pnpm copy could
# not update itself, since that updater only knows npm and native installs.
#
# On the workstation it also points $NVM_DIR/default at nvm's default Node.js,
# so shells that do not load nvm (home.nix puts $NVM_DIR/default/bin on PATH)
# still find node, npm, and pnpm.
#
# Every step skips what is already installed and prints nothing then. Any
# failure exits non-zero with one clear message; the Home Manager activation
# turns that into a warning so the switch still completes.
# Usage: tools/node-tools.sh workstation|container
# NVM_DIR (default ~/.nvm), PNPM_HOME (default ${XDG_DATA_HOME:-~/.local/share}/pnpm,
# as pnpm itself), NVM_INSTALL_URL, PI_INSTALL_URL, COPILOT_INSTALL_URL, and
# CLAUDE_INSTALL_URL can be overridden; the tests point them at local fixtures.
set -euo pipefail

NVM_VERSION=v0.40.8
NVM_INSTALL_URL=${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh}
PI_INSTALL_URL=${PI_INSTALL_URL:-https://pi.dev/install.sh}
COPILOT_INSTALL_URL=${COPILOT_INSTALL_URL:-https://gh.io/copilot-install}
CLAUDE_INSTALL_URL=${CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}
# home.nix sets the same defaults for the shells (nodePath).
export NVM_DIR=${NVM_DIR:-$HOME/.nvm}
export PNPM_HOME=${PNPM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}

say() {
  printf 'node-tools: %s\n' "$*"
}

die() {
  printf 'node-tools: %s\n' "$*" >&2
  exit 1
}

# nvm is written for interactive shells, not errexit/nounset: run it without them.
nvm_run() {
  local status=0
  set +eu
  nvm "$@"
  status=$?
  set -eu
  return "$status"
}

ensure_nvm() {
  [ ! -s "$NVM_DIR/nvm.sh" ] || return 0
  command -v curl >/dev/null 2>&1 || die "curl is required to install nvm"
  say "installing nvm $NVM_VERSION into $NVM_DIR"
  # The installer refuses a custom NVM_DIR that does not exist yet.
  mkdir -p "$NVM_DIR"
  # PROFILE=/dev/null keeps the installer out of the shell rc files; home.nix
  # sets NVM_DIR and PATH for every shell and loads nvm in the workstation zsh.
  curl -fsSL --proto-redir '=https' "$NVM_INSTALL_URL" | PROFILE=/dev/null bash >/dev/null \
    || die "cannot install nvm from $NVM_INSTALL_URL (offline?)"
  [ -s "$NVM_DIR/nvm.sh" ] || die "the nvm install script did not create $NVM_DIR/nvm.sh"
}

load_nvm() {
  set +eu
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh" --no-use
  set -eu
  command -v nvm >/dev/null 2>&1 || die "$NVM_DIR/nvm.sh did not define nvm"
}

# A default Node.js (Node.js LTS on a fresh install), active in this process
# and linked from $NVM_DIR/default.
ensure_node() {
  local default bin
  default=$(nvm_run version default 2>/dev/null || true)
  if [[ $default != v* ]]; then
    say "installing Node.js LTS with nvm"
    nvm_run install --lts --no-progress >/dev/null || die "nvm install --lts failed (offline?)"
    nvm_run alias default 'lts/*' >/dev/null || die "cannot make Node.js LTS nvm's default"
  fi
  nvm_run use --silent default || die "cannot switch to nvm's default Node.js"
  case "$(command -v npm || true)" in
    "$NVM_DIR"/*) ;;
    *) die "npm does not come from nvm's default Node.js (got '$(command -v npm || true)')" ;;
  esac
  bin=$(dirname "$(command -v npm)")
  ln -sfn "$(dirname "$bin")" "$NVM_DIR/default" || die "cannot link $NVM_DIR/default to nvm's default Node.js"
}

ensure_pnpm() {
  local prefix
  prefix=$(npm prefix -g) || die "npm prefix -g failed"
  [ ! -x "$prefix/bin/pnpm" ] || return 0
  say "installing pnpm with npm"
  npm install -g pnpm >/dev/null || die "npm install -g pnpm failed (offline?)"
  [ -x "$prefix/bin/pnpm" ] || die "npm installed pnpm without $prefix/bin/pnpm"
}

# Removes pnpm's global package $2 if it left bin $1 in pnpm's global bin
# directory (an older switch installed Pi and Copilot with pnpm).
remove_pnpm_global() {
  local bin=$1 pkg=$2 dir
  dir=$(pnpm bin -g) || die "pnpm bin -g failed"
  [ -e "$dir/$bin" ] || [ -L "$dir/$bin" ] || return 0
  say "pnpm remove -g $pkg"
  pnpm remove -g "$pkg" >/dev/null || die "pnpm remove -g $pkg failed"
  [ ! -e "$dir/$bin" ] && [ ! -L "$dir/$bin" ] || die "pnpm remove -g $pkg left $dir/$bin behind"
}

# Pi from its official installer, unless its launcher is already there.
ensure_pi() {
  local bin=$HOME/.local/bin/pi script out
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || die "curl is required to install Pi"
  command -v setsid >/dev/null 2>&1 || die "setsid is required to install Pi without prompts"
  script=$(curl -fsSL --proto-redir '=https' "$PI_INSTALL_URL") \
    || die "cannot download the Pi installer from $PI_INSTALL_URL (offline?)"
  remove_pnpm_global pi @earendil-works/pi-coding-agent
  say "installing Pi with its official installer"
  out=$(printf '%s\n' "$script" | PATH="$HOME/.local/bin:$PATH" setsid -w sh 2>&1) || {
    printf '%s\n' "$out" >&2
    die "cannot install Pi from $PI_INSTALL_URL (offline?)"
  }
  [ -x "$bin" ] || die "the Pi installer did not create $bin"
  "$bin" --version >/dev/null 2>&1 </dev/null || die "$bin --version fails after the Pi installer"
}

# The GitHub Copilot CLI from its official installer, unless it is already
# there, then without an older pnpm copy.
ensure_copilot() {
  local bin=$HOME/.local/bin/copilot
  if [ ! -x "$bin" ]; then
    command -v curl >/dev/null 2>&1 || die "curl is required to install the GitHub Copilot CLI"
    command -v setsid >/dev/null 2>&1 || die "setsid is required to install the GitHub Copilot CLI without prompts"
    say "installing the GitHub Copilot CLI with its official installer"
    curl -fsSL --proto-redir '=https' "$COPILOT_INSTALL_URL" \
      | PREFIX="$HOME/.local" PATH="$HOME/.local/bin:$PATH" setsid -w bash >/dev/null \
      || die "cannot install the GitHub Copilot CLI from $COPILOT_INSTALL_URL (offline?)"
    [ -x "$bin" ] || die "the GitHub Copilot CLI installer did not create $bin"
    "$bin" --version >/dev/null 2>&1 </dev/null || die "$bin --version fails after the GitHub Copilot CLI installer"
  fi
  remove_pnpm_global copilot @github/copilot
}

# Claude Code from its native installer, unless its launcher is already there.
ensure_claude() {
  local bin=$HOME/.local/bin/claude
  [ ! -x "$bin" ] || return 0
  command -v curl >/dev/null 2>&1 || die "curl is required to install Claude Code"
  say "installing Claude Code with its native installer"
  curl -fsSL --proto-redir '=https' "$CLAUDE_INSTALL_URL" | bash >/dev/null \
    || die "cannot install Claude Code from $CLAUDE_INSTALL_URL (offline?)"
  [ -x "$bin" ] || die "the Claude Code installer did not create $bin"
  "$bin" --version >/dev/null 2>&1 </dev/null || die "$bin --version fails after the Claude Code installer"
}

main() {
  case "${1:-}" in
    workstation)
      ensure_nvm
      load_nvm
      ensure_node
      ensure_pnpm
      ;;
    container)
      command -v pnpm >/dev/null 2>&1 \
        || die "pnpm not found on PATH; the devcontainer image should provide Node.js and pnpm"
      ;;
    *)
      echo "Usage: $0 workstation|container" >&2
      return 2
      ;;
  esac
  mkdir -p "$PNPM_HOME"
  # pnpm refuses global commands while its global bin directory is not on
  # PATH: $PNPM_HOME/bin for pnpm 11+, $PNPM_HOME for older pnpm.
  export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
  ensure_pi
  ensure_copilot
  ensure_claude
}

main "$@"

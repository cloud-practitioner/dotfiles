#!/usr/bin/env bash
# The Node.js-based CLIs that Home Manager installs at switch time on Linux
# (home.nix `home.activation`), outside the Nix store:
#
# - workstation (WSL2): nvm from its official install script, then Node.js LTS
#   with npm as nvm's default, then pnpm, the way Microsoft's Node.js on WSL
#   guide does it
#   (https://learn.microsoft.com/en-us/windows/dev-environment/javascript/nodejs-on-wsl),
#   then the pnpm tools below on that Node.js;
# - container: only the pnpm tools, on the devcontainer image's own Node.js and
#   pnpm.
#
# The pnpm tools are unpinned, so their own updaters keep them current:
#   pnpm add -g --ignore-scripts @earendil-works/pi-coding-agent   (Pi)
#   pnpm add -g @github/copilot                                    (GitHub Copilot CLI)
#   pnpm add -g @anthropic-ai/claude-code                          (Claude Code)
# pnpm blocks dependency build scripts by default. Claude Code's own
# postinstall fetches its native binary, so exactly that one is allowed
# (--allow-build); Pi and Copilot run without any. Each CLI must answer
# `--version` after it is installed.
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
# as pnpm itself), and NVM_INSTALL_URL can be overridden; the tests point them
# at local fixtures.
set -euo pipefail

NVM_VERSION=v0.40.8
NVM_INSTALL_URL=${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh}
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

# `pnpm add -g` $2... unless bin $1 is already in pnpm's global bin directory,
# then check that the new bin runs.
ensure_pnpm_global() {
  local bin=$1 dir
  shift
  dir=$(pnpm bin -g) || die "pnpm bin -g failed"
  [ ! -x "$dir/$bin" ] || return 0
  say "pnpm add -g $*"
  pnpm add -g "$@" >/dev/null || die "pnpm add -g $* failed (offline?)"
  [ -x "$dir/$bin" ] || die "pnpm add -g $* did not install $dir/$bin"
  "$dir/$bin" --version >/dev/null 2>&1 </dev/null || die "$dir/$bin --version fails after pnpm add -g $*"
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
  ensure_pnpm_global pi --ignore-scripts @earendil-works/pi-coding-agent
  ensure_pnpm_global copilot @github/copilot
  ensure_pnpm_global claude --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code
}

main "$@"

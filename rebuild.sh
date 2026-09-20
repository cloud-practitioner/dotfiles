#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ln -sfn "$DIR" ~/.dotfiles
if [ "$(uname -s)" = "Darwin" ]; then
  exec sudo darwin-rebuild switch --flake ~/.dotfiles#mac
fi
# Linux: apply the user-level config with standalone home-manager (no sudo).
case "$(uname -m)" in
  x86_64) HM_SYSTEM="x86_64-linux" ;;
  aarch64 | arm64) HM_SYSTEM="aarch64-linux" ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac
# Inside a devcontainer, apply the container profile: same shell/tools but no
# host SSH agent/keys (git auth comes from the WSL2 host via VS Code's forwarded
# agent, using plain github.com URLs).
PROFILE_PREFIX=""
if [ -f /.dockerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${CODESPACES:-}" ]; then
  PROFILE_PREFIX="container-"
fi
TARGET=~/.dotfiles#"$(whoami)@${PROFILE_PREFIX}${HM_SYSTEM}"
# The home-manager CLI lands in ~/.nix-profile/bin after the first switch, but
# that isn't on PATH in a shell started before it existed. Fall back to running
# it straight from the flake so rebuild.sh works in any shell.
if command -v home-manager >/dev/null 2>&1; then
  exec home-manager switch --flake "$TARGET"
fi
exec nix run github:nix-community/home-manager/release-26.05 -- switch --flake "$TARGET"

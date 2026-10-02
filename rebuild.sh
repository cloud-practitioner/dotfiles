#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tools/link-dotfiles.sh
. "$DIR/tools/link-dotfiles.sh"
link_dotfiles "$DIR" || exit 1
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
# host SSH agent/config. The devcontainer (cloud-practitioner/agentic-devcontainer)
# bind-mounts the host ~/.ssh read-only, proxies the WSL2 ssh-agent socket, and
# recreates the host aliases in its Dockerfile.
PROFILE_PREFIX=""
if [ -f /.dockerenv ] || [ -n "${REMOTE_CONTAINERS:-}" ] || [ -n "${CODESPACES:-}" ]; then
  PROFILE_PREFIX="container-"
fi
TARGET=~/.dotfiles#"$(whoami)@${PROFILE_PREFIX}${HM_SYSTEM}"
# Always use the Home Manager CLI revision locked in flake.lock.
# Intentionally omit -b backup so a colliding file stops the switch.
exec nix run --inputs-from ~/.dotfiles home-manager -- switch --flake "$TARGET"

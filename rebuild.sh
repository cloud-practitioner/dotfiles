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
# The home-manager CLI lands in ~/.nix-profile/bin after the first switch, but
# that isn't on PATH in a shell started before it existed. Fall back to running
# it straight from the flake (the revision locked in flake.lock) so rebuild.sh works in any shell.
if command -v home-manager >/dev/null 2>&1; then
  exec home-manager switch --flake "$TARGET"
fi
exec nix run --inputs-from ~/.dotfiles home-manager -- switch --flake "$TARGET"

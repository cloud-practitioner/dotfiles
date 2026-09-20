#!/usr/bin/env bash
# Takes a fresh machine from nothing to a built config: nix-darwin on macOS,
# standalone home-manager on Linux. Run this once, then use ./rebuild.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

echo "==> Step 1: Determinate Nix"
if command -v nix >/dev/null 2>&1; then
  echo "    nix already installed, skipping"
else
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

echo "==> Step 2: symlink this repo to ~/.dotfiles"
# home.nix resolves its mkOutOfStoreSymlink paths through ~/.dotfiles, so this
# has to exist before the first switch or the build will fail to find them.
ln -sfn "$DIR" ~/.dotfiles

echo "==> Step 3: personalize the configured username"
# Do this before any sudo call: sudo resets $USER to root, so whoami has to
# run as the real interactive user first.
REAL_USER="$(whoami)"
FLAKE_USER="$(sed -nE 's/^[[:space:]]*user = "([^"]+)";.*/\1/p' "$DIR/flake.nix" | head -n1)"
if [ -z "$FLAKE_USER" ]; then
  echo "    Could not find the single \"user = \" line in flake.nix."
  echo "    Edit flake.nix yourself before continuing."
  exit 1
elif [ "$FLAKE_USER" != "$REAL_USER" ]; then
  echo "    flake.nix is configured for user \"$FLAKE_USER\", but you are \"$REAL_USER\"."
  read -r -p "    Rewrite flake.nix's \"user = \" line to \"$REAL_USER\"? [y/N] " REPLY
  if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    # Portable in-place edit: BSD sed (macOS) needs `-i ''` while GNU sed
    # (Linux) rejects it, so write to a temp file and move it back instead.
    # Keep the temp in flake.nix's own dir so the mv is an atomic same-fs
    # rename, and clean it up if sed fails under `set -e`.
    tmp="$(mktemp "$DIR/flake.nix.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    sed -E "s/^([[:space:]]*user = \")[^\"]+(\";.*)/\1${REAL_USER}\2/" "$DIR/flake.nix" >"$tmp"
    mv "$tmp" "$DIR/flake.nix"
    trap - EXIT
    echo "    Updated. Review the change with: git diff flake.nix"
  else
    echo "    Skipped. Edit the single \"user = \" line in flake.nix yourself before continuing."
    exit 1
  fi
else
  echo "    flake.nix already matches \"$REAL_USER\", nothing to do."
fi

echo "==> Step 4: first switch"
# darwin-rebuild / home-manager don't exist yet on a fresh machine, so run
# them straight from their flakes this once. After this, rebuild.sh works.
# sudo resets PATH to a secure default that excludes /nix/.../bin, so a
# freshly installed `nix` would not be found under sudo even though it's
# on PATH here. Resolve the absolute path first and invoke that instead.
NIX_BIN="$(command -v nix)"
if [ "$(uname -s)" = "Darwin" ]; then
  # macOS: nix-darwin manages the whole system (defaults, Homebrew, home.nix).
  # This fetches darwin-rebuild from the nix-darwin-26.05 release branch, not
  # the exact flake.lock revision; the applied config is still pinned by this
  # repo's flake.lock. "mac" is the flake host label - if you renamed it,
  # change it in flake.nix and rebuild.sh too.
  sudo "$NIX_BIN" run github:nix-darwin/nix-darwin/nix-darwin-26.05#darwin-rebuild -- \
    switch --flake ~/.dotfiles#mac
else
  # Linux: nix-darwin can't run here, so apply the user-level config with
  # standalone home-manager instead. No sudo - home-manager is per-user.
  # `-b backup` renames any pre-existing dotfiles it would overwrite instead
  # of failing (e.g. an existing ~/.zshrc becomes ~/.zshrc.backup).
  case "$(uname -m)" in
    x86_64) HM_SYSTEM="x86_64-linux" ;;
    aarch64 | arm64) HM_SYSTEM="aarch64-linux" ;;
    *) echo "    Unsupported CPU: $(uname -m)"; exit 1 ;;
  esac
  "$NIX_BIN" run github:nix-community/home-manager/release-26.05 -- \
    switch -b backup --flake ~/.dotfiles#"${REAL_USER}@${HM_SYSTEM}"
  # home-manager can't change your login shell; do it once so zsh is the default.
  case "${SHELL:-}" in
    */zsh) : ;;
    *) echo "    To make zsh your login shell: chsh -s \"\$(command -v zsh)\" (then reopen the terminal)." ;;
  esac
fi
# If this still fails with "nix: command not found", open a new terminal
# (Determinate adds nix to new shells' PATH) and re-run ./bootstrap.sh.

echo "==> Done. Use ./rebuild.sh for future changes."

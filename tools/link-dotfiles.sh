#!/usr/bin/env bash
# Sourced by bootstrap.sh and rebuild.sh. home.nix resolves its
# mkOutOfStoreSymlink paths through ~/.dotfiles, so that path has to reach the
# repo. Check-then-act, so re-runs change nothing:
# - already resolves to the repo (cloned straight into ~/.dotfiles, or linked
#   earlier): leave it alone. `ln -sfn` onto a real directory would create
#   ~/.dotfiles/.dotfiles inside the repo and dirty the tree;
# - absent, or a symlink elsewhere (the repo moved): (re)point it at the repo;
# - anything else (a different real directory or file): refuse, never clobber.
# Usage: link_dotfiles <repo-dir>   (returns 1 with a message on refusal)
link_dotfiles() {
  local repo target
  repo="$(readlink -f "$1")"
  target="$HOME/.dotfiles"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ "$(readlink -f "$target")" = "$repo" ]; then
      return 0
    fi
    if [ ! -L "$target" ]; then
      echo "    $target already exists and is not this repo ($repo)." >&2
      echo "    Move it aside or remove it, or clone/move the repo to $target, then re-run." >&2
      return 1
    fi
  fi
  ln -sfn "$repo" "$target"
}

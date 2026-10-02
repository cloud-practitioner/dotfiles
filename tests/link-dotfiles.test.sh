#!/usr/bin/env bash
# Behavior checks for tools/link-dotfiles.sh, which bootstrap.sh and rebuild.sh
# use to make ~/.dotfiles reach the repo. Runs against scratch HOMEs; no nix,
# network, or Home Manager switch.
# Run: bash tests/link-dotfiles.test.sh
#
# Coverage:
# - repo cloned straight into ~/.dotfiles: no self-symlink, tree stays clean;
# - ~/.dotfiles already a symlink to the repo: untouched; re-runs are no-ops;
# - ~/.dotfiles absent: linked to the repo;
# - ~/.dotfiles a symlink elsewhere: re-pointed at the repo;
# - ~/.dotfiles a different real directory: refused, contents untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tools/link-dotfiles.sh
. "$ROOT/tools/link-dotfiles.sh"

command -v git >/dev/null 2>&1 || fail "git is required"
dotfiles_test_tmproot link-dotfiles

new_home() {
  HOME="$TMP_ROOT/$1"
  mkdir -p "$HOME"
  export HOME
}

# 1. repo is ~/.dotfiles
new_home direct
dotfiles_git_init_commit "$HOME/.dotfiles"
link_dotfiles "$HOME/.dotfiles" || fail "direct clone: link_dotfiles failed"
[ ! -e "$HOME/.dotfiles/.dotfiles" ] && [ ! -L "$HOME/.dotfiles/.dotfiles" ] \
  || fail "direct clone: created a self-symlink inside the repo"
[ -z "$(git -C "$HOME/.dotfiles" status --porcelain)" ] || fail "direct clone: tree is dirty"
[ ! -L "$HOME/.dotfiles" ] || fail "direct clone: ~/.dotfiles was replaced by a symlink"
pass "repo cloned into ~/.dotfiles: no self-symlink, clean tree"

# 2. absent, then re-run
new_home absent
dotfiles_git_init_commit "$TMP_ROOT/repo-a"
link_dotfiles "$TMP_ROOT/repo-a" || fail "absent: link_dotfiles failed"
[ "$(readlink -f "$HOME/.dotfiles")" = "$(readlink -f "$TMP_ROOT/repo-a")" ] || fail "absent: not linked to the repo"
before=$(readlink "$HOME/.dotfiles")
link_dotfiles "$TMP_ROOT/repo-a" || fail "absent: re-run failed"
[ "$(readlink "$HOME/.dotfiles")" = "$before" ] || fail "absent: re-run changed the link"
[ ! -e "$TMP_ROOT/repo-a/.dotfiles" ] || fail "absent: created a link inside the repo"
pass "absent ~/.dotfiles is linked; re-run is a no-op"

# 3. symlink elsewhere
new_home stale
dotfiles_git_init_commit "$TMP_ROOT/repo-b"
mkdir -p "$TMP_ROOT/elsewhere"
ln -s "$TMP_ROOT/elsewhere" "$HOME/.dotfiles"
link_dotfiles "$TMP_ROOT/repo-b" || fail "stale link: link_dotfiles failed"
[ "$(readlink -f "$HOME/.dotfiles")" = "$(readlink -f "$TMP_ROOT/repo-b")" ] || fail "stale link: not re-pointed"
[ -z "$(ls -A "$TMP_ROOT/elsewhere")" ] || fail "stale link: wrote into the old target"
pass "symlink elsewhere is re-pointed at the repo"

# 4. different real directory
new_home other
dotfiles_git_init_commit "$TMP_ROOT/repo-c"
mkdir -p "$HOME/.dotfiles"
echo keep >"$HOME/.dotfiles/mine"
err=$(link_dotfiles "$TMP_ROOT/repo-c" 2>&1) && fail "other directory: expected refusal"
assert_contains "$err" "not this repo" "other directory: message missing"
[ ! -L "$HOME/.dotfiles" ] && [ "$(cat "$HOME/.dotfiles/mine")" = keep ] \
  || fail "other directory: contents were disturbed"
[ ! -e "$TMP_ROOT/repo-c/.dotfiles" ] && [ ! -L "$TMP_ROOT/repo-c/.dotfiles" ] || fail "other directory: created a link inside the repo"
pass "different real directory is refused and left alone"

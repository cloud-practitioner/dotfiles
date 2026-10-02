#!/usr/bin/env bash
# Behavioral checks for the container profile's `hm-update` zsh function.
#
# Builds the container profile's generated .zshrc into the Nix store (never
# activating it), then runs hm-update in an interactive zsh with a scratch HOME
# whose ~/.dotfiles is a clone of a scratch "origin". A nix shim logs its
# arguments instead of switching.
#
# Coverage:
# - with ~/.config/dotfiles/applied-rev (the workstation's mount): hm-update
#   checks out exactly that revision, then switches;
# - a -dirty revision warns and uses the commit it is based on;
# - a revision origin does not have warns and falls back to origin/main;
# - without the mount, from a detached checkout: back to main, pulled
#   fast-forward, then switches.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in nix zsh git; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
dotfiles_test_tmproot hm-update
SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
CT="node@container-$SYSTEM"

files=$(nix build --no-link --print-out-paths \
  "$ROOT#homeConfigurations.\"$CT\".config.home-files") || fail "$CT: home-files build failed"

H=$TMP_ROOT/home
ORIGIN=$TMP_ROOT/origin
mkdir -p "$H" "$TMP_ROOT/bin"
{
  cat "$files/.zshrc"
  printf 'HISTFILE="$HOME/.zsh_history"\n'
} >"$H/.zshrc"
cp -L "$files/.zshenv" "$H/.zshenv"
cat >"$TMP_ROOT/bin/nix" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP_ROOT/nix.log"
SHIM
chmod +x "$TMP_ROOT/bin/nix"

dotfiles_git_init_commit "$ORIGIN"
git -C "$ORIGIN" branch -M main
C1=$(git -C "$ORIGIN" rev-parse HEAD)
BRANCH=main
git -C "$ORIGIN" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m second
C2=$(git -C "$ORIGIN" rev-parse HEAD)
git clone -q "$ORIGIN" "$H/.dotfiles" || fail "clone scratch origin"

# hm_update: runs the function; output in HM_OUT, nix calls in nix.log.
hm_update() {
  : >"$TMP_ROOT/nix.log"
  HOME="$H" ZDOTDIR="$H" PATH="$TMP_ROOT/bin:$PATH" TERM=xterm \
    zsh -i -c hm-update </dev/null >"$TMP_ROOT/out" 2>&1 \
    || fail "hm-update failed: $(cat "$TMP_ROOT/out")"
  HM_OUT=$(cat "$TMP_ROOT/out")
  local expected="run --inputs-from $H/.dotfiles home-manager -- switch -b backup --flake $H/.dotfiles#$(id -un)@container-$SYSTEM"
  [ "$(cat "$TMP_ROOT/nix.log")" = "$expected" ] || fail "hm-update must switch the container profile with the locked Home Manager CLI"
}
head_of() { git -C "$H/.dotfiles" rev-parse HEAD; }

mkdir -p "$H/.config/dotfiles"
printf '%s\n' "$C1" >"$H/.config/dotfiles/applied-rev"
hm_update
[ "$(head_of)" = "$C1" ] || fail "follows the workstation's applied revision"
git -C "$H/.dotfiles" symbolic-ref -q HEAD >/dev/null && fail "the checkout is detached"
pass "hm-update checks out the applied revision, not main"

printf '%s-dirty\n' "$C2" >"$H/.config/dotfiles/applied-rev"
hm_update
[ "$(head_of)" = "$C2" ] || fail "a -dirty revision uses its commit"
assert_contains "$HM_OUT" "uncommitted dotfiles changes" "a -dirty revision warns"
pass "hm-update uses the base commit of a dirty workstation revision, with a warning"

git -C "$H/.dotfiles" checkout -q --detach "$C1"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" >"$H/.config/dotfiles/applied-rev"
hm_update
[ "$(head_of)" = "$C2" ] || fail "an unknown revision falls back to origin/main"
assert_contains "$HM_OUT" "not on origin" "an unpushed revision warns"
pass "hm-update falls back to origin/main for a revision origin lacks"

rm -r "$H/.config/dotfiles"
git -C "$H/.dotfiles" checkout -q --detach "$C1"
hm_update
[ "$(head_of)" = "$C2" ] || fail "without a mount, pulls main"
[ "$(git -C "$H/.dotfiles" symbolic-ref --short HEAD)" = "$BRANCH" ] || fail "without a mount, back on $BRANCH"
pass "hm-update without the mount pulls main fast-forward"

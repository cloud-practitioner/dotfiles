#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot herdr-config
SCRIPT="$ROOT/activation/herdr-config-unlink.sh"
H="$TMP_ROOT/home space"
STORE="$TMP_ROOT/store space"
SOURCE="$TMP_ROOT/dotfiles/home/.config/herdr"
OLD="$STORE/old-home-manager-files"
NEW="$STORE/new-home-manager-files"
HERDR="$H/.config/herdr"
mkdir -p "$H/.config" "$STORE" "$SOURCE" "$OLD/.config" "$NEW/.config/herdr"
printf 'authored config\n' >"$TMP_ROOT/config.expected"
printf 'existing session\n' >"$TMP_ROOT/session.expected"
cp "$TMP_ROOT/config.expected" "$SOURCE/config.toml"
cp "$TMP_ROOT/session.expected" "$SOURCE/session.json"
ln -s "$SOURCE" "$OLD/.config/herdr"
ln -s "$SOURCE/config.toml" "$NEW/.config/herdr/config.toml"

unlink_legacy() {
  HOME="$H" bash "$SCRIPT" "$STORE"
}

assert_source_untouched() {
  cmp -s "$TMP_ROOT/config.expected" "$SOURCE/config.toml" || fail "authored config changed"
  cmp -s "$TMP_ROOT/session.expected" "$SOURCE/session.json" || fail "existing session changed"
  [ ! -e "$SOURCE/config.toml.backup" ] || fail "authored config backed up"
  [ ! -L "$SOURCE/config.toml" ] || fail "authored config became a symlink"
}

ln -s "$OLD/.config/herdr" "$HERDR"
unlink_legacy
[ ! -e "$HERDR" ] && [ ! -L "$HERDR" ] || fail "legacy link retained"
assert_source_untouched
unlink_legacy
[ ! -e "$HERDR" ] && [ ! -L "$HERDR" ] || fail "absent path recreated"
pass "legacy directory link removed; source untouched; repeat is a no-op"

mkdir -p "$HERDR"
ln -s "$NEW/.config/herdr/config.toml" "$HERDR/config.toml"
printf 'restored session\n' >"$HERDR/session.json"
cp "$HERDR/session.json" "$TMP_ROOT/restored.expected"
unlink_legacy
unlink_legacy
[ -d "$HERDR" ] && [ ! -L "$HERDR" ] || fail "real directory changed"
[ "$(readlink "$HERDR/config.toml")" = "$NEW/.config/herdr/config.toml" ] || fail "file link changed"
cmp -s "$TMP_ROOT/config.expected" "$HERDR/config.toml" || fail "file link no longer readable"
cmp -s "$TMP_ROOT/restored.expected" "$HERDR/session.json" || fail "local runtime state changed"
assert_source_untouched
pass "real directory, readable config link and runtime state preserved"
rm "$HERDR/config.toml" "$HERDR/session.json"
rmdir "$HERDR"

ln -s "$STORE/gone-home-manager-files/.config/herdr" "$HERDR"
unlink_legacy
[ ! -L "$HERDR" ] || fail "dangling legacy link retained"
pass "dangling Home Manager link removed"

keep_foreign_link() {
  local target=$1
  ln -s "$target" "$HERDR"
  unlink_legacy
  unlink_legacy
  [ -L "$HERDR" ] && [ "$(readlink "$HERDR")" = "$target" ] || fail "foreign symlink changed: $target"
  assert_source_untouched
  rm "$HERDR"
}

keep_foreign_link "$SOURCE"
keep_foreign_link "$TMP_ROOT/missing"
keep_foreign_link "$STORE/other-package/.config/herdr"
keep_foreign_link "$STORE-other/old-home-manager-files/.config/herdr"
keep_foreign_link '../owner-herdr'
pass "live, dangling, relative and store-lookalike foreign links preserved"

printf 'owner file\n' >"$HERDR"
cp "$HERDR" "$TMP_ROOT/owner.expected"
unlink_legacy
cmp -s "$TMP_ROOT/owner.expected" "$HERDR" || fail "owner file changed"
pass "owner file preserved"

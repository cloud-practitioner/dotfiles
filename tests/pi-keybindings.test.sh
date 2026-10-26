#!/usr/bin/env bash
# Behavior checks for Pi's word-delete keybindings: home/.pi/agent/keybindings.json,
# its ~/.pi/agent/keybindings.json home.file link in home.nix, and
# activation/pi-keybindings.sh, which links the file into $PI_CODING_AGENT_DIR
# when that points elsewhere. Everything runs against a scratch HOME and scratch
# directories. The home.nix check also needs nix and is skipped without it.
# Run: bash tests/pi-keybindings.test.sh
#
# Coverage:
# - the file is valid JSON; each word-delete action keeps Pi's defaults and adds
#   the Ctrl keys (backward: ctrl+backspace, ctrl+h; forward: ctrl+delete), and
#   it rebinds nothing else;
# - home.nix: ~/.pi/agent/keybindings.json is an ordinary, unforced home.file
#   link into the dotfiles' copy, and the script runs after linking;
# - PI_CODING_AGENT_DIR unset, empty, naming ~/.pi/agent (also via ~ or a
#   trailing slash): nothing is touched and nothing is printed;
# - a relative path is ignored with a warning;
# - set to another directory: absent or empty directory gets the link; a re-run
#   is a no-op; unrelated files stay;
# - an owner's keybindings.json (real file, link, dangling link) is never
#   overwritten, moved or deleted: it is kept with a warning.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/activation/pi-keybindings.sh"
SRC="$ROOT/home/.pi/agent/keybindings.json"
dotfiles_test_tmproot pi-keybindings
CASE=0
OUT=

# --- the keybindings file ---------------------------------------------------------

jq -e . "$SRC" >/dev/null || fail "keybindings.json is valid JSON"
jq -e '
  keys == ["tui.editor.deleteWordBackward", "tui.editor.deleteWordForward"]
  and .["tui.editor.deleteWordBackward"] == ["ctrl+w", "alt+backspace", "ctrl+backspace", "ctrl+h"]
  and .["tui.editor.deleteWordForward"] == ["alt+d", "alt+delete", "ctrl+delete"]' "$SRC" >/dev/null ||
  fail "keybindings.json keeps Pi's word-delete defaults and adds ctrl+backspace, ctrl+h and ctrl+delete: $(cat "$SRC")"
pass "keybindings.json adds the Ctrl word-delete keys to Pi's defaults"

# --- home.nix, as Home Manager evaluates it -------------------------------------

if command -v nix >/dev/null 2>&1; then
  case $(uname -m) in
    aarch64 | arm64) sys=aarch64-linux ;;
    *) sys=x86_64-linux ;;
  esac
  # shellcheck disable=SC2016
  facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#homeConfigurations" --apply '
    hcs: builtins.mapAttrs (_: hc: let c = hc.config; f = c.home.file.".pi/agent/keybindings.json"; in {
      inherit (f) enable force target;
      dotfiles = f.source.outPath
        == (c.lib.file.mkOutOfStoreSymlink "${c.home.homeDirectory}/.dotfiles/home/.pi/agent/keybindings.json").outPath;
      installAfter = c.home.activation.piKeybindings.after;
    }) (builtins.removeAttrs hcs (builtins.filter (n: builtins.match ".*[@-]'"$sys"'" n == null) (builtins.attrNames hcs)))' \
    2>"$TMP_ROOT/nix.err") || fail "home.nix evaluates: $(cat "$TMP_ROOT/nix.err")"
  [ "$(jq 'length' <<<"$facts")" -ge 2 ] || fail "home.nix: workstation and container configs found for $sys: $facts"
  jq -e 'all(.[]; .enable and (.force | not) and .target == ".pi/agent/keybindings.json" and .dotfiles and (.installAfter | index("linkGeneration")))' <<<"$facts" >/dev/null ||
    fail "home.nix: ~/.pi/agent/keybindings.json is an unforced home.file link into the dotfiles' copy, linked before the script runs: $facts"
  pass "home.nix links ~/.pi/agent/keybindings.json to the dotfiles' copy and runs the script after linking"
else
  pass "home.nix check # SKIP nix not on PATH"
fi

# --- the script ------------------------------------------------------------------

# Fresh scratch HOME; sets H and P (a configured directory path that is not created).
new_case() {
  CASE=$((CASE + 1))
  H="$TMP_ROOT/$CASE/home"
  P="$TMP_ROOT/$CASE/agent"
  mkdir -p "$H/.pi/agent"
}

# Run the script. $1 is PI_CODING_AGENT_DIR, or "-" for unset.
run() {
  local dir=$1
  if [ "$dir" = - ]; then
    OUT=$(env -u PI_CODING_AGENT_DIR HOME="$H" bash "$SCRIPT" install "$SRC" 2>&1) || fail "script exited non-zero: $OUT"
  else
    OUT=$(env HOME="$H" PI_CODING_AGENT_DIR="$dir" bash "$SCRIPT" install "$SRC" 2>&1) || fail "script exited non-zero: $OUT"
  fi
}

snapshot() {
  find "$@" -printf '%p %y %m %l\n' 2>/dev/null | sort
  find "$@" -type f -exec sha256sum {} + 2>/dev/null | sort
}

# Unset, empty, or naming ~/.pi/agent: Home Manager's link alone.
for mode in unset empty home trailing tilde; do
  new_case
  case $mode in
    unset) dir=- ;;
    empty) dir= ;;
    home) dir="$H/.pi/agent" ;;
    trailing) dir="$H/.pi/agent/" ;;
    tilde) dir=$(printf '%s' '~')/.pi/agent ;;
  esac
  before=$(snapshot "$H")
  run "$dir"
  run "$dir"
  [ "$(snapshot "$H")" = "$before" ] || fail "$mode: nothing in HOME changes"
  [ -z "$OUT" ] || fail "$mode: silent, got: $OUT"
  pass "PI_CODING_AGENT_DIR $mode leaves ~/.pi/agent to Home Manager"
done

# A symlinked ~/.pi/agent naming the same directory is not "elsewhere" either.
new_case
rm -rf "$H/.pi/agent"
mkdir -p "$TMP_ROOT/$CASE/real"
ln -s "$TMP_ROOT/$CASE/real" "$H/.pi/agent"
run "$TMP_ROOT/$CASE/real"
[ -z "$OUT" ] && [ ! -e "$TMP_ROOT/$CASE/real/keybindings.json" ] || fail "same directory through a link: untouched, got: $OUT"
pass "a directory that is ~/.pi/agent through a link is left to Home Manager"

# A relative path means nothing to activation.
new_case
OUT=$(cd "$TMP_ROOT/$CASE" && env HOME="$H" PI_CODING_AGENT_DIR=relative/dir bash "$SCRIPT" install "$SRC" 2>&1) || fail "relative: script exited non-zero: $OUT"
assert_contains "$OUT" "warning: PI_CODING_AGENT_DIR=relative/dir is not an absolute path" "relative: reported"
[ ! -e "$TMP_ROOT/$CASE/relative" ] || fail "relative: nothing created"
pass "a relative PI_CODING_AGENT_DIR is ignored with a warning"

# Set elsewhere: the link is created (directory absent, then present and empty).
new_case
run "$P"
[ -L "$P/keybindings.json" ] && [ "$(readlink "$P/keybindings.json")" = "$SRC" ] || fail "link created in an absent directory"
cmp -s "$P/keybindings.json" "$SRC" || fail "the link reads as the dotfiles' keybindings.json"
assert_contains "$OUT" "linked $P/keybindings.json -> $SRC" "link creation reported"
[ ! -e "$H/.pi/agent/keybindings.json" ] || fail "script does not touch ~/.pi/agent (Home Manager's business)"
pass "set elsewhere: keybindings.json linked to the dotfiles' copy"

state=$(snapshot "$P")
run "$P"
[ "$(snapshot "$P")" = "$state" ] && [ -z "$OUT" ] || fail "re-run is a silent no-op, got: $OUT"
pass "re-run is a no-op"

new_case
mkdir -p "$P"
run "$P/"
[ "$(readlink "$P/keybindings.json")" = "$SRC" ] || fail "link created in an existing empty directory (trailing slash)"
pass "an existing empty directory gets the link"

# Unrelated owner files do not matter and stay.
new_case
mkdir -p "$P/sessions"
printf 'secret\n' >"$P/auth.json"
printf '{}\n' >"$P/settings.json"
printf 'mine\n' >"$P/AGENTS.md"
run "$P"
[ "$(readlink "$P/keybindings.json")" = "$SRC" ] || fail "link created beside unrelated files"
[ "$(cat "$P/auth.json")" = secret ] && [ "$(cat "$P/settings.json")" = '{}' ] && [ "$(cat "$P/AGENTS.md")" = mine ] ||
  fail "unrelated files untouched"
pass "unrelated owner files are untouched"

# A real keybindings.json is never overwritten, moved or deleted.
new_case
mkdir -p "$P"
printf '{"app.interrupt": "ctrl+g"}\n' >"$P/keybindings.json"
before=$(snapshot "$P")
run "$P"
[ "$(snapshot "$P")" = "$before" ] || fail "owner file preserved, nothing added"
assert_contains "$OUT" "warning: $P/keybindings.json exists, not linking" "owner file reported"
run "$P"
[ "$(snapshot "$P")" = "$before" ] || fail "re-run changes nothing"
pass "an existing keybindings.json is preserved with a warning"

# An existing link elsewhere is the owner's: kept, with a warning.
new_case
mkdir -p "$P"
printf '{}\n' >"$TMP_ROOT/$CASE/mine.json"
ln -s "$TMP_ROOT/$CASE/mine.json" "$P/keybindings.json"
run "$P"
[ "$(readlink "$P/keybindings.json")" = "$TMP_ROOT/$CASE/mine.json" ] || fail "owner's link kept"
assert_contains "$OUT" "warning: $P/keybindings.json exists" "owner's link reported"
pass "an existing link to something else is kept"

# A dangling link counts as existing.
new_case
mkdir -p "$P"
ln -s "$TMP_ROOT/$CASE/gone.json" "$P/keybindings.json"
run "$P"
[ "$(readlink "$P/keybindings.json")" = "$TMP_ROOT/$CASE/gone.json" ] || fail "dangling link kept"
pass "a dangling link is kept"

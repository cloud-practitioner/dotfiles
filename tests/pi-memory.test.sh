#!/usr/bin/env bash
# Behavior checks for Pi's user memory: the ~/.pi/agent/AGENTS.md home.file link
# in home.nix, and activation/pi-memory.sh, which links home/AGENTS.md into
# $PI_CODING_AGENT_DIR when that points elsewhere. Everything runs against a
# scratch HOME and scratch directories. The home.nix check also needs nix and is
# skipped without it.
# Run: bash tests/pi-memory.test.sh
#
# Coverage:
# - home.nix: ~/.pi/agent/AGENTS.md is an ordinary, unforced home.file link into
#   the dotfiles' home/AGENTS.md, and the script runs after linking;
# - PI_CODING_AGENT_DIR unset, empty, naming ~/.pi/agent (also via ~ or a
#   trailing slash): nothing is touched and nothing is printed;
# - a relative path is ignored with a warning;
# - set to another directory: absent or empty directory gets the link; a re-run
#   is a no-op; a link already pointing elsewhere is kept;
# - owner files are never overwritten, moved or deleted: a real AGENTS.md, and
#   any other file Pi would read as user instructions, is kept with a warning.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/activation/pi-memory.sh"
SRC="$ROOT/home/AGENTS.md"
dotfiles_test_tmproot pi-memory
CASE=0
OUT=

# --- home.nix, as Home Manager evaluates it -------------------------------------

if command -v nix >/dev/null 2>&1; then
  case $(uname -m) in
    aarch64 | arm64) sys=aarch64-linux ;;
    *) sys=x86_64-linux ;;
  esac
  # shellcheck disable=SC2016
  facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#homeConfigurations" --apply '
    hcs: builtins.mapAttrs (_: hc: let c = hc.config; f = c.home.file.".pi/agent/AGENTS.md"; in {
      inherit (f) enable force target;
      dotfiles = f.source.outPath
        == (c.lib.file.mkOutOfStoreSymlink "${c.home.homeDirectory}/.dotfiles/home/AGENTS.md").outPath;
      installAfter = c.home.activation.piMemory.after;
    }) (builtins.removeAttrs hcs (builtins.filter (n: builtins.match ".*[@-]'"$sys"'" n == null) (builtins.attrNames hcs)))' \
    2>"$TMP_ROOT/nix.err") || fail "home.nix evaluates: $(cat "$TMP_ROOT/nix.err")"
  [ "$(jq 'length' <<<"$facts")" -ge 2 ] || fail "home.nix: workstation and container configs found for $sys: $facts"
  jq -e 'all(.[]; .enable and (.force | not) and .target == ".pi/agent/AGENTS.md" and .dotfiles and (.installAfter | index("linkGeneration")))' <<<"$facts" >/dev/null ||
    fail "home.nix: ~/.pi/agent/AGENTS.md is an unforced home.file link into home/AGENTS.md, linked before the script runs: $facts"
  pass "home.nix links ~/.pi/agent/AGENTS.md to home/AGENTS.md and runs the script after linking"
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
[ -z "$OUT" ] && [ ! -e "$TMP_ROOT/$CASE/real/AGENTS.md" ] || fail "same directory through a link: untouched, got: $OUT"
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
[ -L "$P/AGENTS.md" ] && [ "$(readlink "$P/AGENTS.md")" = "$SRC" ] || fail "link created in an absent directory"
cmp -s "$P/AGENTS.md" "$SRC" || fail "the link reads as home/AGENTS.md"
assert_contains "$OUT" "linked $P/AGENTS.md -> $SRC" "link creation reported"
[ ! -e "$H/.pi/agent/AGENTS.md" ] || fail "script does not touch ~/.pi/agent (Home Manager's business)"
pass "set elsewhere: AGENTS.md linked to home/AGENTS.md"

state=$(snapshot "$P")
run "$P"
[ "$(snapshot "$P")" = "$state" ] && [ -z "$OUT" ] || fail "re-run is a silent no-op, got: $OUT"
pass "re-run is a no-op"

new_case
mkdir -p "$P"
run "$P/"
[ "$(readlink "$P/AGENTS.md")" = "$SRC" ] || fail "link created in an existing empty directory (trailing slash)"
pass "an existing empty directory gets the link"

# Unrelated owner files do not matter and stay.
new_case
mkdir -p "$P/sessions"
printf 'secret\n' >"$P/auth.json"
printf '{}\n' >"$P/settings.json"
run "$P"
[ "$(readlink "$P/AGENTS.md")" = "$SRC" ] || fail "link created beside unrelated files"
[ "$(cat "$P/auth.json")" = secret ] && [ "$(cat "$P/settings.json")" = '{}' ] || fail "unrelated files untouched"
pass "unrelated owner files are untouched"

# An existing link elsewhere is the owner's: kept, with a warning.
new_case
mkdir -p "$P"
printf 'mine\n' >"$TMP_ROOT/$CASE/mine.md"
ln -s "$TMP_ROOT/$CASE/mine.md" "$P/AGENTS.md"
run "$P"
[ "$(readlink "$P/AGENTS.md")" = "$TMP_ROOT/$CASE/mine.md" ] || fail "owner's link kept"
assert_contains "$OUT" "warning: $P/AGENTS.md exists" "owner's link reported"
pass "an existing link to something else is kept"

# A dangling link counts as existing.
new_case
mkdir -p "$P"
ln -s "$TMP_ROOT/$CASE/gone.md" "$P/AGENTS.md"
run "$P"
[ "$(readlink "$P/AGENTS.md")" = "$TMP_ROOT/$CASE/gone.md" ] || fail "dangling link kept"
pass "a dangling link is kept"

# Real files are never overwritten, moved or deleted.
for name in AGENTS.md AGENTS.override.md AGENTS.MD CLAUDE.md CLAUDE.MD; do
  new_case
  mkdir -p "$P"
  printf 'owner %s\n' "$name" >"$P/$name"
  before=$(snapshot "$P")
  run "$P"
  [ "$(snapshot "$P")" = "$before" ] || fail "$name: owner file preserved, nothing added"
  [ "$(cat "$P/$name")" = "owner $name" ] || fail "$name: content intact"
  assert_contains "$OUT" "warning: $P/$name exists, not linking" "$name: reported"
  run "$P"
  [ "$(snapshot "$P")" = "$before" ] || fail "$name: re-run changes nothing"
  pass "an existing $name is preserved with a warning"
done

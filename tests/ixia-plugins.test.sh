#!/usr/bin/env bash
# Behavior checks for the Ixia plugin marketplace on Pi (Claude Code's half is
# in tests/claude-config.test.sh): tools/ixia-marketplace.sh, which keeps a real
# shallow clone, and activation/pi-config.sh, which adds the dotfiles' Pi
# `skills` entry to the settings file Pi really reads. Needs bash, git, jq and
# GNU coreutils. Run: bash tests/ixia-plugins.test.sh
#
# Everything runs in a scratch HOME, PI_CODING_AGENT_DIR and clone directory,
# against a local fake marketplace repository (file:// URL, so --depth applies);
# nothing contacts Bitbucket.
#
# Coverage:
# - the tracked Pi settings name <clone>/plugins/ixia-stratex/skills, with the
#   script's own default clone location, and carry no credentials;
# - tools/ixia-marketplace.sh: a fresh shallow clone (the agents/ directory the
#   review-panel skill needs sits two levels above the skills), a no-op re-run,
#   fast-forward to new upstream commits (including several in a row, which a
#   shallow clone must still follow), local uncommitted changes and local
#   commits never discarded, a non-git directory left alone, and offline / no
#   access / no git only warning, exit 0, leaving nothing half-cloned;
# - activation/pi-config.sh: PI_CODING_AGENT_DIR unset, empty or ~/.pi/agent
#   changes nothing; otherwise the `skills` entry is added to the owner's
#   settings.json without changing any other owner value, once, with one backup
#   and the owner's mode, idempotently; an absent file is created with just
#   `skills`; an owner's existing, excluded (-/!/+ prefixed) or non-list
#   `skills`, invalid JSON, and a settings link into the dotfiles are handled
#   without overwriting anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLONE_SCRIPT="$ROOT/tools/ixia-marketplace.sh"
PI_SCRIPT="$ROOT/activation/pi-config.sh"
SRC_PI="$ROOT/home/.pi/agent/settings.json"
ENTRY=$(jq -r '.skills[0]' "$SRC_PI")
dotfiles_test_tmproot ixia-plugins

GIT=(git -c user.name=dotfiles-test -c user.email=dotfiles-test@example.invalid -c commit.gpgsign=false)

# --- the tracked Pi settings ----------------------------------------------------

[ "$(jq '.skills | length' "$SRC_PI")" = 1 ] || fail "pi settings: exactly one skills entry"
default_dir=$(sed -n 's/^DIR=\${IXIA_MARKETPLACE_DIR:-\$HOME\(.*\)}$/\1/p' "$CLONE_SCRIPT")
[ "~$default_dir/plugins/ixia-stratex/skills" = "$ENTRY" ] ||
  fail "pi settings: the skills entry ($ENTRY) is the clone script's default location ($default_dir)"
case $default_dir in /.local/share/*) ;; *) fail "pi settings: the clone lives under ~/.local/share" ;; esac
if grep -qE 'token|password|://[^/ "]*@' "$SRC_PI" "$CLONE_SCRIPT" "$PI_SCRIPT"; then
  fail "no credentials in the settings or scripts"
fi
grep -q '^URL=\${IXIA_MARKETPLACE_URL:-git@bitbucket.org:iqxbusiness/ixia-marketplace.git}$' "$CLONE_SCRIPT" ||
  fail "the clone script defaults to the SSH URL of iqxbusiness/ixia-marketplace"
pass "tracked Pi settings point at the clone script's location; no credentials"

# --- home.nix, as Home Manager evaluates it -------------------------------------

if command -v nix >/dev/null 2>&1; then
  case $(uname -m) in
    aarch64 | arm64) sys=aarch64-linux ;;
    *) sys=x86_64-linux ;;
  esac
  facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#homeConfigurations" --apply '
    hcs: builtins.mapAttrs (_: hc: {
      clone = hc.config.home.activation ? ixiaMarketplace;
      piAfter = hc.config.home.activation.piConfig.after;
    }) (builtins.removeAttrs hcs (builtins.filter (n: builtins.match ".*[@-]'"$sys"'" n == null) (builtins.attrNames hcs)))' \
    2>"$TMP_ROOT/nix.err") || fail "home.nix evaluates: $(cat "$TMP_ROOT/nix.err")"
  [ "$(jq 'length' <<<"$facts")" -ge 2 ] || fail "home.nix: workstation and container configs found for $sys: $facts"
  jq -e 'all(.[]; .clone and (.piAfter | index("linkGeneration")))' <<<"$facts" >/dev/null ||
    fail "home.nix: both profiles clone the marketplace each switch and merge Pi settings after linking: $facts"
  pass "home.nix runs the marketplace clone and the Pi settings merge in both Linux profiles"
else
  pass "home.nix checks # SKIP nix not on PATH"
fi

# --- tools/ixia-marketplace.sh --------------------------------------------------

UP="$TMP_ROOT/upstream"
mkdir -p "$UP/plugins/ixia-stratex/skills/plan-gate" "$UP/plugins/ixia-stratex/agents"
printf 'plan-gate v1\n' >"$UP/plugins/ixia-stratex/skills/plan-gate/SKILL.md"
printf 'reviewer\n' >"$UP/plugins/ixia-stratex/agents/plan-ba.md"
git -C "$UP" init -q -b master
git -C "$UP" add -A
"${GIT[@]}" -C "$UP" commit -qm v1
URL="file://$UP"

new_upstream_commit() {
  printf 'plan-gate %s\n' "$1" >"$UP/plugins/ixia-stratex/skills/plan-gate/SKILL.md"
  "${GIT[@]}" -C "$UP" commit -qam "$1"
}

run_clone() { # [ENV=VAL...]
  OUT=$(env HOME="$HOME_DIR" IXIA_MARKETPLACE_URL="$URL" IXIA_MARKETPLACE_DIR="$DIR" "$@" bash "$CLONE_SCRIPT" 2>&1)
  RC=$?
}

HOME_DIR="$TMP_ROOT/home"
DIR="$TMP_ROOT/share/ixia-marketplace"
mkdir -p "$HOME_DIR"

run_clone
[ "$RC" = 0 ] || fail "clone: exit 0, got $RC: $OUT"
SK="$DIR/plugins/ixia-stratex/skills"
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v1" ] || fail "clone: skills present"
[ -f "$SK/../agents/plan-ba.md" ] || fail "clone: agents/ sits two levels above the skills (review-panel needs it)"
[ "$(git -C "$DIR" rev-parse --is-shallow-repository)" = true ] || fail "clone: shallow"
[ "$(git -C "$DIR" rev-list --count HEAD)" = 1 ] || fail "clone: depth 1"
[ "$(git -C "$DIR" remote get-url origin)" = "$URL" ] || fail "clone: origin is the marketplace URL"
[ "$(find "$(dirname "$DIR")" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || fail "clone: no temporary leftovers"
pass "fresh shallow clone with the plugin's skills and agents"

before=$(git -C "$DIR" rev-parse HEAD)
run_clone
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "re-run: silent no-op: $OUT"
pass "re-run with nothing new is a silent no-op"

new_upstream_commit v2
new_upstream_commit v3
run_clone
[ "$RC" = 0 ] || fail "update: exit 0: $OUT"
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v3" ] || fail "update: fast-forwarded past two new commits: $OUT"
[ "$(git -C "$DIR" status --porcelain | wc -l)" = 0 ] || fail "update: clean tree"
pass "refresh fast-forwards to the marketplace's latest release"

# Local uncommitted changes survive an update that does not touch them, and one
# that does is refused, never forced.
printf 'mine\n' >"$DIR/local-note.txt"
new_upstream_commit v4
run_clone
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v4" ] && [ "$(cat "$DIR/local-note.txt")" = mine ] || fail "local file: update applied, local file kept: $OUT"
printf 'edited\n' >"$SK/plan-gate/SKILL.md"
new_upstream_commit v5
run_clone
[ "$RC" = 0 ] || fail "conflicting local change: exit 0"
[ "$(cat "$SK/plan-gate/SKILL.md")" = edited ] || fail "conflicting local change: never overwritten"
assert_contains "$OUT" "warning:" "conflicting local change: warns"
git -C "$DIR" checkout -q -- . && rm -f "$DIR/local-note.txt"
run_clone
[ "$(cat "$SK/plan-gate/SKILL.md")" = "plan-gate v5" ] || fail "after the local change is gone, the update lands: $OUT"
pass "local changes are never discarded"

# A local commit stops the fast-forward; it is kept, with a warning.
"${GIT[@]}" -C "$DIR" commit -q --allow-empty -m local
local_head=$(git -C "$DIR" rev-parse HEAD)
new_upstream_commit v6
run_clone
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$local_head" ] || fail "local commit kept: $OUT"
assert_contains "$OUT" "warning:" "local commit: warns"
pass "local commits are never discarded"

# Offline / no access: only warnings, nothing half-cloned, nothing removed.
BAD=file://$TMP_ROOT/does-not-exist
before=$(git -C "$DIR" rev-parse HEAD)
run_clone IXIA_MARKETPLACE_URL="$BAD"
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "fetch failure: exit 0, clone kept: $OUT"
assert_contains "$OUT" "warning:" "fetch failure: warns"
DIR="$TMP_ROOT/share2/ixia-marketplace"
run_clone IXIA_MARKETPLACE_URL="$BAD"
[ "$RC" = 0 ] || fail "clone failure: exit 0: $OUT"
assert_contains "$OUT" "warning:" "clone failure: warns"
[ ! -e "$DIR" ] && [ "$(find "$TMP_ROOT/share2" -mindepth 1 | wc -l)" = 0 ] || fail "clone failure: no half-cloned directory or temporary leftovers"
# ... and the next switch with access clones it.
run_clone
[ "$(cat "$DIR/plugins/ixia-stratex/skills/plan-gate/SKILL.md")" = "plan-gate v6" ] || fail "recovery: the next run clones: $OUT"
pass "no network or access only warns and retries next time"

# A directory that is not a git clone is left alone.
DIR="$TMP_ROOT/share3/ixia-marketplace"
mkdir -p "$DIR"
printf 'not mine\n' >"$DIR/keep.txt"
run_clone
[ "$RC" = 0 ] && [ "$(cat "$DIR/keep.txt")" = "not mine" ] && [ "$(find "$DIR" -type f | wc -l)" = 1 ] || fail "non-git directory untouched: $OUT"
assert_contains "$OUT" "not a git clone" "non-git directory: warns"
pass "a non-git directory is left alone with a warning"

# No git on PATH: warns, exits 0.
NOGIT="$TMP_ROOT/nogit-bin"
mkdir -p "$NOGIT"
for tool in bash dirname; do ln -s "$(command -v "$tool")" "$NOGIT/$tool"; done
DIR="$TMP_ROOT/share4/ixia-marketplace"
OUT=$(env -i HOME="$HOME_DIR" PATH="$NOGIT" IXIA_MARKETPLACE_DIR="$DIR" "$NOGIT/bash" "$CLONE_SCRIPT" 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -e "$DIR" ] || fail "no git: exit 0, nothing created: $OUT"
assert_contains "$OUT" "git not found" "no git: warns"
pass "a missing git only warns"

# The default location is under HOME, outside any git repository.
OUT=$(env HOME="$TMP_ROOT/home2" IXIA_MARKETPLACE_URL="$URL" bash "$CLONE_SCRIPT" 2>&1)
[ -f "$TMP_ROOT/home2/.local/share/ixia-marketplace/plugins/ixia-stratex/skills/plan-gate/SKILL.md" ] || fail "default location: $OUT"
pass "default clone location is ~/.local/share/ixia-marketplace"

# --- activation/pi-config.sh ----------------------------------------------------

PH="$TMP_ROOT/pihome"
mkdir -p "$PH/.pi/agent"
run_pi() { # <PI_CODING_AGENT_DIR or - for unset>
  local dir=$1
  if [ "$dir" = - ]; then
    OUT=$(env -u PI_CODING_AGENT_DIR HOME="$PH" bash "$PI_SCRIPT" install "$SRC_PI" 2>&1)
  else
    OUT=$(env HOME="$PH" PI_CODING_AGENT_DIR="$dir" bash "$PI_SCRIPT" install "$SRC_PI" 2>&1)
  fi
  RC=$?
}
tree_sum() { find "$1" -mindepth 0 -printf '%p %y %m %l\n' -type f -exec sha256sum {} + 2>/dev/null | sort; }

for dir in - "" "$PH/.pi/agent" "$PH/.pi/agent/"; do
  before=$(tree_sum "$PH")
  run_pi "$dir"
  [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(tree_sum "$PH")" = "$before" ] || fail "PI_CODING_AGENT_DIR '${dir:-<empty>}': nothing happens: $OUT"
done
pass "PI_CODING_AGENT_DIR unset, empty, or ~/.pi/agent: nothing to do (the linked file is what Pi reads)"

# The devcontainer: the owner's settings in the workspace's .pi.
PD="$TMP_ROOT/workspace/.pi"
mkdir -p "$PD"
cat >"$PD/settings.json" <<'JSON'
{
  "packages": [],
  "lastChangelogVersion": "1.2.0",
  "theme": "dark",
  "hideThinkingBlock": false
}
JSON
chmod 640 "$PD/settings.json"
cp -p "$PD/settings.json" "$TMP_ROOT/pi-owner.orig"
run_pi "$PD"
[ "$RC" = 0 ] || fail "container: exit 0: $OUT"
jq -e --arg e "$ENTRY" '.skills == [$e] and .theme == "dark" and .hideThinkingBlock == false and .packages == []
  and .lastChangelogVersion == "1.2.0" and (keys | length) == 5' "$PD/settings.json" >/dev/null ||
  fail "container: the skills entry added, every owner value kept: $(cat "$PD/settings.json")"
[ "$(stat -c %a "$PD/settings.json")" = 640 ] || fail "container: mode kept"
backups=("$PD"/settings.json.pre-dotfiles-*)
[ "${#backups[@]}" = 1 ] && cmp -s "${backups[0]}" "$TMP_ROOT/pi-owner.orig" || fail "container: one byte-for-byte backup"
state=$(tree_sum "$PD")
run_pi "$PD"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(tree_sum "$PD")" = "$state" ] || fail "container: re-run is a silent no-op: $OUT"
[ ! -e "$PH/.pi/agent/settings.json" ] || fail "container: ~/.pi/agent is not touched"
pass "container: the skills entry reaches \$PI_CODING_AGENT_DIR/settings.json additively, once, with a backup"

# Absent file: created with just `skills`.
PD2="$TMP_ROOT/workspace2/.pi"
run_pi "$PD2"
jq -e --arg e "$ENTRY" '. == {skills: [$e]}' "$PD2/settings.json" >/dev/null || fail "absent: created with just skills: $OUT"
pass "an absent settings file is created with just skills"

# The owner's own skills list: kept, in order; the entry appended once; an
# owner's exclusion or explicit inclusion of the same path is respected.
PD3="$TMP_ROOT/workspace3/.pi"
mkdir -p "$PD3"
printf '{"skills": ["~/mine", "+/exact/skill"], "theme": "light"}\n' >"$PD3/settings.json"
run_pi "$PD3"
jq -e --arg e "$ENTRY" '.skills == ["~/mine", "+/exact/skill", $e] and .theme == "light"' "$PD3/settings.json" >/dev/null ||
  fail "owner skills: kept in order, entry appended: $(cat "$PD3/settings.json")"
for prefix in - ! +; do
  printf '{"skills": ["%s%s"]}\n' "$prefix" "$ENTRY" >"$PD3/settings.json"
  rm -f "$PD3"/settings.json.pre-dotfiles-*
  run_pi "$PD3"
  jq -e --arg e "$prefix$ENTRY" '.skills == [$e]' "$PD3/settings.json" >/dev/null && [ -z "$OUT" ] ||
    fail "owner '$prefix' entry for the same path is respected: $OUT $(cat "$PD3/settings.json")"
  compgen -G "$PD3/settings.json.pre-dotfiles-*" >/dev/null && fail "owner '$prefix' entry: file untouched, no backup"
done
printf '{"skills": ["%s"], "x": 1}\n' "$ENTRY" >"$PD3/settings.json"
run_pi "$PD3"
[ -z "$OUT" ] && [ "$(jq -c . "$PD3/settings.json")" = "{\"skills\":[\"$ENTRY\"],\"x\":1}" ] || fail "owner already lists the entry: untouched: $OUT"
pass "an owner's own, excluded or already-present skills entries are respected"

# Things the merge cannot extend are left untouched, with a warning.
for body in '{"skills": "nope"}' '[1, 2]' '{"skills": ' ; do
  printf '%s\n' "$body" >"$PD3/settings.json"
  rm -f "$PD3"/settings.json.pre-dotfiles-*
  run_pi "$PD3"
  [ "$RC" = 0 ] && [ "$(cat "$PD3/settings.json")" = "$body" ] || fail "unusable owner settings '$body' left untouched: $OUT"
  assert_contains "$OUT" "warning:" "unusable owner settings '$body': warns"
done
pass "non-object, invalid or non-list owner settings are left untouched with a warning"

# A settings link: merged through, the link kept; one into the dotfiles is skipped.
PD4="$TMP_ROOT/workspace4/.pi"
mkdir -p "$PD4" "$TMP_ROOT/ownerfiles"
printf '{"theme": "owner"}\n' >"$TMP_ROOT/ownerfiles/pi.json"
ln -s "$TMP_ROOT/ownerfiles/pi.json" "$PD4/settings.json"
run_pi "$PD4"
[ -L "$PD4/settings.json" ] && jq -e --arg e "$ENTRY" '.skills == [$e] and .theme == "owner"' "$TMP_ROOT/ownerfiles/pi.json" >/dev/null ||
  fail "settings link: merged through, link kept: $OUT"
PD5="$TMP_ROOT/workspace5/.pi"
mkdir -p "$PD5"
ln -s "$SRC_PI" "$PD5/settings.json"
src_sum=$(sha256sum <"$SRC_PI")
run_pi "$PD5"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(sha256sum <"$SRC_PI")" = "$src_sum" ] || fail "settings linked to the dotfiles: not rewritten: $OUT"
mkdir -p "$TMP_ROOT/workspace6/.pi"
ln -s "$TMP_ROOT/gone.json" "$TMP_ROOT/workspace6/.pi/settings.json"
run_pi "$TMP_ROOT/workspace6/.pi"
[ "$RC" = 0 ] && [ ! -e "$TMP_ROOT/gone.json" ] || fail "dangling settings link: nothing created: $OUT"
assert_contains "$OUT" "dangling" "dangling settings link: warns"
pass "settings links are merged through or skipped, never replaced"

# The dotfiles source may not be a dotfiles settings file at all.
OUT=$(env HOME="$PH" PI_CODING_AGENT_DIR="$PD" bash "$PI_SCRIPT" install "$TMP_ROOT/nope.json" 2>&1)
[ $? = 0 ] || fail "unreadable source: exit 0"
assert_contains "$OUT" "warning:" "unreadable source: warns"
env HOME="$PH" bash "$PI_SCRIPT" bogus >/dev/null 2>&1
[ $? = 2 ] || fail "usage error exits 2"
pass "bad input warns or reports usage"

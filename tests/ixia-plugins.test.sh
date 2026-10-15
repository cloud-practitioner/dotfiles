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
#   script's own default clone location, with feedback exactly excluded;
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

EXCLUSION="-$ENTRY/feedback/SKILL.md"
jq -e --arg e "$ENTRY" --arg x "$EXCLUSION" '.skills == [$e, $x]' "$SRC_PI" >/dev/null ||
  fail "pi settings: skills directory included, feedback file exactly excluded"
pass "tracked Pi settings include Ixia skills and exactly exclude feedback"

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
  darwin_facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#darwinConfigurations.mac" --apply '
    dc: builtins.mapAttrs (_: hc: {
      clone = hc.home.activation ? ixiaMarketplace;
      piAfter = hc.home.activation.piConfig.after;
    }) dc.config.home-manager.users' 2>"$TMP_ROOT/darwin-nix.err") || fail "macOS home.nix evaluates: $(cat "$TMP_ROOT/darwin-nix.err")"
  jq -e 'length > 0 and all(.[]; .clone and (.piAfter | index("linkGeneration")))' <<<"$darwin_facts" >/dev/null ||
    fail "home.nix: macOS clones the marketplace and merges Pi settings: $darwin_facts"
  pass "home.nix provisions the marketplace and Pi settings on Linux and macOS"
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
git -C "$DIR" remote set-url origin "$BAD"
run_clone
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "fetch failure: exit 0, clone kept: $OUT"
assert_contains "$OUT" "cannot fetch" "fetch failure: warns"
git -C "$DIR" remote set-url origin "$URL"
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

DEFAULT_BIN="$TMP_ROOT/default-bin"
mkdir -p "$DEFAULT_BIN"
cat >"$DEFAULT_BIN/git" <<'SH'
#!/usr/bin/env bash
args=("$@")
for arg in "$@"; do
  if [ "$arg" = clone ]; then
    i=$((${#args[@]} - 2))
    printf '%s\n' "${args[i]}" >"$CLONE_URL_LOG"
    args[i]=$LOCAL_MARKETPLACE
    break
  fi
done
exec "$REAL_GIT" "${args[@]}"
SH
chmod +x "$DEFAULT_BIN/git"
OUT=$(env -u IXIA_MARKETPLACE_URL -u IXIA_MARKETPLACE_DIR HOME="$TMP_ROOT/home2" PATH="$DEFAULT_BIN:$PATH" \
  REAL_GIT="$(command -v git)" LOCAL_MARKETPLACE="$URL" CLONE_URL_LOG="$TMP_ROOT/clone-url" bash "$CLONE_SCRIPT" 2>&1)
[ "$(cat "$TMP_ROOT/clone-url")" = git@bitbucket.org:iqxbusiness/ixia-marketplace.git ] || fail "default SSH clone URL: $OUT"
[ -f "$TMP_ROOT/home2/${ENTRY#\~/}/plan-gate/SKILL.md" ] || fail "default clone provides the configured skills path: $OUT"
pass "default SSH URL and clone destination provide the configured Pi skills"

SSH_BIN="$TMP_ROOT/ssh-bin"
mkdir -p "$SSH_BIN"
cat >"$SSH_BIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$SSH_ARGS_LOG"
exec git upload-pack "$SSH_UPSTREAM"
SH
chmod +x "$SSH_BIN/ssh"
cat >"$HOME_DIR/.gitconfig" <<EOF
[includeIf "hasconfig:remote.*.url:git@bitbucket.org:iqxbusiness/**"]
  path = $HOME_DIR/work.gitconfig
EOF
git config --file "$HOME_DIR/work.gitconfig" core.sshCommand "'$SSH_BIN/ssh' -i 'work key' -o IdentitiesOnly=yes -F 'pinned hosts'"
for identity in config env default; do
  DIR="$TMP_ROOT/ssh-$identity"
  identity_env=()
  case $identity in
    env) identity_env=("GIT_SSH_COMMAND='$SSH_BIN/ssh' -i 'owner key'" "PATH=$SSH_BIN:$PATH"); key='owner key' ;;
    config) key='work key' ;;
    default) identity_env=("GIT_CONFIG_GLOBAL=/dev/null" "PATH=$SSH_BIN:$PATH"); key= ;;
  esac
  for operation in clone fetch; do
    : >"$TMP_ROOT/ssh-args"
    OUT=$(env -u GIT_SSH_COMMAND HOME="$HOME_DIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOME_DIR/.gitconfig" \
      GIT_SSH_VARIANT=ssh SSH_ARGS_LOG="$TMP_ROOT/ssh-args" SSH_UPSTREAM="$UP" \
      IXIA_MARKETPLACE_URL=git@bitbucket.org:iqxbusiness/ixia-marketplace.git IXIA_MARKETPLACE_DIR="$DIR" \
      "${identity_env[@]}" bash "$CLONE_SCRIPT" 2>&1)
    [ $? = 0 ] && [ -f "$DIR/plugins/ixia-stratex/skills/plan-gate/SKILL.md" ] || fail "SSH $identity $operation: clone available: $OUT"
    for option in BatchMode=yes ConnectTimeout=15; do
      grep -Fxq "$option" "$TMP_ROOT/ssh-args" || fail "SSH $identity $operation: $option applied: $OUT"
    done
    [ -z "$key" ] || grep -Fxq "$key" "$TMP_ROOT/ssh-args" || fail "SSH $identity $operation: identity preserved: $OUT"
    if [ "$identity" = config ]; then
      grep -Fxq 'pinned hosts' "$TMP_ROOT/ssh-args" || fail "SSH $operation: host-key configuration preserved"
      grep -Fxq IdentitiesOnly=yes "$TMP_ROOT/ssh-args" || fail "SSH $operation: identity selection preserved"
    fi
  done
done
pass "clone and fetch preserve configured or environment SSH identity and apply noninteractive options"

PORTABLE_BIN="$TMP_ROOT/portable-bin"
mkdir -p "$PORTABLE_BIN"
for tool in bash git dirname mkdir mktemp mv rm tail; do ln -s "$(command -v "$tool")" "$PORTABLE_BIN/$tool"; done
DIR="$TMP_ROOT/portable-clone"
for operation in clone fetch; do
  OUT=$(env -u GIT_SSH_COMMAND HOME="$HOME_DIR" PATH="$PORTABLE_BIN" GIT_CONFIG_GLOBAL=/dev/null \
    IXIA_MARKETPLACE_URL="$URL" IXIA_MARKETPLACE_DIR="$DIR" "$PORTABLE_BIN/bash" "$CLONE_SCRIPT" 2>&1)
  [ $? = 0 ] && [ -f "$DIR/plugins/ixia-stratex/skills/plan-gate/SKILL.md" ] || fail "without timeout: $operation succeeds: $OUT"
  assert_not_contains "$OUT" "warning:" "without timeout: $operation needs no warning: $OUT"
done
pass "clone and refresh work without timeout or realpath on PATH"

before=$(git -C "$DIR" rev-parse HEAD)
git -C "$DIR" remote set-url origin git@bitbucket.org:iqxbusiness/ixia-marketplace.git
run_clone PATH="$PORTABLE_BIN" GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_COMMAND=false GIT_SSH_VARIANT=ssh
[ "$RC" = 0 ] && [ "$(git -C "$DIR" rev-parse HEAD)" = "$before" ] || fail "without timeout: rejected SSH fetch exits 0 and keeps clone: $OUT"
assert_contains "$OUT" "warning: cannot fetch" "without timeout: rejected SSH fetch warns"
DIR="$TMP_ROOT/portable-failed/ixia-marketplace"
run_clone PATH="$PORTABLE_BIN" GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_COMMAND=false GIT_SSH_VARIANT=ssh \
  IXIA_MARKETPLACE_URL=git@bitbucket.org:iqxbusiness/ixia-marketplace.git
[ "$RC" = 0 ] && [ ! -e "$DIR" ] && [ "$(find "$TMP_ROOT/portable-failed" -mindepth 1 | wc -l)" = 0 ] ||
  fail "without timeout: rejected SSH clone exits 0 without leftovers: $OUT"
assert_contains "$OUT" "warning: cannot clone" "without timeout: rejected SSH clone warns"
pass "without timeout, missing SSH access only warns and skips clone or refresh"

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
jq -e --arg e "$ENTRY" --arg x "$EXCLUSION" '.skills == [$e, $x] and .theme == "dark" and .hideThinkingBlock == false and .packages == []
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
jq -e --arg e "$ENTRY" --arg x "$EXCLUSION" '. == {skills: [$e, $x]}' "$PD2/settings.json" >/dev/null || fail "absent: created with just skills: $OUT"
pass "an absent settings file is created with just skills"

# The owner's own skills list: kept, in order; the entry appended once; an
# owner's exclusion or explicit inclusion of the same path is respected.
PD3="$TMP_ROOT/workspace3/.pi"
mkdir -p "$PD3"
printf '{"skills": ["~/mine", "+/exact/skill"], "theme": "light"}\n' >"$PD3/settings.json"
run_pi "$PD3"
jq -e --arg e "$ENTRY" --arg x "$EXCLUSION" '.skills == ["~/mine", "+/exact/skill", $e, $x] and .theme == "light"' "$PD3/settings.json" >/dev/null ||
  fail "owner skills: kept in order, entry appended: $(cat "$PD3/settings.json")"
for prefix in - ! +; do
  for target in "$ENTRY" "${EXCLUSION#-}"; do
    jq -n --arg e "$prefix$target" '{skills: [$e]}' >"$PD3/settings.json"
    rm -f "$PD3"/settings.json.pre-dotfiles-*
    run_pi "$PD3"
    jq -e --arg owner "$prefix$target" --arg target "$target" --slurpfile src "$SRC_PI" '
      .skills == ([$owner] + [$src[0].skills[] | select(ltrimstr("-") != $target)])
    ' "$PD3/settings.json" >/dev/null || fail "owner '$prefix$target' respected, other resource added: $OUT"
    state=$(tree_sum "$PD3")
    run_pi "$PD3"
    [ -z "$OUT" ] && [ "$(tree_sum "$PD3")" = "$state" ] || fail "owner '$prefix$target': re-run untouched"
  done
done
jq -n --arg e "$ENTRY" '{skills: [$e]}' >"$PD3/settings.json"
run_pi "$PD3"
jq -e --slurpfile src "$SRC_PI" '.skills == $src[0].skills' "$PD3/settings.json" >/dev/null ||
  fail "existing Ixia inclusion gains the feedback exclusion: $OUT"
state=$(tree_sum "$PD3")
run_pi "$PD3"
[ -z "$OUT" ] && [ "$(tree_sum "$PD3")" = "$state" ] || fail "owner already lists both resources: untouched: $OUT"
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
[ -L "$PD4/settings.json" ] && jq -e --arg e "$ENTRY" --arg x "$EXCLUSION" '.skills == [$e, $x] and .theme == "owner"' "$TMP_ROOT/ownerfiles/pi.json" >/dev/null ||
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

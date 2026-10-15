#!/usr/bin/env bash
# Behavior checks for the Ixia plugin marketplace on Pi (Claude Code's half is
# in tests/claude-config.test.sh): tools/ixia-marketplace.sh, which keeps a real
# shallow clone that Pi loads on demand (`pi --skill <clone>/plugins/ixia-stratex/skills`;
# no Pi setting names it). Needs bash and git. Run: bash tests/ixia-plugins.test.sh
#
# Everything runs in a scratch HOME and clone directory, against a local fake
# marketplace repository (file:// URL, so --depth applies); nothing contacts
# Bitbucket.
#
# Coverage:
# - home.nix runs the clone step in the Linux and macOS profiles;
# - tools/ixia-marketplace.sh: a fresh shallow clone (the agents/ directory the
#   review-panel skill needs sits two levels above the skills), a no-op re-run,
#   fast-forward to new upstream commits (including several in a row, which a
#   shallow clone must still follow), local uncommitted changes and local
#   commits never discarded, a non-git directory left alone, the default SSH
#   URL and destination, configured SSH identity preserved, and offline / no
#   access / no git / no timeout only warning, exit 0, leaving nothing
#   half-cloned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLONE_SCRIPT="$ROOT/tools/ixia-marketplace.sh"
SKILLS_DIR=.local/share/ixia-marketplace/plugins/ixia-stratex/skills
dotfiles_test_tmproot ixia-plugins

GIT=(git -c user.name=dotfiles-test -c user.email=dotfiles-test@example.invalid -c commit.gpgsign=false)

# --- home.nix, as Home Manager evaluates it -------------------------------------

if command -v nix >/dev/null 2>&1; then
  case $(uname -m) in
    aarch64 | arm64) sys=aarch64-linux ;;
    *) sys=x86_64-linux ;;
  esac
  facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#homeConfigurations" --apply '
    hcs: builtins.mapAttrs (_: hc: {
      clone = hc.config.home.activation ? ixiaMarketplace;
    }) (builtins.removeAttrs hcs (builtins.filter (n: builtins.match ".*[@-]'"$sys"'" n == null) (builtins.attrNames hcs)))' \
    2>"$TMP_ROOT/nix.err") || fail "home.nix evaluates: $(cat "$TMP_ROOT/nix.err")"
  [ "$(jq 'length' <<<"$facts")" -ge 2 ] || fail "home.nix: workstation and container configs found for $sys: $facts"
  jq -e 'all(.[]; .clone)' <<<"$facts" >/dev/null ||
    fail "home.nix: both profiles clone the marketplace each switch: $facts"
  darwin_facts=$(nix --extra-experimental-features 'nix-command flakes' eval --json "$ROOT#darwinConfigurations.mac" --apply '
    dc: builtins.mapAttrs (_: hc: {
      clone = hc.home.activation ? ixiaMarketplace;
    }) dc.config.home-manager.users' 2>"$TMP_ROOT/darwin-nix.err") || fail "macOS home.nix evaluates: $(cat "$TMP_ROOT/darwin-nix.err")"
  jq -e 'length > 0 and all(.[]; .clone)' <<<"$darwin_facts" >/dev/null ||
    fail "home.nix: macOS clones the marketplace: $darwin_facts"
  pass "home.nix provisions the marketplace clone on Linux and macOS"
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
[ -f "$TMP_ROOT/home2/$SKILLS_DIR/plan-gate/SKILL.md" ] || fail "default clone provides the skills directory to load on demand: $OUT"
pass "default SSH URL and clone destination provide the skills directory for pi --skill"

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

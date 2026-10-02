#!/usr/bin/env bash
# Behavior checks for activation/identity.sh end to end against scratch HOMEs,
# throwaway keys, a throwaway ssh-agent, and an ssh shim that logs instead of
# connecting. No network, no Nix.
#
# Coverage:
# 1. fresh workstation: guidance only, nothing rendered;
# 2. filled identity file, one key missing and one not loaded: exact
#    ssh-keygen / ssh-add guidance, only .pub files exported (never a private
#    key), the key list and applied revision written, rewrites only on change;
# 3. remote-URL routing: personal, work GitHub org, Bitbucket workspace
#    (including https with a user), legacy aliases, and an unmatched owner
#    that refuses to commit;
# 4. container render from a read-only identity directory, with and without
#    the mount and the agent;
# 5. GIT_CONFIG_GLOBAL and a ~/.gitconfig with identity keys are flagged, and
#    check exits 1 on problems while render exits 0;
# 6. the identity file is parsed, never sourced, and bad values are rejected;
# 7. stale outputs are removed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in git ssh ssh-agent ssh-add ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
dotfiles_test_tmproot identity
S=$ROOT/activation/identity.sh
WS=$TMP_ROOT/ws CT=$TMP_ROOT/ct BIN=$TMP_ROOT/bin
mkdir -p "$WS" "$CT" "$BIN"
cat >"$BIN/ssh" <<'SHIM'
#!/bin/sh
echo "ssh $*" >>"$SSH_LOG"
exit 128
SHIM
chmod +x "$BIN/ssh"
export SSH_LOG=$TMP_ROOT/ssh.log
AGENT_PID=
cleanup() {
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  chmod -R u+w "$TMP_ROOT" 2>/dev/null
  dotfiles_test_cleanup
}
trap cleanup EXIT

SOCK=
# run HOME PROFILE MODE [VAR=value...]: prints the script's stdout+stderr and
# leaves its exit status in RC (call it as `run ... >file`, not in $(...),
# when RC matters).
RC=0
run() {
  local h=$1 p=$2 m=$3; shift 3
  env -i HOME="$h" PATH="$PATH" SSH_AUTH_SOCK="$SOCK" DOTFILES_TEMPLATE="$ROOT/identity.env.example" "$@" bash "$S" "$m" "$p" 2>&1
  RC=$?
}
OUT=$TMP_ROOT/out
runo() { run "$@" >"$OUT"; }

echo "== 1. fresh workstation, no identity file"
runo "$WS" workstation render DOTFILES_REV=abc123
out=$(cat "$OUT")
echo "$out"
assert_contains "$out" "install -D -m 600 $ROOT/identity.env.example ~/.config/dotfiles/identity.env" "guidance names the template copy"
assert_not_contains "$out" "ssh-keygen" "no key guidance before there is an identity file"
[ "$RC" = 0 ] || fail "render never fails the switch"
[ ! -e "$WS/.config/git/identities.gitconfig" ] && [ ! -e "$WS/.ssh" ] || fail "nothing rendered without an identity file"
runo "$WS" workstation check
[ "$RC" = 1 ] || fail "standalone check exits 1 on a problem"
pass "fresh workstation: guidance only, nothing rendered"

echo "== 2. identity file filled, one key missing, one not loaded"
mkdir -p "$WS/.config/dotfiles" "$WS/.ssh"
chmod 700 "$WS/.ssh"
cat >"$WS/.config/dotfiles/identity.env" <<'ENVFILE'
# a comment
IDENTITIES="gh_personal gh_work bb_work"
gh_personal_HOST=github.com
gh_personal_OWNERS="cloud-practitioner"
gh_personal_KEY=~/.ssh/id_ed25519_gh_personal
gh_personal_NAME="Test Personal"
gh_personal_EMAIL="personal@example.invalid"
gh_personal_ALIAS=github.com-personal
gh_work_HOST=github.com
gh_work_OWNERS="work-org"
gh_work_KEY=~/.ssh/id_ed25519_gh_work
gh_work_NAME="Test Work"
gh_work_EMAIL="gh-work@example.invalid"
bb_work_HOST=bitbucket.org
bb_work_OWNERS="iqx-test"
bb_work_KEY=~/.ssh/id_ed25519_bb_work
bb_work_NAME="Test BB"
bb_work_EMAIL="bb-work@example.invalid"
bb_work_ALIAS=bitbucket.org-work
ENVFILE
chmod 600 "$WS/.config/dotfiles/identity.env"
# Throwaway keys for two identities; gh_work's is deliberately missing.
for k in id_ed25519_gh_personal id_ed25519_bb_work; do
  ssh-keygen -q -t ed25519 -N '' -C "throwaway-$k" -f "$WS/.ssh/$k" >/dev/null
done
eval "$(ssh-agent -a "$TMP_ROOT/agent.sock")" >/dev/null
AGENT_PID=$SSH_AGENT_PID SOCK=$TMP_ROOT/agent.sock
SSH_AUTH_SOCK=$SOCK ssh-add -q "$WS/.ssh/id_ed25519_gh_personal" 2>/dev/null
runo "$WS" workstation render DOTFILES_REV=abc123
out=$(cat "$OUT")
echo "$out"
[ "$RC" = 0 ] || fail "render exits 0 with problems"
assert_contains "$out" "ssh-keygen -t ed25519 -C \"gh-work@example.invalid\" -f ~/.ssh/id_ed25519_gh_work" "missing key -> ssh-keygen guidance"
assert_contains "$out" "https://github.com/settings/ssh/new" "missing key -> where to register the public key"
assert_contains "$out" "bb_work: key not loaded in the agent: ssh-add ~/.ssh/id_ed25519_bb_work" "unloaded key -> ssh-add guidance"
assert_not_contains "$out" "gh_personal:" "loaded key raises nothing"
assert_contains "$out" "2 problem(s) above" "two problems counted"
assert_contains "$out" "check workstation" "names the standalone check"
D=$WS/.config/dotfiles
echo "--- rendered ~/.config/git/identities.gitconfig (head)"; head -8 "$WS/.config/git/identities.gitconfig"
echo "--- rendered identity/gh_personal.gitconfig"; cat "$WS/.config/git/identity/gh_personal.gitconfig"
echo "--- rendered ~/.ssh/config.d/identities"; cat "$WS/.ssh/config.d/identities"
ls -l "$D/pub"
! grep -rq PRIVATE "$D/pub" "$D/ssh-keys" "$D/applied-rev" "$WS/.config/git" "$WS/.ssh/config.d" || fail "a private key leaked into an output"
[ "$(ls "$D/pub")" = "$(printf 'bb_work.pub\ngh_personal.pub')" ] || fail "only the existing keys' public halves are exported"
for l in gh_personal bb_work; do
  cmp "$D/pub/$l.pub" "$WS/.ssh/id_ed25519_$l.pub" || fail "$l.pub is the public half"
done
[ "$(cat "$D/applied-rev")" = abc123 ] || fail "applied revision recorded"
[ "$(cat "$D/ssh-keys")" = "$(printf '%s\n' "$WS/.ssh/id_ed25519_gh_personal" "$WS/.ssh/id_ed25519_gh_work" "$WS/.ssh/id_ed25519_bb_work")" ] \
  || fail "key list for the zsh agent autoload"
grep -q "IdentityFile $WS/.ssh/id_ed25519_gh_personal" "$WS/.ssh/config.d/identities" || fail "alias uses the private key path"
[ "$(stat -c %a "$WS/.ssh/config.d/identities")" = 600 ] || fail "ssh include is mode 600"
# Rewritten only when the content changes.
stamp() { stat -c '%i %Y' "$WS/.config/git/identities.gitconfig" "$WS/.config/git/identity/"*.gitconfig "$WS/.ssh/config.d/identities" "$D/ssh-keys" "$D/applied-rev" "$D/pub/"*; }
before=$(stamp)
sleep 1
runo "$WS" workstation render DOTFILES_REV=abc123
[ "$before" = "$(stamp)" ] || fail "an unchanged render rewrites nothing"
pass "workstation render: rules, per-identity files, aliases, key list, revision, public halves only"

# Minimal Home Manager-like global config: the XDG file includes the rendered rules last.
gitcfg() { # home
  mkdir -p "$1/.config/git"
  printf '[user]\n\tuseConfigOnly = true\n[include]\n\tpath = ~/.config/git/identities.gitconfig\n' >"$1/.config/git/config"
}
gitrun() { # home args...
  local h=$1; shift
  env -i HOME="$h" XDG_CONFIG_HOME="$h/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$BIN:$PATH" SSH_LOG="$SSH_LOG" git "$@"
}
# route HOME URL: sets EMAIL (what a commit in a repo with that remote uses)
# and SSH (the ssh command line git runs to reach it; empty for https).
route() {
  local h=$1 url=$2 d=$TMP_ROOT/probe.$RANDOM
  gitrun "$h" init -q "$d" && gitrun "$h" -C "$d" remote add origin "$url"
  EMAIL=$(gitrun "$h" -C "$d" config user.email || echo NONE) SSH=
  case "$url" in
    https://*) ;;
    *) : >"$SSH_LOG"; gitrun "$h" clone -q "$url" "$d.clone" >/dev/null 2>&1; SSH=$(head -n1 "$SSH_LOG") ;;
  esac
  printf '%-52s email=%-26s %s\n' "$url" "$EMAIL" "${SSH%% -o SendEnv*}"
  rm -rf "$d" "$d.clone"
}
expect_route() { # home url email key-path-or-empty
  route "$1" "$2"
  [ "$EMAIL" = "$3" ] || fail "$2 -> email $3 (got $EMAIL)"
  [ -z "$4" ] || assert_contains "$SSH" "-i $4 -o IdentitiesOnly=yes" "$2 -> ssh uses $4"
}
echo "== 3. workstation routing (git $(git --version | awk '{print $3}'))"
gitcfg "$WS"
K=$WS/.ssh
expect_route "$WS" git@github.com:cloud-practitioner/x.git personal@example.invalid "$K/id_ed25519_gh_personal"
expect_route "$WS" ssh://git@github.com/cloud-practitioner/x.git personal@example.invalid "$K/id_ed25519_gh_personal"
expect_route "$WS" https://github.com/cloud-practitioner/x.git personal@example.invalid ""
expect_route "$WS" git@github.com-personal:cloud-practitioner/x.git personal@example.invalid "$K/id_ed25519_gh_personal"
expect_route "$WS" git@github.com:work-org/y.git gh-work@example.invalid "$K/id_ed25519_gh_work"
expect_route "$WS" https://someone@github.com/work-org/y.git gh-work@example.invalid ""
expect_route "$WS" git@bitbucket.org:iqx-test/z.git bb-work@example.invalid "$K/id_ed25519_bb_work"
expect_route "$WS" https://someone@bitbucket.org/iqx-test/z.git bb-work@example.invalid ""
expect_route "$WS" git@bitbucket.org-work:iqx-test/z.git bb-work@example.invalid "$K/id_ed25519_bb_work"
# An unmatched owner gets no identity, and useConfigOnly refuses the commit.
route "$WS" git@github.com:stranger/w.git
[ "$EMAIL" = NONE ] || fail "an unmatched owner gets no identity"
d=$TMP_ROOT/stranger
gitrun "$WS" init -q "$d" && gitrun "$WS" -C "$d" remote add origin git@github.com:stranger/w.git
if out=$(gitrun "$WS" -C "$d" commit -q --allow-empty -m x 2>&1); then fail "an unmatched owner must refuse the commit"; fi
assert_contains "$out" "Author identity unknown" "git refuses with no identity to guess"
# The same owner name on another host does not match.
expect_route "$WS" git@gitlab.com:work-org/y.git NONE ""
pass "routing: personal, work org, Bitbucket workspace, legacy alias; unmatched owner refuses commit"

echo "== 4. container: identity dir mounted read-only, no ~/.ssh mount"
chmod -R a-w "$WS/.config/dotfiles"
runo "$CT" container render DOTFILES_IDENTITY_DIR="$WS/.config/dotfiles"
out=$(cat "$OUT")
echo "$out"
[ "$RC" = 0 ] || fail "container render exits 0"
assert_contains "$out" "gh_work: the workstation exported no public key" "container names the missing key"
assert_not_contains "$out" "cannot write" "a read-only identity directory is never written"
assert_not_contains "$out" "gh_personal:" "container: the forwarded agent holds gh_personal"
grep -q "sshCommand = ssh -i \"$WS/.config/dotfiles/pub/gh_personal.pub\" -o IdentitiesOnly=yes" "$CT/.config/git/identity/gh_personal.gitconfig" \
  || fail "container selects the agent key by its public half"
grep -q "IdentityFile $WS/.config/dotfiles/pub/bb_work.pub" "$CT/.ssh/config.d/identities" || fail "container alias uses the public half"
[ ! -e "$CT/.config/dotfiles" ] || fail "container render writes nothing under its own identity directory"
gitcfg "$CT"
expect_route "$CT" git@github.com:cloud-practitioner/x.git personal@example.invalid "$WS/.config/dotfiles/pub/gh_personal.pub"
expect_route "$CT" git@bitbucket.org:iqx-test/z.git bb-work@example.invalid "$WS/.config/dotfiles/pub/bb_work.pub"
chmod -R u+w "$WS/.config/dotfiles"
runo "$CT" container check DOTFILES_IDENTITY_DIR="$TMP_ROOT/not-mounted"
out=$(cat "$OUT")
assert_contains "$out" "identity directory is not mounted here" "container says plainly the identity file is not mounted"
assert_contains "$out" "install -D -m 600 ~/.dotfiles/identity.env.example" "container points at the workstation setup"
SOCK_KEEP=$SOCK SOCK=$TMP_ROOT/dead.sock
runo "$CT" container check DOTFILES_IDENTITY_DIR="$WS/.config/dotfiles"
SOCK=$SOCK_KEEP
out=$(cat "$OUT")
assert_contains "$out" "no ssh-agent at SSH_AUTH_SOCK=$TMP_ROOT/dead.sock" "container names a missing forwarded agent"
pass "container render: public halves only, from the read-only identity dir"

echo "== 5. GIT_CONFIG_GLOBAL and ~/.gitconfig mask the identities"
runo "$CT" container check DOTFILES_IDENTITY_DIR="$WS/.config/dotfiles" GIT_CONFIG_GLOBAL=/home/node/.gitconfig-container
out=$(cat "$OUT")
assert_contains "$out" "GIT_CONFIG_GLOBAL=/home/node/.gitconfig-container" "warns about GIT_CONFIG_GLOBAL"
[ "$RC" = 1 ] || fail "check exits 1 on problems"
printf '[user]\n\temail = old@example.invalid\n' >"$WS/.gitconfig"
runo "$WS" workstation check
out=$(cat "$OUT")
assert_contains "$out" "~/.gitconfig sets user/includeIf/url keys" "warns about an overriding ~/.gitconfig"
rm "$WS/.gitconfig"
pass "check flags GIT_CONFIG_GLOBAL and ~/.gitconfig"

echo "== 6. strict parsing: never sourced, bad values rejected"
BAD=$TMP_ROOT/bad
mkdir -p "$BAD/.config/dotfiles"
cat >"$BAD/.config/dotfiles/identity.env" <<ENVFILE
IDENTITIES="evil ok"
evil_HOST=github.com
evil_OWNERS="x"
evil_KEY="~/.ssh/k; touch $TMP_ROOT/pwned"
evil_NAME="Ev\\il"
evil_EMAIL="e@example.invalid"
ok_HOST=github.com
ok_OWNERS="fine"
ok_KEY=~/.ssh/ok
ok_NAME="\$(touch $TMP_ROOT/pwned)"
ok_EMAIL="ok@example.invalid"
ENVFILE
chmod 600 "$BAD/.config/dotfiles/identity.env"
runo "$BAD" workstation render
out=$(cat "$OUT")
echo "$out"
[ ! -e "$TMP_ROOT/pwned" ] || fail "the identity file was executed"
assert_contains "$out" "evil_KEY has an invalid value" "shell metacharacters in _KEY rejected"
assert_contains "$out" "evil_NAME has an invalid value" "backslash in _NAME rejected"
[ ! -e "$BAD/.config/git/identity/evil.gitconfig" ] || fail "an invalid identity renders nothing"
grep -qF 'name = $(touch' "$BAD/.config/git/identity/ok.gitconfig" || fail "command substitution stays literal text"
printf 'IDENTITIES="a"\nthis is not a setting\n' >"$BAD/.config/dotfiles/identity.env"
runo "$BAD" workstation check
out=$(cat "$OUT")
assert_contains "$out" "identity.env:2 is not a KEY=value line" "a non-KEY=value line is an error"
pass "identity file parsed strictly"

echo "== 7. stale outputs removed"
sed -i 's/^IDENTITIES=.*/IDENTITIES="gh_personal"/' "$WS/.config/dotfiles/identity.env"
runo "$WS" workstation render
if [ -e "$WS/.config/git/identity/gh_work.gitconfig" ] || [ -e "$WS/.config/git/identity/bb_work.gitconfig" ] \
  || [ -e "$WS/.config/dotfiles/pub/bb_work.pub" ]; then fail "a removed identity leaves its files behind"; fi
[ -e "$WS/.config/git/identity/gh_personal.gitconfig" ] || fail "remaining identity kept"
if grep -q bitbucket "$WS/.config/git/identities.gitconfig" "$WS/.ssh/config.d/identities"; then fail "removed identity's rules and aliases are gone"; fi
[ "$(cat "$WS/.config/dotfiles/ssh-keys")" = "$WS/.ssh/id_ed25519_gh_personal" ] || fail "key list follows the identities"
rm "$WS/.config/dotfiles/identity.env"
runo "$WS" workstation render
if [ -e "$WS/.config/git/identities.gitconfig" ] || [ -e "$WS/.config/git/identity" ] || [ -e "$WS/.ssh/config.d/identities" ] \
  || [ -e "$WS/.config/dotfiles/pub" ] || [ -e "$WS/.config/dotfiles/ssh-keys" ]; then fail "stale files left"; fi
pass "no stale identities after an identity or the identity file goes"

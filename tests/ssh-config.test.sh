#!/usr/bin/env bash
# Behavior checks for the SSH client config and global git config home.nix
# generates (programs.ssh, programs.git).
#
# Builds each Linux home profile for this machine's system into the Nix store
# (never activating it) and reads the generated files.
#
# Coverage:
# - neither profile evaluates with a Home Manager warning;
# - workstation: ~/.ssh/config is the include of the rendered
#   ~/.ssh/config.d/identities plus the `*` defaults this repo has always
#   shipped, and no personal host alias or key path is hard-coded;
# - workstation: with an identity file rendered by activation/identity.sh in a
#   scratch HOME, `ssh -G` resolves a legacy alias to its real host, user git,
#   only its own key, and keys added to the agent;
# - both profiles: the global git config sets useConfigOnly, pushes over SSH
#   for github.com and bitbucket.org, includes the rendered identity rules
#   last, and has no folder (gitdir:) rules, insteadOf, or gpg section;
# - container: no ~/.ssh/config is generated.
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in nix ssh; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
dotfiles_test_tmproot ssh-config

SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
WS="dev@$SYSTEM"
CT="node@container-$SYSTEM"

home_files() {
  nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$1\".config.home-files" \
    || fail "$1: home-files build failed"
}

for profile in "$WS" "$CT"; do
  warnings=$(nix eval --json "$ROOT#homeConfigurations.\"$profile\".config.warnings") \
    || fail "$profile: evaluating warnings failed"
  [ "$warnings" = "[]" ] || fail "$profile: evaluates without warnings, got: $warnings"
  pass "$profile: evaluates without Home Manager warnings"
done

ws_files=$(home_files "$WS")
config="$ws_files/.ssh/config"
[ -e "$config" ] || fail "$WS: ~/.ssh/config is generated"

expected=$(cat <<'EOT'
Include ~/.ssh/config.d/identities

Host *
  AddKeysToAgent yes
  Compression no
  ControlMaster no
  ControlPath ~/.ssh/master-%r@%n:%p
  ControlPersist no
  ForwardAgent no
  HashKnownHosts no
  ServerAliveCountMax 3
  ServerAliveInterval 0
  UserKnownHostsFile ~/.ssh/known_hosts
EOT
)
actual=$(cat "$config")
[ "$actual" = "$expected" ] || fail "$WS: ~/.ssh/config matches, got:
$actual"
assert_not_contains "$actual" id_ed25519 "$WS: no key path is hard-coded"
pass "$WS: ~/.ssh/config is the identities include plus the * defaults"

# A legacy alias, rendered the way activation does. ssh expands `~` from the
# passwd entry, not $HOME, so point the include at the scratch HOME.
H="$TMP_ROOT/home"
mkdir -p "$H/.config/dotfiles" "$H/.ssh"
cat >"$H/.config/dotfiles/identity.env" <<'EOT'
IDENTITIES="gh_work"
gh_work_HOST=github.com
gh_work_OWNERS="work-org"
gh_work_KEY=~/.ssh/id_ed25519_gh_work
gh_work_NAME="Test Work"
gh_work_EMAIL="work@example.invalid"
gh_work_ALIAS=github.com-work
EOT
chmod 600 "$H/.config/dotfiles/identity.env"
env -i HOME="$H" PATH="$PATH" bash "$ROOT/activation/identity.sh" render workstation >/dev/null 2>&1
[ -f "$H/.ssh/config.d/identities" ] || fail "identity render wrote ~/.ssh/config.d/identities"
sed "s|~/.ssh/config.d/identities|$H/.ssh/config.d/identities|" "$config" >"$H/ssh_config"

resolved=$(ssh -G -F "$H/ssh_config" github.com-work 2>&1) || fail "$WS: ssh -G github.com-work failed: $resolved"
assert_contains "$resolved" $'\n'"hostname github.com"$'\n' "$WS: github.com-work resolves to github.com"
assert_contains "$resolved" $'\n'"user git"$'\n' "$WS: github.com-work logs in as git"
assert_contains "$resolved" $'\n'"identitiesonly yes"$'\n' "$WS: github.com-work offers only its own key"
assert_contains "$resolved" "$H/.ssh/id_ed25519_gh_work"$'\n' "$WS: github.com-work uses its key"
[ "$(printf '%s\n' "$resolved" | grep -c '^identityfile ')" = 1 ] \
  || fail "$WS: github.com-work has exactly one identity file"
assert_contains "$resolved" $'\n'"addkeystoagent true"$'\n' "$WS: github.com-work adds keys to the agent"
pass "$WS: a rendered legacy alias resolves to git@github.com with only its own key"

for profile in "$WS" "$CT"; do
  files=$(home_files "$profile")
  gitcfg=$(cat "$files/.config/git/config") || fail "$profile: ~/.config/git/config is generated"
  assert_contains "$gitcfg" $'useConfigOnly = true' "$profile: git refuses to guess an identity"
  assert_contains "$gitcfg" $'[url "git@github.com:"]\n\tpushInsteadOf = "https://github.com/"' "$profile: github.com pushes over SSH"
  assert_contains "$gitcfg" $'[url "git@bitbucket.org:"]\n\tpushInsteadOf = "https://bitbucket.org/"' "$profile: bitbucket.org pushes over SSH"
  assert_contains "$gitcfg" $'[include]\n\tpath = "~/.config/git/identities.gitconfig"' "$profile: includes the rendered identity rules"
  assert_not_contains "$gitcfg" 'gitdir' "$profile: no folder rules"
  assert_not_contains "$gitcfg" 'insteadOf = ' "$profile: no clone rewrites"
  assert_not_contains "$gitcfg" 'gpg' "$profile: no gpg section"
  [ "$(grep -n '^\[include\]' <<<"$gitcfg" | cut -d: -f1)" -gt "$(grep -n '^\[user\]' <<<"$gitcfg" | cut -d: -f1)" ] \
    || fail "$profile: the identity include comes after the plain settings"
  pass "$profile: global git config"
done

ct_files=$(home_files "$CT")
[ ! -e "$ct_files/.ssh/config" ] || fail "$CT: no ~/.ssh/config is generated"
pass "$CT: no ~/.ssh/config is generated"

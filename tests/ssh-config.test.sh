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

for tool in nix ssh git; do
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

ssh_value() {
  awk -v key="$1" '$1 == key {sub(/^[^ ]+ /, ""); print}' <<<"${2:-$resolved}"
}

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
[ "$(ssh_value hostname)" = github.com ] || fail "$WS: github.com-work resolves to github.com"
[ "$(ssh_value user)" = git ] || fail "$WS: github.com-work logs in as git"
[ "$(ssh_value identitiesonly)" = yes ] || fail "$WS: github.com-work offers only its own key"
[ "$(ssh_value identityfile)" = "$H/.ssh/id_ed25519_gh_work" ] || fail "$WS: github.com-work uses exactly its own key"
cat >"$H/defaults" <<'EOT'
Host github.com-work
  HostName github.com
  User git
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
defaults=$(ssh -G -F "$H/defaults" github.com-work 2>/dev/null) || fail "SSH consumes default settings fixture"
for key in addkeystoagent compression controlmaster controlpath controlpersist forwardagent hashknownhosts serveralivecountmax serveraliveinterval userknownhostsfile; do
  [ "$(ssh_value "$key")" = "$(ssh_value "$key" "$defaults")" ] || fail "$WS: $key retains its default setting"
done
pass "$WS: a rendered legacy alias resolves to git@github.com with only its own key"

for profile in "$WS" "$CT"; do
  files=$(home_files "$profile")
  gitcfg=$files/.config/git/config
  [ -f "$gitcfg" ] || fail "$profile: ~/.config/git/config is generated"
  [ "$(git config --file "$gitcfg" --bool user.useConfigOnly)" = true ] || fail "$profile: git refuses to guess an identity"
  [ "$(git config --file "$gitcfg" --get-all url.git@github.com:.pushInsteadOf)" = https://github.com/ ] || fail "$profile: github.com push rewrite"
  [ "$(git config --file "$gitcfg" --get-all url.git@bitbucket.org:.pushInsteadOf)" = https://bitbucket.org/ ] || fail "$profile: bitbucket.org push rewrite"
  [ "$(git config --file "$gitcfg" --get-all include.path)" = '~/.config/git/identities.gitconfig' ] || fail "$profile: includes the rendered identities"
  if git config --file "$gitcfg" --get-regexp '^(includeif\.|url\..*\.insteadof$|gpg\.)' >/dev/null; then
    fail "$profile: no conditional global rules, clone rewrites or signing settings"
  fi
  mkdir -p "$H/.config/git"
  install -m 600 "$gitcfg" "$H/.config/git/config" || fail "$profile: global config fixture installed"
  repo=$TMP_ROOT/git-probe
  rm -rf "$repo"
  git_home() { env -i HOME="$H" XDG_CONFIG_HOME="$H/.config" GIT_CONFIG_NOSYSTEM=1 PATH="$PATH" git "$@"; }
  git_home init -q "$repo" || fail "$profile: fixture repository initialized"
  git_home -C "$repo" remote add origin https://github.com/work-org/repo.git
  [ "$(git_home -C "$repo" config user.email)" = work@example.invalid ] || fail "$profile: rendered identity is consumed"
  [ "$(git_home -C "$repo" remote get-url origin)" = https://github.com/work-org/repo.git ] || fail "$profile: fetch URL stays HTTPS"
  [ "$(git_home -C "$repo" remote get-url --push origin)" = git@github.com:work-org/repo.git ] || fail "$profile: Git pushes to GitHub over SSH"
  git_home -C "$repo" remote set-url origin https://bitbucket.org/other/repo.git
  [ "$(git_home -C "$repo" remote get-url origin)" = https://bitbucket.org/other/repo.git ] || fail "$profile: Bitbucket fetch URL stays HTTPS"
  [ "$(git_home -C "$repo" remote get-url --push origin)" = git@bitbucket.org:other/repo.git ] || fail "$profile: Git pushes to Bitbucket over SSH"
  if git_home -C "$repo" commit -q --allow-empty -m unmatched >/dev/null 2>&1; then
    fail "$profile: unmatched owner must refuse the commit"
  fi
  pass "$profile: global git config"
done

ct_files=$(home_files "$CT")
[ ! -e "$ct_files/.ssh/config" ] || fail "$CT: no ~/.ssh/config is generated"
pass "$CT: no ~/.ssh/config is generated"

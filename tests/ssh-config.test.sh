#!/usr/bin/env bash
# Behavior checks for the SSH client config home.nix generates
# (programs.ssh.settings).
#
# Builds each Linux home profile for this machine's system into the Nix store
# (never activating it) and reads the generated ~/.ssh/config.
#
# Coverage:
# - workstation: ~/.ssh/config is exactly the three host aliases plus the `*`
#   defaults this repo has always shipped (same text as the old matchBlocks
#   config with Home Manager's legacy defaults);
# - workstation: `ssh -G` resolves each alias to its real host, user git, only
#   its own key, and keys added to the agent;
# - container: no ~/.ssh/config is generated;
# - neither profile evaluates with a Home Manager warning (such as the
#   `programs.ssh.matchBlocks` or default-values deprecations).
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in nix ssh; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

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

expected=$(cat <<'EOF'
Host bitbucket.org-work
  HostName bitbucket.org
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519_bb_work
  User git

Host github.com-personal
  HostName github.com
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519_gh_personal
  User git

Host github.com-work
  HostName github.com
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519_gh_work
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
EOF
)
actual=$(cat "$config")
[ "$actual" = "$expected" ] || fail "$WS: ~/.ssh/config matches, got:
$actual"
pass "$WS: ~/.ssh/config has the three aliases and the * defaults"

# Effective options per alias, as OpenSSH itself resolves them from this file
# alone (-F skips the system-wide ssh_config).
check_alias() {
  local alias=$1 host=$2 key=$3 resolved
  resolved=$(ssh -G -F "$config" "$alias" 2>&1) || fail "$WS: ssh -G $alias failed: $resolved"
  assert_contains "$resolved" $'\n'"hostname $host"$'\n' "$WS: $alias resolves to $host"
  assert_contains "$resolved" $'\n'"user git"$'\n' "$WS: $alias logs in as git"
  assert_contains "$resolved" $'\n'"identitiesonly yes"$'\n' "$WS: $alias offers only its own key"
  assert_contains "$resolved" "/.ssh/$key"$'\n' "$WS: $alias uses ~/.ssh/$key"
  [ "$(printf '%s\n' "$resolved" | grep -c '^identityfile ')" = 1 ] \
    || fail "$WS: $alias has exactly one identity file"
  assert_contains "$resolved" $'\n'"addkeystoagent true"$'\n' "$WS: $alias adds keys to the agent"
  pass "$WS: $alias resolves to git@$host with only ~/.ssh/$key"
}
check_alias github.com-personal github.com id_ed25519_gh_personal
check_alias github.com-work github.com id_ed25519_gh_work
check_alias bitbucket.org-work bitbucket.org id_ed25519_bb_work

ct_files=$(home_files "$CT")
[ ! -e "$ct_files/.ssh/config" ] || fail "$CT: no ~/.ssh/config is generated"
pass "$CT: no ~/.ssh/config is generated"

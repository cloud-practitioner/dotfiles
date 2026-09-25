#!/usr/bin/env bash
# Checks that the zsh ssh-agent key autoload block is rendered only into the
# WSL2 workstation profile, never into a devcontainer profile. Evaluates the
# flake's Home Manager configs; needs no running agent or real keys.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

system="$(uname -m)-linux"

init_content() {
  nix eval --raw "$ROOT#homeConfigurations.\"$1\".config.programs.zsh.initContent" 2>/dev/null
}

ws=$(init_content "dev@$system") || fail "evaluate workstation initContent"
ct=$(init_content "dev@container-$system") || fail "evaluate container initContent"

for needle in 'ssh-add -l >/dev/null 2>&1' '~/.ssh/id_ed25519_gh_work' \
  '~/.ssh/id_ed25519_gh_personal' '~/.ssh/id_ed25519_bb_work'; do
  printf '%s' "$ws" | grep -Fq -- "$needle" || fail "workstation zshrc contains: $needle"
done
pass "workstation zshrc loads ssh keys into an empty agent"

printf '%s' "$ct" | grep -Fq 'ssh-add' && fail "container zshrc has no ssh-add"
pass "container zshrc has no ssh-add"

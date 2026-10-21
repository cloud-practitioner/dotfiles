#!/usr/bin/env bash
# Behavior checks that both Linux home profiles provision AWS CLI v2 through
# Home Manager.
#
# Coverage:
# - the workstation and container profiles for this machine's system list
#   awscli2 in home.packages, and it is major version 2;
# - the built profiles ship an `aws` binary in home-path, which is what lands
#   on PATH for interactive and non-interactive shells alike.
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-linux ;;
  aarch64|arm64) SYSTEM=aarch64-linux ;;
  *) SYSTEM= ;;
esac

# Echo the two Linux home configs for $SYSTEM: the workstation one and a container one.
profiles() {
  local configs
  configs=$(nix eval --json "$ROOT#homeConfigurations" --apply builtins.attrNames) || return 1
  jq -er --arg s "$SYSTEM" '
    [
      (map(select(endswith("@" + $s))) | first),
      (map(select(endswith("@container-" + $s))) | first)
    ]
    | select(all(.[]; type == "string" and length > 0))
    | .[]' <<<"$configs"
}

have_linux_nix() {
  if [ "$(uname -s)" != Linux ] || [ -z "$SYSTEM" ] || ! command -v nix >/dev/null 2>&1; then
    echo "skip: needs Nix on x86_64/aarch64 Linux"
    return 1
  fi
}

test_profiles_install_awscli2() {
  local profile versions
  for profile in $PROFILE_NAMES; do
    versions=$(nix eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.packages" \
      --apply 'ps: map (p: p.version) (builtins.filter (p: (p.pname or "") == "awscli2") ps)' 2>/dev/null) \
      || fail "$profile: cannot evaluate home.packages"
    [ "$(jq 'length' <<<"$versions")" = 1 ] || fail "$profile: does not install exactly one awscli2: $versions"
    [ "$(jq -r '.[0] | split(".") | .[0]' <<<"$versions")" = 2 ] || fail "$profile: awscli2 is not AWS CLI v2: $versions"
  done
  pass "workstation and container profiles install AWS CLI v2 (awscli2)"
}

test_built_profiles_ship_aws() {
  local profile out
  for profile in $PROFILE_NAMES; do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    [ -x "$out/home-path/bin/aws" ] || fail "$profile: the home profile ships no aws binary"
  done
  pass "built workstation and container profiles ship an aws binary"
}

if have_linux_nix; then
  PROFILE_NAMES=$(profiles) || fail "cannot discover workstation and container profiles"
  test_profiles_install_awscli2
  test_built_profiles_ship_aws
fi

#!/usr/bin/env bash
# Behavior checks that both Linux home profiles provision AWS CLI v2 through
# Home Manager and nothing else of AWS's.
#
# Coverage:
# - the workstation and container profiles for this machine's system list
#   awscli2 in home.packages, and it is major version 2;
# - the built profiles ship an `aws` binary in home-path, which is what lands
#   on PATH for interactive and non-interactive shells alike;
# - the install scripts and home.nix manage no ~/.aws files or AWS credential
#   environment variables.
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
  nix eval --json "$ROOT#homeConfigurations" --apply builtins.attrNames 2>/dev/null \
    | jq -r --arg s "$SYSTEM" '
        (map(select(endswith("@" + $s))) | first),
        (map(select(endswith("@container-" + $s))) | first)'
}

have_linux_nix() {
  if [ "$(uname -s)" != Linux ] || [ -z "$SYSTEM" ] || ! command -v nix >/dev/null 2>&1; then
    echo "skip: needs Nix on x86_64/aarch64 Linux"
    return 1
  fi
}

test_profiles_install_awscli2() {
  local profile versions
  have_linux_nix || return 0
  for profile in $(profiles); do
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
  have_linux_nix || return 0
  for profile in $(profiles); do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    [ -x "$out/home-path/bin/aws" ] || fail "$profile: the home profile ships no aws binary"
  done
  pass "built workstation and container profiles ship an aws binary"
}

test_no_aws_configuration_managed() {
  local f
  for f in "$ROOT/home.nix" "$ROOT"/tools/*.sh "$ROOT"/activation/*.sh; do
    if grep -nE '\.aws|AWS_[A-Z_]*(KEY|TOKEN|PROFILE|CONFIG)' "$f" >/dev/null; then
      fail "$f manages AWS configuration or credentials; the AWS CLI is install-only"
    fi
  done
  pass "no dotfiles script or Nix module manages ~/.aws or AWS credential variables"
}

test_profiles_install_awscli2
test_built_profiles_ship_aws
test_no_aws_configuration_managed

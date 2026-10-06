#!/usr/bin/env bash
# Behavior checks that the Linux home profiles leave the upstream CLI tools to
# their vendors' installers: Home Manager installs herdr, Claude Code, Pi, the
# GitHub Copilot CLI, and Antigravity unpinned at switch time
# (tests/node-tools.test.sh covers that), so no profile may ship a Nix-built
# copy that could shadow them.
#
# Coverage:
# - both Linux home profiles (workstation and container) for this machine's
#   system list no herdr, Claude Code, Pi, Copilot CLI, or Antigravity package;
# - the built profiles' home-path has no herdr, claude, pi, copilot, or agy binary,
#   so a switch removes the Nix-built herdr that an older switch installed.
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

test_profiles_install_no_nix_builds() {
  local profile packages
  have_linux_nix || return 0
  for profile in $(profiles); do
    packages=$(nix eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.packages" \
      --apply 'map (p: p.pname or p.name)' 2>/dev/null) || fail "$profile: cannot evaluate home.packages"
    [ "$(jq '[.[] | select(test("^(herdr|pi|pi-coding-agent|claude-code|github-copilot-cli|antigravity|google-antigravity|antigravity-cli)$"))] | length' <<<"$packages")" = 0 ] \
      || fail "$profile: still installs a Nix-built herdr, Claude Code, Pi, Copilot CLI, or Antigravity: $packages"
  done
  pass "workstation and container profiles install no Nix-built herdr, Claude Code, Pi, Copilot CLI, or Antigravity"
}

test_built_profiles_ship_no_nix_builds() {
  local profile out tool
  have_linux_nix || return 0
  for profile in $(profiles); do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    for tool in herdr claude pi copilot agy; do
      [ ! -e "$out/home-path/bin/$tool" ] || fail "$profile: the home profile still ships a Nix-built $tool"
    done
  done
  pass "built workstation and container profiles ship no herdr, claude, pi, copilot, or agy binary"
}

test_profiles_install_no_nix_builds
test_built_profiles_ship_no_nix_builds

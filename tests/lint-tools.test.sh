#!/usr/bin/env bash
# Behavior checks that both Linux home profiles (WSL2 workstation and
# devcontainer) provision the lint tools and the no-mistakes skill
# through Home Manager, so a rebuild needs no manual reinstall.
#
# Coverage:
# - both profiles for this machine's system list shellcheck and actionlint in
#   home.packages;
# - the built profiles ship runnable shellcheck and actionlint binaries in
#   home-path, which is what lands on PATH for interactive and non-interactive
#   shells alike;
# - both built activation scripts run tools/node-tools.sh, whose agent skills
#   step installs the no-mistakes skill into ~/.agents/skills at the release
#   tag of the installed no-mistakes CLI (tests/node-tools.test.sh runs that
#   step against fakes: install, version-following refresh, idempotence, and
#   failure reporting).
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

test_profiles_install_lint_tools() {
  local profile tool names
  for profile in $PROFILE_NAMES; do
    for tool in shellcheck actionlint; do
      names=$(nix eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.packages" \
        --apply "ps: map (p: p.name) (builtins.filter (p: builtins.match \"$tool-[0-9].*\" (p.name or \"\") != null) ps)" 2>/dev/null) \
        || fail "$profile: cannot evaluate home.packages"
      [ "$(jq 'length' <<<"$names")" = 1 ] || fail "$profile: does not install exactly one $tool: $names"
    done
  done
  pass "workstation and container profiles install shellcheck and actionlint from nixpkgs"
}

test_built_profiles_ship_lint_tools_and_skill_step() {
  local profile out tool
  # shellcheck disable=SC2016 # a literal $version in the script, not an expansion
  grep -q 'NO_MISTAKES_SKILL_REPO/tree/\$version/skills/no-mistakes' "$ROOT/tools/node-tools.sh" \
    || fail "tools/node-tools.sh does not install the no-mistakes skill from the installed CLI's release tag"
  for profile in $PROFILE_NAMES; do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    for tool in shellcheck actionlint; do
      [ -x "$out/home-path/bin/$tool" ] || fail "$profile: the home profile ships no $tool binary"
      "$out/home-path/bin/$tool" --version >/dev/null 2>&1 </dev/null || fail "$profile: $tool --version fails"
    done
    grep -q 'node-tools.sh' "$out/activate" || fail "$profile: the activation script does not run node-tools.sh"
  done
  pass "built workstation and container profiles ship runnable shellcheck and actionlint and run the node-tools step that installs the no-mistakes skill of the CLI's version"
}

if have_linux_nix; then
  PROFILE_NAMES=$(profiles) || fail "cannot discover workstation and container profiles"
  test_profiles_install_lint_tools
  test_built_profiles_ship_lint_tools_and_skill_step
fi

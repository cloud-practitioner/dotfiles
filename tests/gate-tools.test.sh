#!/usr/bin/env bash
# Check the Linux home profiles for the PR evidence tools.
# Check that Nix gh does not hide the container image's gh on PATH.
#
# The gate uploads images with `gh pr create --attach`.
# This command needs gh 2.99 or newer.
# The gate uses ImageMagick (magick, convert) to make the images.
#
# Coverage:
# - the container profile installs no gh;
# - the workstation profile installs exactly one gh;
# - both profiles declare exactly one ImageMagick in home.packages;
# - both built profiles provide runnable magick and convert;
# - the built workstation profile provides a runnable gh.
#
# Nix evaluates the flake from Git. Track new files with `git add`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-linux ;;
  aarch64|arm64) SYSTEM=aarch64-linux ;;
  *) SYSTEM= ;;
esac

# Echo the workstation config name, then a container config name, for $SYSTEM.
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

# Echo the names of the packages in a profile's home.packages that match a
# derivation-name regex (anchored at the start).
package_names() {
  nix eval --json "$ROOT#homeConfigurations.\"$1\".config.home.packages" \
    --apply "ps: map (p: p.name) (builtins.filter (p: builtins.match \"$2\" (p.name or \"\") != null) ps)" 2>/dev/null
}

test_gh_source_per_profile() {
  local names
  names=$(package_names "$WORKSTATION" 'gh-[0-9].*') || fail "$WORKSTATION: cannot evaluate home.packages"
  [ "$(jq 'length' <<<"$names")" = 1 ] || fail "$WORKSTATION: does not install exactly one gh: $names"
  names=$(package_names "$CONTAINER" 'gh-[0-9].*') || fail "$CONTAINER: cannot evaluate home.packages"
  [ "$(jq 'length' <<<"$names")" = 0 ] || fail "$CONTAINER: installs a Nix gh that hides the image's newer gh on PATH: $names"
  pass "the workstation profile installs one gh and the container profile installs none"
}

test_profiles_declare_imagemagick() {
  local profile names
  for profile in $WORKSTATION $CONTAINER; do
    names=$(package_names "$profile" 'imagemagick-[0-9].*') || fail "$profile: cannot evaluate home.packages"
    [ "$(jq 'length' <<<"$names")" = 1 ] || fail "$profile: does not install exactly one imagemagick: $names"
  done
  pass "workstation and container profiles declare ImageMagick"
}

test_built_profiles_ship_gate_tools() {
  local profile out tool
  for profile in $WORKSTATION $CONTAINER; do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    for tool in magick convert; do
      [ -x "$out/home-path/bin/$tool" ] || fail "$profile: the home profile ships no $tool binary"
      "$out/home-path/bin/$tool" -version >/dev/null 2>&1 </dev/null || fail "$profile: $tool -version fails"
    done
    if [ "$profile" = "$WORKSTATION" ]; then
      [ -x "$out/home-path/bin/gh" ] || fail "$profile: the home profile ships no gh binary"
      "$out/home-path/bin/gh" --version >/dev/null 2>&1 </dev/null || fail "$profile: gh --version fails"
    else
      [ ! -e "$out/home-path/bin/gh" ] || fail "$profile: the home profile ships a gh binary that hides the image's gh"
    fi
  done
  pass "built profiles provide runnable magick and convert"
  pass "the built workstation profile provides gh"
  pass "the built container profile provides no gh"
}

if have_linux_nix; then
  PROFILE_NAMES=$(profiles) || fail "cannot discover workstation and container profiles"
  WORKSTATION=$(sed -n 1p <<<"$PROFILE_NAMES")
  CONTAINER=$(sed -n 2p <<<"$PROFILE_NAMES")
  test_gh_source_per_profile
  test_profiles_declare_imagemagick
  test_built_profiles_ship_gate_tools
fi

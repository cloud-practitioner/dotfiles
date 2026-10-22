#!/usr/bin/env bash
# Behavior checks that the Linux home profiles provide the tools the PR
# evidence gate needs, and that no stale Nix gh hides a newer one.
#
# The gate uploads images with `gh pr create --attach`, which needs gh 2.99 or
# newer, and it builds the images with ImageMagick (magick, convert).
#
# Coverage:
# - the container profile installs no gh, so the newer gh from the image's
#   GitHub apt repo (agentic-devcontainer Dockerfile) wins on PATH;
# - the workstation profile installs exactly one gh, and it is 2.99 or newer;
# - both profiles declare exactly one ImageMagick in home.packages;
# - the built profiles ship runnable magick and convert, and the built
#   workstation profile ships a runnable gh at the required version.
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GH_MIN_MAJOR=2
GH_MIN_MINOR=99

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

# True when "gh version X.Y.Z" output $1 is at least the required version.
gh_version_ok() {
  local v major minor
  v=$(sed -n 's/^gh version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' <<<"$1" | head -n 1)
  [ -n "$v" ] || return 1
  read -r major minor <<<"$v"
  [ "$major" -gt "$GH_MIN_MAJOR" ] || { [ "$major" -eq "$GH_MIN_MAJOR" ] && [ "$minor" -ge "$GH_MIN_MINOR" ]; }
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
  local profile out tool version
  for profile in $WORKSTATION $CONTAINER; do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    for tool in magick convert; do
      [ -x "$out/home-path/bin/$tool" ] || fail "$profile: the home profile ships no $tool binary"
      "$out/home-path/bin/$tool" -version >/dev/null 2>&1 </dev/null || fail "$profile: $tool -version fails"
    done
  done
  out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$WORKSTATION\".activationPackage" 2>/dev/null) \
    || fail "$WORKSTATION: activation package does not build"
  [ -x "$out/home-path/bin/gh" ] || fail "$WORKSTATION: the home profile ships no gh binary"
  version=$("$out/home-path/bin/gh" --version 2>&1 </dev/null | head -n 1)
  gh_version_ok "$version" || fail "$WORKSTATION: gh is older than $GH_MIN_MAJOR.$GH_MIN_MINOR: $version"
  out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$CONTAINER\".activationPackage" 2>/dev/null) \
    || fail "$CONTAINER: activation package does not build"
  [ ! -e "$out/home-path/bin/gh" ] || fail "$CONTAINER: the home profile ships a gh binary that hides the image's gh"
  pass "built profiles ship runnable magick and convert; the workstation gh is $GH_MIN_MAJOR.$GH_MIN_MINOR or newer and the container has none"
}

if have_linux_nix; then
  PROFILE_NAMES=$(profiles) || fail "cannot discover workstation and container profiles"
  WORKSTATION=$(sed -n 1p <<<"$PROFILE_NAMES")
  CONTAINER=$(sed -n 2p <<<"$PROFILE_NAMES")
  test_gh_source_per_profile
  test_profiles_declare_imagemagick
  test_built_profiles_ship_gate_tools
fi

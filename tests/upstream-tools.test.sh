#!/usr/bin/env bash
# Behavior checks for the pinned upstream CLI tool (tools/): herdr as its
# vendor's curl installer installs it.
#
# Coverage:
# - both Linux home profiles (workstation and container) for this machine's
#   system install exactly the pinned herdr build from tools/sources.json, and
#   no Nix-built Claude Code or Pi (Home Manager installs those, and the GitHub
#   Copilot CLI, with pnpm; tests/node-tools.test.sh covers that);
# - the built profiles' herdr reports the pinned version and refuses to
#   self-update;
# - `update-tools` rewrites the version, URLs, and hashes from a vendor-shaped
#   manifest, leaves the pin alone in --dry-run, and rejects bad manifests;
# - the `nix run .#update-tools` flake app builds (shellcheck included).
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot upstream-tools
SOURCES="$ROOT/tools/sources.json"
TOOLS=(herdr)

case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-linux ;;
  aarch64|arm64) SYSTEM=aarch64-linux ;;
  *) SYSTEM= ;;
esac

pin() {
  jq -r --arg t "$1" --arg f "$2" '.[$t][$f]' "$3"
}

pin_platform() {
  jq -r --arg t "$1" --arg s "$2" --arg f "$3" '.[$t].platforms[$s][$f]' "$4"
}

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

test_profiles_install_pinned_builds() {
  local profile packages tool matches
  have_linux_nix || return 0
  for profile in $(profiles); do
    packages=$(nix eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.packages" \
      --apply 'map (p: { name = p.pname or p.name; version = p.version or null; url = p.src.url or null; hash = p.src.outputHash or null; })' \
      2>/dev/null) || fail "$profile: cannot evaluate home.packages"
    for tool in "${TOOLS[@]}"; do
      matches=$(jq -c --arg t "$tool" '[.[] | select(.name == $t)]' <<<"$packages")
      [ "$(jq length <<<"$matches")" = 1 ] \
        || fail "$profile: expected exactly one $tool package, got $matches"
      [ "$(jq -r '.[0].version' <<<"$matches")" = "$(pin "$tool" version "$SOURCES")" ] \
        || fail "$profile: $tool is not at the pinned version: $matches"
      [ "$(jq -r '.[0].url' <<<"$matches")" = "$(pin_platform "$tool" "$SYSTEM" url "$SOURCES")" ] \
        || fail "$profile: $tool does not fetch the pinned upstream URL: $matches"
      [ "$(jq -r '.[0].hash' <<<"$matches")" = "$(pin_platform "$tool" "$SYSTEM" sha256 "$SOURCES")" ] \
        || fail "$profile: $tool does not verify the pinned SHA-256: $matches"
    done
    [ "$(jq '[.[] | select(.name | test("^(pi|pi-coding-agent|claude-code|github-copilot-cli)$"))] | length' <<<"$packages")" = 0 ] \
      || fail "$profile: still installs a Nix-built Claude Code, Pi, or Copilot CLI: $packages"
  done
  pass "workstation and container profiles install herdr from the pinned upstream release, and no Nix-built Claude Code, Pi, or Copilot CLI"
}

test_built_profiles_run_pinned_versions() {
  local profile out home update tool
  have_linux_nix || return 0
  for profile in $(profiles); do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    home="$TMP_ROOT/home-$profile"
    mkdir -p "$home"
    [ "$(HOME=$home "$out/home-path/bin/herdr" --version)" = "herdr $(pin herdr version "$SOURCES")" ] \
      || fail "$profile: herdr --version is not the pinned version"
    for tool in claude pi copilot; do
      [ ! -e "$out/home-path/bin/$tool" ] || fail "$profile: the home profile still ships a Nix-built $tool"
    done
    update=$(HOME=$home "$out/home-path/bin/herdr" update </dev/null 2>&1)
    assert_contains "$update" "self-update is disabled for Nix installs" "$profile: herdr update is not refused: $update"
    [ "$(HOME=$home HERDR_CONFIG_PATH="$ROOT/home/.config/herdr/config.toml" "$out/home-path/bin/herdr" config check)" = "config: ok" ] \
      || fail "$profile: herdr rejects home/.config/herdr/config.toml"
  done
  pass "built workstation and container profiles run herdr at the pinned version with self-update refused"
}

# Write a vendor-shaped herdr release manifest under $1 for version $2.
write_fixtures() {
  local dir=$1 herdr=$2
  mkdir -p "$dir"
  jq -n --arg v "$herdr" '{version: $v,
      assets: {
        "linux-x86_64": "https://github.com/herdrdev/herdr/releases/download/v\($v)/herdr-linux-x86_64",
        "linux-aarch64": "https://github.com/herdrdev/herdr/releases/download/v\($v)/herdr-linux-aarch64"},
      sha256: {"linux-x86_64": ("D" * 64), "linux-aarch64": ("e" * 64)}}' \
    > "$dir/herdr-latest.json"
}

# Copy the committed pins to $1/sources.json.
copy_pins() {
  mkdir -p "$1"
  cp "$SOURCES" "$1/sources.json"
}

# Fail with $1 unless the pins in $2 still match the committed ones.
assert_pins_unchanged() {
  cmp -s "$SOURCES" "$2/sources.json" || fail "$1"
}

run_update_tools() {
  local dir=$1 sources=$2
  shift 2
  HERDR_MANIFEST_URL="file://$dir/herdr-latest.json" \
    UPDATE_TOOLS_SOURCES="$sources" \
    bash "$ROOT/tools/update.sh" "$@" 2>&1
}

test_update_tools_rewrites_pins() {
  local dir="$TMP_ROOT/update" pins sources out
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip: update-tools needs curl and jq"
    return 0
  fi
  pins="$dir/pins"
  sources="$pins/sources.json"
  write_fixtures "$dir" 9.9.9
  copy_pins "$pins"

  out=$(run_update_tools "$dir" "$sources" --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "herdr        $(pin herdr version "$SOURCES") -> 9.9.9" "dry run does not report the herdr bump: $out"
  assert_contains "$out" "Dry run: $sources left unchanged" "dry run does not say it wrote nothing: $out"
  assert_pins_unchanged "dry run modified the pins" "$pins"

  out=$(run_update_tools "$dir" "$sources") || fail "update failed: $out"
  assert_contains "$out" "Updated $sources" "update does not report the rewrite: $out"
  [ "$(jq -c 'keys' "$sources")" = '["herdr"]' ] \
    || fail "update-tools pins other tools than herdr: $(jq -c keys "$sources")"
  [ "$(pin herdr version "$sources")" = 9.9.9 ] || fail "herdr version not bumped"
  [ "$(pin herdr checksums "$sources")" = "file://$dir/herdr-latest.json" ] \
    || fail "herdr pin does not record its checksum source"
  [ "$(pin_platform herdr x86_64-linux url "$sources")" = "https://github.com/herdrdev/herdr/releases/download/v9.9.9/herdr-linux-x86_64" ] \
    || fail "herdr URL is not the manifest asset"
  [ "$(pin_platform herdr x86_64-linux sha256 "$sources")" = "$(printf 'd%.0s' {1..64})" ] \
    || fail "herdr hash is not the lower-cased manifest checksum"
  [ "$(pin_platform herdr aarch64-linux sha256 "$sources")" = "$(printf 'e%.0s' {1..64})" ] \
    || fail "herdr aarch64 hash is not the manifest checksum"
  [ "$(jq -c '[.[] | .platforms | keys] | unique' "$sources")" = '[["aarch64-linux","x86_64-linux"]]' ] \
    || fail "pins cover other systems than the Linux profiles"

  out=$(run_update_tools "$dir" "$sources") || fail "idempotent rerun failed: $out"
  assert_contains "$out" "The herdr pin is already current." "rerun does not report a current pin: $out"
  pass "update-tools rewrites herdr's version, URLs, and hashes from the vendor manifest, and leaves the pin alone in --dry-run"
}

test_update_tools_rejects_bad_manifests() {
  local dir="$TMP_ROOT/bad" pins sources out
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip: update-tools needs curl and jq"
    return 0
  fi
  pins="$dir/pins"
  sources="$pins/sources.json"
  write_fixtures "$dir" 9.9.9
  copy_pins "$pins"

  jq '.sha256["linux-aarch64"] = "not-a-hash"' "$dir/herdr-latest.json" > "$dir/m" \
    && mv "$dir/m" "$dir/herdr-latest.json"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools accepted a malformed checksum: $out"
  fi
  assert_contains "$out" "herdr linux-aarch64: missing or malformed SHA-256" "malformed checksum error is unclear: $out"
  assert_pins_unchanged "a rejected update modified the pins" "$pins"

  write_fixtures "$dir" 9.9.9
  jq '.assets["linux-aarch64"] = "https://github.com/herdrdev/herdr/releases/download/v9.9.8/herdr-linux-aarch64"' \
    "$dir/herdr-latest.json" > "$dir/m" && mv "$dir/m" "$dir/herdr-latest.json"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools accepted a herdr asset for another version: $out"
  fi
  assert_contains "$out" "herdr: file://$dir/herdr-latest.json has no 9.9.9 asset for linux-aarch64" "wrong-version asset error is unclear: $out"
  assert_pins_unchanged "a rejected update modified the pins" "$pins"

  rm "$dir/herdr-latest.json"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools succeeded without the herdr manifest: $out"
  fi
  assert_contains "$out" "cannot fetch file://$dir/herdr-latest.json" "unreachable endpoint error is unclear: $out"
  pass "update-tools rejects malformed or incomplete manifests without touching the pins"
}

test_update_tools_flake_app() {
  local out
  have_linux_nix || return 0
  out=$(nix run "$ROOT#update-tools" -- --help 2>/dev/null) || fail "nix run .#update-tools does not build or run"
  assert_contains "$out" "Usage: nix run .#update-tools [-- --dry-run]" "update-tools app prints unexpected help: $out"
  pass "nix run .#update-tools builds (shellcheck-clean) and runs"
}

test_profiles_install_pinned_builds
test_built_profiles_run_pinned_versions
test_update_tools_rewrites_pins
test_update_tools_rejects_bad_manifests
test_update_tools_flake_app

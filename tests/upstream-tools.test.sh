#!/usr/bin/env bash
# Behavior checks for the pinned upstream CLI tools (tools/): herdr, Claude
# Code, and Pi as each vendor's curl installer installs them.
#
# Coverage:
# - both Linux home profiles (workstation and container) for this machine's
#   system install exactly the pinned builds from tools/sources.json;
# - the built profiles' tools report the pinned versions, Pi runs on its own
#   Nix Node.js, and self-updates refuse and write nothing;
# - `update-tools` rewrites every version, URL, and hash (and Pi's npm lock)
#   from vendor-shaped manifests, leaves the pins alone in --dry-run, and
#   rejects bad manifests;
# - the `nix run .#update-tools` flake app builds (shellcheck included).
#
# Nix evaluates the flake from Git, so new files must be tracked (`git add`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot upstream-tools
SOURCES="$ROOT/tools/sources.json"
TOOLS=(claude-code herdr pi)

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
      # Pi pins its npm lock (tools/pi/), not a per-platform download.
      [ "$tool" = pi ] && continue
      [ "$(jq -r '.[0].url' <<<"$matches")" = "$(pin_platform "$tool" "$SYSTEM" url "$SOURCES")" ] \
        || fail "$profile: $tool does not fetch the pinned upstream URL: $matches"
      [ "$(jq -r '.[0].hash' <<<"$matches")" = "$(pin_platform "$tool" "$SYSTEM" sha256 "$SOURCES")" ] \
        || fail "$profile: $tool does not verify the pinned SHA-256: $matches"
    done
    assert_not_contains "$packages" '"pi-coding-agent"' "$profile: still installs nixpkgs pi-coding-agent"
  done
  pass "workstation and container profiles install herdr, Claude Code, and Pi from the pinned upstream releases"
}

test_built_profiles_run_pinned_versions() {
  local profile out home update_home update
  have_linux_nix || return 0
  for profile in $(profiles); do
    out=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".activationPackage" 2>/dev/null) \
      || fail "$profile: activation package does not build"
    home="$TMP_ROOT/home-$profile"
    mkdir -p "$home"
    [ "$(HOME=$home "$out/home-path/bin/claude" --version)" = "$(pin claude-code version "$SOURCES") (Claude Code)" ] \
      || fail "$profile: claude --version is not the pinned version"
    [ "$(HOME=$home "$out/home-path/bin/herdr" --version)" = "herdr $(pin herdr version "$SOURCES")" ] \
      || fail "$profile: herdr --version is not the pinned version"
    [ "$(env -i HOME="$home" PATH=/var/empty "$out/home-path/bin/pi" --version)" = "$(pin pi version "$SOURCES")" ] \
      || fail "$profile: pi does not run the pinned version on its own Node.js (no node on PATH)"
    update_home="$home/claude-update"
    mkdir -p "$update_home"
    update=$(HOME=$update_home CLAUDE_CONFIG_DIR="$update_home/.claude" "$out/home-path/bin/claude" update </dev/null 2>&1)
    assert_contains "$update" "Updates are disabled" "$profile: claude update is not refused: $update"
    [ ! -e "$update_home/.local/bin/claude" ] || fail "$profile: claude update installed an unpinned copy"
    update=$(HOME=$home "$out/home-path/bin/herdr" update </dev/null 2>&1)
    assert_contains "$update" "self-update is disabled for Nix installs" "$profile: herdr update is not refused: $update"
    [ "$(HOME=$home HERDR_CONFIG_PATH="$ROOT/home/.config/herdr/config.toml" "$out/home-path/bin/herdr" config check)" = "config: ok" ] \
      || fail "$profile: herdr rejects home/.config/herdr/config.toml"
    update_home="$home/pi-update"
    mkdir -p "$update_home"
    # --force skips the up-to-date shortcut; a sandboxed npm prefix catches a stray global install.
    if update=$(HOME=$update_home npm_config_prefix="$update_home/npm-global" \
      "$out/home-path/bin/pi" update --self --force </dev/null 2>&1); then
      fail "$profile: pi update succeeded: $update"
    fi
    assert_contains "$update" "pi cannot self-update this installation" "$profile: pi update is not refused: $update"
    [ ! -e "$update_home/npm-global" ] || fail "$profile: pi update installed an unpinned copy"
    grep -aq PI_SKIP_VERSION_CHECK "$(readlink -f "$out/home-path/bin/pi")" \
      || fail "$profile: pi wrapper does not skip the version check"
  done
  pass "built workstation and container profiles run herdr, Claude Code, and Pi at the pinned versions with self-updates refused"
}

# Write vendor-shaped release manifests under $1 for claude $2, herdr $3, pi $4.
# The Pi lock leaves out its own package's hash, which the release metadata lists.
write_fixtures() {
  local dir=$1 claude=$2 herdr=$3 pi=$4 pi_tarball
  pi_tarball="https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-$pi.tgz"
  mkdir -p "$dir/claude/$claude" "$dir/pi-api/$pi"
  printf '%s\n' "$claude" > "$dir/claude/latest"
  jq -n --arg v "$claude" '{version: $v, platforms: {
      "linux-x64": {binary: "claude", checksum: ("a" * 64), size: 1},
      "linux-arm64": {binary: "claude", checksum: ("b" * 64), size: 1},
      "darwin-arm64": {binary: "claude", checksum: ("c" * 64), size: 1}}}' \
    > "$dir/claude/$claude/manifest.json"
  jq -n --arg v "$herdr" '{version: $v,
      assets: {
        "linux-x86_64": "https://github.com/herdrdev/herdr/releases/download/v\($v)/herdr-linux-x86_64",
        "linux-aarch64": "https://github.com/herdrdev/herdr/releases/download/v\($v)/herdr-linux-aarch64"},
      sha256: {"linux-x86_64": ("D" * 64), "linux-aarch64": ("e" * 64)}}' \
    > "$dir/herdr-latest.json"
  jq -n --arg v "$pi" --arg t "$pi_tarball" '{schemaVersion: 1, version: $v, packages: [
      {name: "@earendil-works/pi-coding-agent", version: $v, tarball: $t, integrity: "sha512-pi-fixture"}]}' \
    > "$dir/pi-api/latest"
  jq -n --arg v "$pi" '{name: "@earendil-works/pi-coding-agent-install", version: $v, private: true,
      dependencies: {"@earendil-works/pi-coding-agent": $v}}' \
    > "$dir/pi-api/$pi/package.json"
  jq -n --arg v "$pi" --arg t "$pi_tarball" '{name: "@earendil-works/pi-coding-agent-install", version: $v,
      lockfileVersion: 3, requires: true, packages: {
        "": {name: "@earendil-works/pi-coding-agent-install", version: $v,
          dependencies: {"@earendil-works/pi-coding-agent": $v}},
        "node_modules/@earendil-works/pi-coding-agent": {version: $v, resolved: $t,
          dependencies: {chalk: "6.0.0"}, bin: {pi: "dist/bundle/cli.js"}},
        "node_modules/chalk": {version: "6.0.0",
          resolved: "https://registry.npmjs.org/chalk/-/chalk-6.0.0.tgz", integrity: "sha512-chalk-fixture"}}}' \
    > "$dir/pi-api/$pi/package-lock.json"
}

# Copy the committed pins (sources.json and Pi's lock) to $1.
copy_pins() {
  mkdir -p "$1"
  cp "$SOURCES" "$1/sources.json"
  cp -R "$ROOT/tools/pi" "$1/pi"
}

# Fail with $1 unless the pins in $2 still match the committed ones.
assert_pins_unchanged() {
  cmp -s "$SOURCES" "$2/sources.json" && diff -r "$ROOT/tools/pi" "$2/pi" >/dev/null || fail "$1"
}

run_update_tools() {
  local dir=$1 sources=$2
  shift 2
  CLAUDE_RELEASES_URL="file://$dir/claude" \
    HERDR_MANIFEST_URL="file://$dir/herdr-latest.json" \
    PI_INSTALLER_API_URL="file://$dir/pi-api" \
    UPDATE_TOOLS_SOURCES="$sources" \
    bash "$ROOT/tools/update.sh" "$@" 2>&1
}

test_update_tools_rewrites_pins() {
  local dir="$TMP_ROOT/update" pins sources out pi_key=node_modules/@earendil-works/pi-coding-agent
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip: update-tools needs curl and jq"
    return 0
  fi
  pins="$dir/pins"
  sources="$pins/sources.json"
  write_fixtures "$dir" 9.8.7 9.9.9 9.10.11
  copy_pins "$pins"

  out=$(run_update_tools "$dir" "$sources" --dry-run) || fail "dry run failed: $out"
  assert_contains "$out" "claude-code  $(pin claude-code version "$SOURCES") -> 9.8.7" "dry run does not report the Claude Code bump: $out"
  assert_contains "$out" "pi           $(pin pi version "$SOURCES") -> 9.10.11" "dry run does not report the Pi bump: $out"
  assert_contains "$out" "Dry run: $sources and $pins/pi left unchanged" "dry run does not say it wrote nothing: $out"
  assert_pins_unchanged "dry run modified the pins" "$pins"

  out=$(run_update_tools "$dir" "$sources") || fail "update failed: $out"
  assert_contains "$out" "Updated $sources and $pins/pi" "update does not report the rewrite: $out"
  [ "$(pin claude-code version "$sources")" = 9.8.7 ] || fail "Claude Code version not bumped"
  [ "$(pin_platform claude-code x86_64-linux url "$sources")" = "file://$dir/claude/9.8.7/linux-x64/claude" ] \
    || fail "Claude Code URL does not follow install.sh's layout"
  [ "$(pin_platform claude-code aarch64-linux sha256 "$sources")" = "$(printf 'b%.0s' {1..64})" ] \
    || fail "Claude Code hash is not the manifest checksum"
  [ "$(pin claude-code checksums "$sources")" = "file://$dir/claude/9.8.7/manifest.json" ] \
    || fail "Claude Code pin does not record its checksum source"
  [ "$(pin herdr version "$sources")" = 9.9.9 ] || fail "herdr version not bumped"
  [ "$(pin_platform herdr x86_64-linux url "$sources")" = "https://github.com/herdrdev/herdr/releases/download/v9.9.9/herdr-linux-x86_64" ] \
    || fail "herdr URL is not the manifest asset"
  [ "$(pin_platform herdr x86_64-linux sha256 "$sources")" = "$(printf 'd%.0s' {1..64})" ] \
    || fail "herdr hash is not the lower-cased manifest checksum"
  [ "$(pin pi version "$sources")" = 9.10.11 ] || fail "Pi version not bumped"
  [ "$(pin pi checksums "$sources")" = "file://$dir/pi-api/9.10.11/package-lock.json" ] \
    || fail "Pi pin does not record its lock source"
  cmp -s "$dir/pi-api/9.10.11/package.json" "$pins/pi/package.json" \
    || fail "Pi package.json is not the installer's"
  [ "$(jq -r --arg k "$pi_key" '.packages[$k].integrity' "$pins/pi/package-lock.json")" = sha512-pi-fixture ] \
    || fail "Pi lock does not pin Pi's own package by the release metadata's hash"
  [ "$(jq -S --arg k "$pi_key" 'del(.packages[$k].integrity)' "$pins/pi/package-lock.json")" = "$(jq -S . "$dir/pi-api/9.10.11/package-lock.json")" ] \
    || fail "Pi lock differs from the installer's beyond the added hash"
  [ "$(jq -c '[.[] | .platforms // empty | keys] | unique' "$sources")" = '[["aarch64-linux","x86_64-linux"]]' ] \
    || fail "pins cover other systems than the Linux profiles"

  out=$(run_update_tools "$dir" "$sources") || fail "idempotent rerun failed: $out"
  assert_contains "$out" "All pins are already current." "rerun does not report current pins: $out"
  pass "update-tools rewrites every version, URL, and hash and Pi's lock from the vendor manifests, and leaves pins alone in --dry-run"
}

test_update_tools_rejects_bad_manifests() {
  local dir="$TMP_ROOT/bad" pins sources out
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip: update-tools needs curl and jq"
    return 0
  fi
  pins="$dir/pins"
  sources="$pins/sources.json"
  write_fixtures "$dir" 9.8.7 9.9.9 9.10.11
  copy_pins "$pins"

  jq '.platforms["linux-arm64"].checksum = "not-a-hash"' "$dir/claude/9.8.7/manifest.json" > "$dir/m" \
    && mv "$dir/m" "$dir/claude/9.8.7/manifest.json"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools accepted a malformed checksum: $out"
  fi
  assert_contains "$out" "claude-code linux-arm64: missing or malformed SHA-256" "malformed checksum error is unclear: $out"
  assert_pins_unchanged "a rejected update modified the pins" "$pins"

  write_fixtures "$dir" 9.8.7 9.9.9 9.10.11
  jq 'del(.packages)' "$dir/pi-api/latest" > "$dir/m" && mv "$dir/m" "$dir/pi-api/latest"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools accepted a Pi lock with an unhashed package: $out"
  fi
  assert_contains "$out" "pi: no published hash for node_modules/@earendil-works/pi-coding-agent" "unhashed package error is unclear: $out"
  assert_pins_unchanged "a rejected update modified the pins" "$pins"

  write_fixtures "$dir" 9.8.7 9.9.9 9.10.11
  jq '.packages["node_modules/@earendil-works/pi-coding-agent"].version = "9.10.10"' \
    "$dir/pi-api/9.10.11/package-lock.json" > "$dir/m" && mv "$dir/m" "$dir/pi-api/9.10.11/package-lock.json"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools accepted a Pi lock for another version: $out"
  fi
  assert_contains "$out" "pi: file://$dir/pi-api/9.10.11/package-lock.json does not lock @earendil-works/pi-coding-agent@9.10.11" "wrong-version lock error is unclear: $out"
  assert_pins_unchanged "a rejected update modified the pins" "$pins"

  rm "$dir/pi-api/latest"
  if out=$(run_update_tools "$dir" "$sources"); then
    fail "update-tools succeeded without the Pi release metadata: $out"
  fi
  assert_contains "$out" "cannot fetch file://$dir/pi-api/latest" "unreachable endpoint error is unclear: $out"
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

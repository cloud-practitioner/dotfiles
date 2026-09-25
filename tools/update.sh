#!/usr/bin/env bash
# Bump the herdr, Claude Code, and Pi pins in tools/sources.json to each
# vendor's latest release. Versions and SHA-256 checksums come from the same
# manifests the vendors' curl installers read, so a pin always names exactly
# the artifact `curl ... | sh` would have installed. Usage is below; the
# endpoint variables exist so tests can point them at local fixtures.
set -euo pipefail

CLAUDE_RELEASES_URL=${CLAUDE_RELEASES_URL:-https://downloads.claude.ai/claude-code-releases}
HERDR_MANIFEST_URL=${HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}
PI_INSTALLER_API_URL=${PI_INSTALLER_API_URL:-https://pi.dev/api/installer/releases}
PI_RELEASES_URL=${PI_RELEASES_URL:-https://github.com/earendil-works/pi/releases/download}
SOURCES=${UPDATE_TOOLS_SOURCES:-tools/sources.json}

# Nix system -> each vendor's platform name. Keep in sync with linuxSystems in flake.nix.
SYSTEMS=(x86_64-linux aarch64-linux)
declare -A CLAUDE_PLATFORM=([x86_64-linux]=linux-x64 [aarch64-linux]=linux-arm64)
declare -A HERDR_PLATFORM=([x86_64-linux]=linux-x86_64 [aarch64-linux]=linux-aarch64)
declare -A PI_PLATFORM=([x86_64-linux]=linux-x64 [aarch64-linux]=linux-arm64)

die() {
  printf 'update-tools: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: nix run .#update-tools [-- --dry-run]

Bump the herdr, Claude Code, and Pi pins in tools/sources.json to the latest
upstream releases. --dry-run shows the new pins and writes nothing.
Run it from the repository root, then rebuild (README "Upstream CLI tools").
EOF
}

fetch() {
  curl -fsSL --retry 3 --connect-timeout 10 "$1" || die "cannot fetch $1"
}

check_version() {
  [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$1: unexpected version '$2'"
}

check_sha256() {
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "$1: missing or malformed SHA-256 '$2'"
}

# Echo the platforms object $1 with {url: $3, sha256: $4} added for system $2.
add_platform() {
  jq -c --arg system "$2" --arg url "$3" --arg sha256 "$4" \
    '.[$system] = {url: $url, sha256: $sha256}' <<<"$1"
}

# Echo one tool's pin: version $1, checksum provenance URL $2, platforms $3.
tool_json() {
  jq -n --arg version "$1" --arg checksums "$2" --argjson platforms "$3" \
    '{version: $version, checksums: $checksums, platforms: $platforms}'
}

# Claude Code: install.sh reads <releases>/latest, then fetches
# <releases>/<version>/<platform>/claude and verifies it against the
# per-platform checksum in <releases>/<version>/manifest.json.
pin_claude_code() {
  local version manifest_url manifest system platform sha256 platforms='{}'
  version=$(fetch "$CLAUDE_RELEASES_URL/latest")
  check_version claude-code "$version"
  manifest_url="$CLAUDE_RELEASES_URL/$version/manifest.json"
  manifest=$(fetch "$manifest_url")
  [ "$(jq -r .version <<<"$manifest")" = "$version" ] \
    || die "claude-code: $manifest_url does not describe $version"
  for system in "${SYSTEMS[@]}"; do
    platform=${CLAUDE_PLATFORM[$system]}
    [ "$(jq -r --arg p "$platform" '.platforms[$p].binary // empty' <<<"$manifest")" = claude ] \
      || die "claude-code: $manifest_url has no binary for $platform"
    sha256=$(jq -r --arg p "$platform" '.platforms[$p].checksum // empty' <<<"$manifest")
    check_sha256 "claude-code $platform" "$sha256"
    platforms=$(add_platform "$platforms" "$system" "$CLAUDE_RELEASES_URL/$version/$platform/claude" "$sha256")
  done
  tool_json "$version" "$manifest_url" "$platforms"
}

# herdr: install.sh (and `herdr update`) read latest.json, which lists each
# platform's release asset URL and its SHA-256.
pin_herdr() {
  local manifest version system platform url sha256 platforms='{}'
  manifest=$(fetch "$HERDR_MANIFEST_URL")
  version=$(jq -r '.version // empty' <<<"$manifest")
  check_version herdr "$version"
  for system in "${SYSTEMS[@]}"; do
    platform=${HERDR_PLATFORM[$system]}
    url=$(jq -r --arg p "$platform" '.assets[$p] // empty' <<<"$manifest")
    [[ $url == */v$version/herdr-$platform ]] \
      || die "herdr: $HERDR_MANIFEST_URL has no $version asset for $platform (got '$url')"
    sha256=$(jq -r --arg p "$platform" '.sha256[$p] // empty | ascii_downcase' <<<"$manifest")
    check_sha256 "herdr $platform" "$sha256"
    platforms=$(add_platform "$platforms" "$system" "$url" "$sha256")
  done
  tool_json "$version" "$HERDR_MANIFEST_URL" "$platforms"
}

# Pi: install.sh takes the current release from the installer API; the same
# GitHub release publishes standalone binaries and a SHA256SUMS file.
pin_pi() {
  local version sums_url sums system asset sha256 platforms='{}'
  version=$(fetch "$PI_INSTALLER_API_URL/latest" | jq -r '.version // empty')
  check_version pi "$version"
  sums_url="$PI_RELEASES_URL/v$version/SHA256SUMS"
  sums=$(fetch "$sums_url")
  for system in "${SYSTEMS[@]}"; do
    asset="pi-${PI_PLATFORM[$system]}.tar.gz"
    sha256=$(awk -v f="$asset" '$2 == f { print $1; exit }' <<<"$sums")
    check_sha256 "pi $asset" "$sha256"
    platforms=$(add_platform "$platforms" "$system" "$PI_RELEASES_URL/v$version/$asset" "$sha256")
  done
  tool_json "$version" "$sums_url" "$platforms"
}

main() {
  local dry_run=0 old claude_code herdr pi new tool
  case "${1:-}" in
    "") ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  [ -f "$SOURCES" ] || die "$SOURCES not found; run from the dotfiles repository root"

  old=$(cat "$SOURCES")
  claude_code=$(pin_claude_code)
  herdr=$(pin_herdr)
  pi=$(pin_pi)
  new=$(jq -n --argjson c "$claude_code" --argjson h "$herdr" --argjson p "$pi" \
    '{"claude-code": $c, herdr: $h, pi: $p}')

  for tool in claude-code herdr pi; do
    printf '%-12s %s -> %s\n' "$tool" \
      "$(jq -r --arg t "$tool" '.[$t].version // "none"' <<<"$old")" \
      "$(jq -r --arg t "$tool" '.[$t].version' <<<"$new")"
  done

  if [ "$(jq -S . <<<"$old")" = "$(jq -S . <<<"$new")" ]; then
    echo "All pins are already current."
    return 0
  fi
  if [ "$dry_run" = 1 ]; then
    echo "Dry run: $SOURCES left unchanged. It would become:"
    printf '%s\n' "$new"
    return 0
  fi
  printf '%s\n' "$new" > "$SOURCES.tmp"
  mv "$SOURCES.tmp" "$SOURCES"
  echo "Updated $SOURCES. Commit it, then rebuild each environment (README \"Upstream CLI tools\")."
}

main "$@"

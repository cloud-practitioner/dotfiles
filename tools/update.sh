#!/usr/bin/env bash
# Bump the herdr pin in tools/sources.json to herdr's latest release. The
# version and hashes come from the same manifest herdr's curl installer reads,
# so the pin always names exactly what `curl ... | sh` would have installed.
# Usage is below; the endpoint variable exists so tests can point it at a local
# fixture.
set -euo pipefail

HERDR_MANIFEST_URL=${HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}
SOURCES=${UPDATE_TOOLS_SOURCES:-tools/sources.json}

# Nix system -> herdr's platform name. Keep in sync with linuxSystems in flake.nix.
SYSTEMS=(x86_64-linux aarch64-linux)
declare -A HERDR_PLATFORM=([x86_64-linux]=linux-x86_64 [aarch64-linux]=linux-aarch64)

die() {
  printf 'update-tools: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: nix run .#update-tools [-- --dry-run]

Bump the herdr pin in tools/sources.json to the latest upstream release.
--dry-run shows the new pin and writes nothing.
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

main() {
  local dry_run=0 old herdr new
  case "${1:-}" in
    "") ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  [ -f "$SOURCES" ] || die "$SOURCES not found; run from the dotfiles repository root"

  old=$(cat "$SOURCES")
  herdr=$(pin_herdr)
  new=$(jq -n --argjson h "$herdr" '{herdr: $h}')

  printf '%-12s %s -> %s\n' herdr \
    "$(jq -r '.herdr.version // "none"' <<<"$old")" "$(jq -r '.herdr.version' <<<"$new")"

  if [ "$(jq -S . <<<"$old")" = "$(jq -S . <<<"$new")" ]; then
    echo "The herdr pin is already current."
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

#!/usr/bin/env bash
# Add the dotfiles' Pi `skills` entries to the settings file Pi really reads.
#
# Usage: pi-config.sh install <settings.json>
#
# Pi reads $PI_CODING_AGENT_DIR/settings.json when that variable is set, else
# ~/.pi/agent/settings.json. home.nix links the latter to the dotfiles'
# home/.pi/agent/settings.json, which carries the `skills` entry for the Ixia
# marketplace clone (tools/ixia-marketplace.sh). Flakes evaluate purely, so only
# activation time can see PI_CODING_AGENT_DIR (the devcontainer points it at the
# workspace's .pi, where Pi never looks at the linked file).
#
# PI_CODING_AGENT_DIR unset, empty, or naming ~/.pi/agent: nothing to do, the
# linked file is what Pi reads.
#
# Any other PI_CODING_AGENT_DIR, which may already hold the owner's own
# settings.json: every entry of the dotfiles file's `skills` list is appended
# to the owner's `skills` list unless it is already there (or the owner
# listed it with a +, - or ! prefix: that choice stays). Nothing else of the
# dotfiles file is copied (theme, packages, ... stay the owner's), no other
# owner value changes, and the owner's `skills` entries keep their order.
# Written only when that changes something, atomically, keeping the file mode,
# after a one-time byte-for-byte settings.json.pre-dotfiles-<epoch> backup;
# absent, the file is created with just `skills`. Re-running is a no-op.
set -euo pipefail

log() { printf 'pi-config: %s\n' "$*"; }
warn() { printf 'pi-config: warning: %s\n' "$*" >&2; }

# jq: append the entries of $add[0].skills that $cur[0] does not list yet.
# shellcheck disable=SC2016
MERGE='
def bare: ltrimstr("+") | ltrimstr("-") | ltrimstr("!");
($add[0].skills // []) as $want
| ($cur[0].skills // []) as $have
| ([$have[] | strings | bare]) as $known
| $cur[0] + {skills: ($have + [$want[] | select(. as $s | $known | index($s | bare) | not)])}'

is_json_object() {
  jq -e -n --slurpfile doc "$1" '($doc | length) == 1 and ($doc[0] | type) == "object"' >/dev/null 2>&1
}

# The directory Pi reads when it is not ~/.pi/agent, else nothing.
configured_dir() {
  local dir=${PI_CODING_AGENT_DIR:-} home_dir="$HOME/.pi/agent"
  case $dir in /*) ;; *) return 0 ;; esac
  dir=$(realpath -m -s -- "$dir")
  if [ "$dir" != "$(realpath -m -s -- "$home_dir")" ] && [ ! "$dir" -ef "$home_dir" ]; then
    printf '%s\n' "$dir"
  fi
}

merge_skills() {
  local src=$1 dest=$2/settings.json dir tmp backup
  if ! is_json_object "$src" || ! jq -e '(.skills // []) | type == "array"' "$src" >/dev/null 2>&1; then
    warn "$src is not a JSON object with a skills list, skipping"
    return 0
  fi
  if [ "$(jq '(.skills // []) | length' "$src")" = 0 ]; then
    return 0
  fi
  if [ -L "$dest" ]; then
    # Merge into whatever the owner's link points at, keeping the link.
    if ! dest=$(realpath -e -- "$dest" 2>/dev/null); then
      warn "$2/settings.json is a dangling link, skipping"
      return 0
    fi
    [ "$dest" = "$(realpath -e -- "$src")" ] && return 0
  fi
  dir=$(dirname -- "$dest")
  mkdir -p -- "$dir"
  if [ ! -e "$dest" ]; then
    tmp=$(mktemp "$dir/.settings.json.XXXXXX")
    if jq '{skills}' "$src" >"$tmp"; then
      chmod 644 "$tmp"
      mv -f -- "$tmp" "$dest"
      log "created $dest"
    else
      rm -f -- "$tmp"
      warn "could not write $dest"
    fi
    return 0
  fi
  if ! is_json_object "$dest"; then
    warn "$dest is not a JSON object, leaving it untouched"
    return 0
  fi
  if ! jq -e '(.skills // []) | type == "array"' "$dest" >/dev/null 2>&1; then
    warn "skills in $dest is not a list, leaving it untouched"
    return 0
  fi
  # Already merged: leave the file and its directory untouched.
  if jq -e -n --slurpfile cur "$dest" --slurpfile add "$src" "($MERGE) == \$cur[0]" >/dev/null 2>&1; then
    return 0
  fi
  tmp=$(mktemp "$dir/.settings.json.XXXXXX")
  # Copy first so the rewrite keeps the owner's mode, then replace atomically.
  cp -p -- "$dest" "$tmp"
  if ! jq -n --slurpfile cur "$dest" --slurpfile add "$src" "$MERGE" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    warn "could not merge the skills of $src into $dest, leaving it untouched"
    return 0
  fi
  if ! compgen -G "$dest.pre-dotfiles-*" >/dev/null; then
    backup="$dest.pre-dotfiles-$(date +%s)"
    cp -p -- "$dest" "$backup"
    log "backed up $dest to $backup"
  fi
  mv -f -- "$tmp" "$dest"
  log "added the skills of $src to $dest"
}

main() {
  local dir
  [ "${1:-}:$#" = install:2 ] || {
    printf 'usage: %s install <settings.json>\n' "$0" >&2
    exit 2
  }
  case ${PI_CODING_AGENT_DIR:-} in
    '' | /*) ;;
    *) warn "PI_CODING_AGENT_DIR=$PI_CODING_AGENT_DIR is not an absolute path, using $HOME/.pi/agent" ;;
  esac
  dir=$(configured_dir)
  [ -z "$dir" ] || merge_skills "$2" "$dir"
}

main "$@"

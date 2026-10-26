#!/usr/bin/env bash
# Link the dotfiles' Pi keybindings (home/.pi/agent/keybindings.json) into
# $PI_CODING_AGENT_DIR.
#
# Usage: pi-keybindings.sh install <keybindings.json source>
#
# Pi reads <agent-dir>/keybindings.json, where the agent directory is
# $PI_CODING_AGENT_DIR when that is set and non-empty, else ~/.pi/agent (Pi
# docs/keybindings.md and docs/configuration.md, "Agent directory"). Flakes
# evaluate purely, so only activation time can see that variable. home.nix
# links ~/.pi/agent/keybindings.json with a plain home.file entry and runs this
# script after Home Manager's own link step.
#
# PI_CODING_AGENT_DIR unset, empty, or naming ~/.pi/agent: does nothing, so
# that home.file link and Home Manager's collision handling are all there is.
#
# Any other PI_CODING_AGENT_DIR (the devcontainer points it at the workspace),
# which may already hold the owner's own files: keybindings.json there is
# linked to the source only when nothing of that name exists. A file or link of
# the owner's (even a dangling one) is left untouched, with a warning unless it
# is already this link. Nothing is ever overwritten, moved or deleted.
# Re-running is a no-op.
set -euo pipefail

log() { printf 'pi-keybindings: %s\n' "$*"; }
warn() { printf 'pi-keybindings: warning: %s\n' "$*" >&2; }

# The directory Pi reads when it is not ~/.pi/agent, else nothing. Pi expands a
# leading ~ itself; any other relative path depends on Pi's working directory,
# so it is ignored with a warning.
# shellcheck disable=SC2088 # the quoted ~ patterns match Pi's literal setting
configured_dir() {
  local dir=${PI_CODING_AGENT_DIR:-} home_dir="$HOME/.pi/agent"
  case $dir in
    '') return 0 ;;
    '~') dir=$HOME ;;
    '~/'*) dir="$HOME/${dir#'~/'}" ;;
    /*) ;;
    *)
      warn "PI_CODING_AGENT_DIR=$dir is not an absolute path, using $home_dir"
      return 0
      ;;
  esac
  dir=$(realpath -m -s -- "$dir")
  if [ "$dir" != "$(realpath -m -s -- "$home_dir")" ] && [ ! "$dir" -ef "$home_dir" ]; then
    printf '%s\n' "$dir"
  fi
}

install_into() {
  local dir=$1 source=$2 path="$1/keybindings.json"
  if [ -L "$path" ] && [ "$(readlink -- "$path")" = "$source" ]; then
    return 0
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    warn "$path exists, not linking it to $source; move it aside and re-apply"
    return 0
  fi
  mkdir -p -- "$dir"
  ln -s -- "$source" "$path"
  log "linked $path -> $source"
}

main() {
  local dir
  [ "${1:-}:$#" = install:2 ] || {
    printf 'usage: %s install <keybindings.json source>\n' "$0" >&2
    exit 2
  }
  dir=$(configured_dir)
  [ -z "$dir" ] || install_into "$dir" "$2"
}

main "$@"

#!/usr/bin/env bash
# Link the dotfiles' user memory (home/AGENTS.md) into $PI_CODING_AGENT_DIR.
#
# Usage: pi-memory.sh install <AGENTS.md source>
#
# Pi reads its user instructions from <agent-dir>/AGENTS.md, where the agent
# directory is $PI_CODING_AGENT_DIR when that is set and non-empty, else
# ~/.pi/agent (Pi docs/configuration.md, "Agent directory"). Flakes evaluate
# purely, so only activation time can see that variable. home.nix links
# ~/.pi/agent/AGENTS.md with a plain home.file entry and runs this script after
# Home Manager's own link step.
#
# PI_CODING_AGENT_DIR unset, empty, or naming ~/.pi/agent: does nothing, so
# that home.file link and Home Manager's collision handling are all there is.
#
# Any other PI_CODING_AGENT_DIR (the devcontainer points it at the workspace),
# which may already hold the owner's own files: AGENTS.md there is linked to
# the source only when the directory holds no user instructions yet. Pi reads
# the first of AGENTS.override.md, AGENTS.md, AGENTS.MD, CLAUDE.md, CLAUDE.MD
# it finds, so adding AGENTS.md beside an owner's CLAUDE.md would silently
# replace it. Therefore any of those five names that exists (a link of the
# owner's, even a dangling one, or a real file) is left untouched, with a
# warning unless it is already this link. Nothing is ever overwritten, moved or
# deleted. Re-running is a no-op.
set -euo pipefail

log() { printf 'pi-memory: %s\n' "$*"; }
warn() { printf 'pi-memory: warning: %s\n' "$*" >&2; }

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
  local dir=$1 source=$2 path="$1/AGENTS.md" name
  if [ -L "$path" ] && [ "$(readlink -- "$path")" = "$source" ]; then
    return 0
  fi
  for name in AGENTS.override.md AGENTS.md AGENTS.MD CLAUDE.md CLAUDE.MD; do
    if [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
      warn "$dir/$name exists, not linking $path to $source; move it aside and re-apply"
      return 0
    fi
  done
  mkdir -p -- "$dir"
  ln -s -- "$source" "$path"
  log "linked $path -> $source"
}

main() {
  local dir
  [ "${1:-}:$#" = install:2 ] || {
    printf 'usage: %s install <AGENTS.md source>\n' "$0" >&2
    exit 2
  }
  dir=$(configured_dir)
  [ -z "$dir" ] || install_into "$dir" "$2"
}

main "$@"

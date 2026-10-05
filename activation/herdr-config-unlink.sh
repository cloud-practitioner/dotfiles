#!/usr/bin/env bash
set -euo pipefail

herdr="$HOME/.config/herdr"
# Drop only the legacy Home Manager-owned directory link before collision checks.
if [ -L "$herdr" ]; then
  case $(readlink -- "$herdr") in
    "$(readlink -e -- "$1")"/*-home-manager-files/*) rm -- "$herdr" ;;
  esac
fi

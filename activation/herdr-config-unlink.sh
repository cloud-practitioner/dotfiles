#!/usr/bin/env bash
set -euo pipefail

herdr="$HOME/.config/herdr"
if [ -L "$herdr" ]; then
  case $(readlink -- "$herdr") in
    "$(readlink -e -- "$1")"/*-home-manager-files/*) rm -- "$herdr" ;;
  esac
fi

#!/usr/bin/env bash
# Behavioral checks for the zsh line-editor setup in home.nix.
#
# Builds each Linux home profile's generated files into the Nix store (never
# activating them), then starts an interactive zsh against the generated
# .zshrc with a scratch HOME and inspects the resulting keymap state.
#
# Coverage:
# - the `main` keymap is emacs, even with EDITOR=nvim exported;
# - Ctrl+Backspace, Ctrl+Delete, Delete and Shift+Enter resolve to the intended
#   widgets, and plain Backspace/Delete still delete one character;
# - WORDCHARS is empty, so word deletion stops at `-`, `/`, `.` and the like.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v nix >/dev/null 2>&1 || fail "nix is required"
command -v zsh >/dev/null 2>&1 || fail "zsh is required"

TMP_ROOT=$(dotfiles_test_tmproot zsh-keymap)
SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)

probe_profile() {
  local profile=$1 files home out
  files=$(nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$profile\".config.home-files") \
    || fail "$profile: home-files build failed"
  [ -e "$files/.zshrc" ] || fail "$profile: generated .zshrc missing"

  home="$TMP_ROOT/$profile"
  mkdir -p "$home"
  cp -L "$files/.zshrc" "$home/.zshrc"
  [ -e "$files/.zshenv" ] && cp -L "$files/.zshenv" "$home/.zshenv"

  # EDITOR=nvim is what used to flip zle into vi-insert mode; keep it set.
  out=$(HOME="$home" ZDOTDIR="$home" EDITOR=nvim HISTFILE="$home/.zsh_history" \
    TERM=xterm zsh -i -c '
      bindkey -lL main
      printf "WORDCHARS=[%s]\n" "$WORDCHARS"
      for k in "^H" "^[[127;5u" "^[[3;5~" "^[[3~" "^[[27;2;13~" "^[[13;2u" "^?"; do
        bindkey -M main "$k"
      done
      whence -w _insert-newline
    ' </dev/null 2>&1)

  assert_contains "$out" "bindkey -A emacs main" "$profile: main keymap is emacs"
  assert_contains "$out" "WORDCHARS=[]" "$profile: WORDCHARS is empty"
  assert_contains "$out" '"^H" backward-kill-word' "$profile: ^H is backward-kill-word"
  assert_contains "$out" '"^[[127;5u" backward-kill-word' "$profile: CSI 127;5u is backward-kill-word"
  assert_contains "$out" '"^[[3;5~" kill-word' "$profile: Ctrl+Delete is kill-word"
  assert_contains "$out" '"^[[3~" delete-char' "$profile: Delete is delete-char"
  assert_contains "$out" '"^[[27;2;13~" _insert-newline' "$profile: Shift+Enter (modifyOtherKeys) inserts a newline"
  assert_contains "$out" '"^[[13;2u" _insert-newline' "$profile: Shift+Enter (CSI-u) inserts a newline"
  assert_contains "$out" '"^?" backward-delete-char' "$profile: Backspace deletes one character"
  assert_contains "$out" "_insert-newline: function" "$profile: _insert-newline widget is defined"
  pass "$profile: zsh keymap, bindings and WORDCHARS"
}

probe_profile "dev@$SYSTEM"
probe_profile "node@container-$SYSTEM"

#!/usr/bin/env bash
# Behavioral checks for the zsh line-editor setup in home.nix.
#
# Builds each Linux home profile's generated files into the Nix store (never
# activating them), then starts an interactive zsh against the generated
# .zshrc with a scratch HOME, inspects the resulting keymap state, and drives
# a real line editor in a pseudo-terminal.
#
# Coverage:
# - the `main` keymap is emacs, even with EDITOR=nvim exported;
# - Ctrl+Backspace, Ctrl+Delete, Delete and Shift+Enter resolve to the intended
#   widgets, and plain Backspace/Delete still delete one character;
# - WORDCHARS is empty, so word deletion stops at `-`, `/`, `.` and the like;
# - both Shift+Enter sequences insert a newline and clear the
#   zsh-autosuggestions ghost text, so accepting it cannot splice stale text
#   onto the new line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v nix >/dev/null 2>&1 || fail "nix is required"
command -v zsh >/dev/null 2>&1 || fail "zsh is required"

dotfiles_test_tmproot zsh-keymap
SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)

# Drives `zsh -i` in a pseudo-terminal against the scratch HOME given as $1.
# History holds `git status`, so typing `git st` shows the ghost text `atus`.
# Each Shift+Enter sequence must leave `git st` plus a newline and no
# suggestion; Ctrl+C then abandons the line before the next sequence.
SHIFT_ENTER_DRIVER="$TMP_ROOT/shift-enter.zsh"
cat >"$SHIFT_ENTER_DRIVER" <<'EOF'
zmodload zsh/zpty || exit 1
home=$1 log=$1/probe.log last=
zpty -b sh "HOME=${(q)home} ZDOTDIR=${(q)home} EDITOR=nvim TERM=xterm zsh -i"

# Wait until the line editor last redrew with state $1, or give up after ~10s.
await() {
  local i chunk lines
  for i in {1..200}; do
    while zpty -r sh chunk; do :; done
    [[ -s $log ]] && lines=(${(f)"$(<$log)"}) && last=$lines[-1]
    [[ $last == "$1" ]] && return 0
    sleep 0.05
  done
  print -r -- "expected $1, got $last"
  zpty -d sh
  exit 1
}

await '[][]'
for seq in $'\e[27;2;13~' $'\e[13;2u'; do
  zpty -w -n sh 'git st'
  await '[git st][atus]'
  zpty -w -n sh $seq
  await '[git st<NL>][]'
  zpty -w -n sh $'\C-c'
  await '[][]'
done
zpty -d sh
EOF

probe_profile() {
  local profile=$1 files home out
  files=$(nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$profile\".config.home-files") \
    || fail "$profile: home-files build failed"
  [ -e "$files/.zshrc" ] || fail "$profile: generated .zshrc missing"

  home="$TMP_ROOT/$profile"
  mkdir -p "$home"
  # The generated .zshrc hard-codes HISTFILE; keep history in the scratch HOME.
  # `_probe-state` logs the line editor state when a line starts and on every
  # redraw. It sends no keys: zsh-autosuggestions skips fetching while input
  # is queued. Suggestions are fetched synchronously so each one lands before
  # the redraw the probe sees; async results skip the pre-redraw hook.
  {
    cat "$files/.zshrc"
    cat <<'EOF'
HISTFILE="$HOME/.zsh_history"
unset ZSH_AUTOSUGGEST_USE_ASYNC
_probe-state() { print -r -- "[${BUFFER//$'\n'/<NL>}][$POSTDISPLAY]" >>"$HOME/probe.log" }
zle -N _probe-state
autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-init _probe-state
add-zle-hook-widget line-pre-redraw _probe-state
EOF
  } >"$home/.zshrc"
  [ -e "$files/.zshenv" ] && cp -L "$files/.zshenv" "$home/.zshenv"
  printf 'git status\n' >"$home/.zsh_history"

  # EDITOR=nvim is what used to flip zle into vi-insert mode; keep it set.
  out=$(HOME="$home" ZDOTDIR="$home" EDITOR=nvim TERM=xterm zsh -i -c '
      bindkey -lL main
      printf "WORDCHARS=[%s]\n" "$WORDCHARS"
      for k in "^H" "^[[127;5u" "^[[3;5~" "^[[3~" "^[[27;2;13~" "^[[13;2u" "^?"; do
        bindkey -M main "$k"
      done
    ' </dev/null 2>&1)

  assert_contains "$out" "bindkey -A emacs main" "$profile: main keymap is emacs"
  assert_contains "$out" "WORDCHARS=[]" "$profile: WORDCHARS is empty"
  assert_contains "$out" '"^H" backward-kill-word' "$profile: ^H is backward-kill-word"
  assert_contains "$out" '"^[[127;5u" backward-kill-word' "$profile: CSI 127;5u is backward-kill-word"
  assert_contains "$out" '"^[[3;5~" kill-word' "$profile: Ctrl+Delete is kill-word"
  assert_contains "$out" '"^[[3~" delete-char' "$profile: Delete is delete-char"
  assert_contains "$out" '"^[[27;2;13~" insert-newline' "$profile: Shift+Enter (modifyOtherKeys) inserts a newline"
  assert_contains "$out" '"^[[13;2u" insert-newline' "$profile: Shift+Enter (CSI-u) inserts a newline"
  assert_contains "$out" '"^?" backward-delete-char' "$profile: Backspace deletes one character"
  pass "$profile: zsh keymap, bindings and WORDCHARS"

  out=$(zsh -f "$SHIFT_ENTER_DRIVER" "$home" 2>&1) \
    || fail "$profile: Shift+Enter leaves no stale autosuggestion ($out)"
  pass "$profile: Shift+Enter inserts a newline and clears the autosuggestion"
}

probe_profile "dev@$SYSTEM"
probe_profile "node@container-$SYSTEM"

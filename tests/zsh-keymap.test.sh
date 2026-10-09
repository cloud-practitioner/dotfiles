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
#   onto the new line;
# - Windows-style cursor keys: every xterm modified arrow/Home/End sequence
#   (`ESC [ 1 ; <mod> <A-D,H,F>`, mod 2..8, which is what Windows Terminal and
#   Herdr send for Shift/Alt/Ctrl), and the Home/End forms
#   resolve to the intended widget (Ctrl/Alt+Left/Right by word, Shift+Left/
#   Right by character), and typing each one into a real line editor inserts
#   no text and leaves the cursor where that widget puts it.
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

# Drives `zsh -i` in a pseudo-terminal against the scratch HOME given as $1.
# $2 is a table with one `<sequence><TAB><expected>` line per key, the sequence
# in zsh escape form and expected as `BUFFER|CURSOR`. Per key it types
# `ab cd-ef gh`, sends the sequence, then Ctrl-X Ctrl-P, which records
# `BUFFER|CURSOR` in arrows.log. WORDCHARS is empty, so `-` ends a word.
ARROW_DRIVER="$TMP_ROOT/arrows.zsh"
cat >"$ARROW_DRIVER" <<'EOF'
zmodload zsh/zpty || exit 1
home=$1 table=$2 log=$1/arrows.log rc=0
zpty -b sh "HOME=${(q)home} ZDOTDIR=${(q)home} EDITOR=nvim TERM=xterm zsh -i"
sleep 1

# Wait ~10s for arrows.log to hold $1.
await_state() {
  local i chunk
  for i in {1..200}; do
    while zpty -r -t sh chunk; do :; done
    [[ -s $log && "$(<$log)" == "$1" ]] && return 0
    sleep 0.05
  done
  return 1
}

for line in ${(f)"$(<$table)"}; do
  fields=("${(@s:	:)line}")
  : >$log
  zpty -w -n sh 'ab cd-ef gh'
  sleep 0.1
  zpty -w -n sh "${(g::)fields[1]}"
  sleep 0.1
  zpty -w -n sh $'\C-x\C-p'
  if ! await_state "$fields[2]"; then
    print -r -- "${fields[1]}: expected $fields[2], got $(<$log)"
    rc=1
  fi
  # Back to an empty new line (Ctrl-X Ctrl-R; Ctrl-C would make zsh drop
  # typeahead) and wait until the editor reports an empty buffer.
  zpty -w -n sh $'\C-x\C-r\C-x\C-p'
  await_state '|0' || { print -r -- "line not cleared after ${fields[1]}"; rc=1; }
done
zpty -d sh
exit $rc
EOF

# Checks the arrow, Home and End sequences of the Windows-style cursor keys in
# profile $1 (scratch HOME $2): first the widget each is bound to, then the
# effect of typing it. Up/Down fall back to history here (`git status`), so the
# plain-key result is the expectation for every modifier.
check_cursor_keys() {
  local profile=$1 home=$2 out table="$TMP_ROOT/arrow-table" m seq left right
  local tab=$'\t' text=$'ab cd-ef gh'

  out=$(HOME="$home" ZDOTDIR="$home" EDITOR=nvim TERM=xterm zsh -i -c '
      for m in {2..8}; do
        for c in D C A B H F; do bindkey -M main "^[[1;$m$c"; done
      done
      for k in "^[[H" "^[OH" "^[[1~" "^[[7~" "^[[F" "^[OF" "^[[4~" "^[[8~"; do
        bindkey -M main "$k"
      done
    ' </dev/null 2>&1)
  for m in {2..8}; do
    left=backward-char right=forward-char
    if (( ((m - 1) & 6) != 0 )); then left=backward-word right=forward-word; fi
    assert_contains "$out" "\"^[[1;${m}D\" $left" "$profile: ESC[1;${m}D is $left"
    assert_contains "$out" "\"^[[1;${m}C\" $right" "$profile: ESC[1;${m}C is $right"
    assert_contains "$out" "\"^[[1;${m}A\" up-line-or-history" "$profile: ESC[1;${m}A is up-line-or-history"
    assert_contains "$out" "\"^[[1;${m}B\" down-line-or-history" "$profile: ESC[1;${m}B is down-line-or-history"
    assert_contains "$out" "\"^[[1;${m}H\" beginning-of-line" "$profile: ESC[1;${m}H is beginning-of-line"
    assert_contains "$out" "\"^[[1;${m}F\" end-of-line" "$profile: ESC[1;${m}F is end-of-line"
  done
  for seq in '^[[H' '^[OH' '^[[1~' '^[[7~'; do
    assert_contains "$out" "\"$seq\" beginning-of-line" "$profile: $seq is beginning-of-line"
  done
  for seq in '^[[F' '^[OF' '^[[4~' '^[[8~'; do
    assert_contains "$out" "\"$seq\" end-of-line" "$profile: $seq is end-of-line"
  done
  pass "$profile: modified arrows and Home/End are bound to the intended widgets"

  # `ab cd-ef gh`, cursor at the end (11): a word move lands on `gh` (9), a
  # character move on `h` (10). Up replaces the line with the history entry
  # `git status`; Down at the newest entry leaves the line alone.
  {
    for m in {2..8}; do
      if (( ((m - 1) & 6) != 0 )); then left=9 right=11; else left=10 right=11; fi
      printf '%s\t%s\n' "\\e[1;${m}D" "$text|$left" "\\e[1;${m}C" "$text|$right" \
        "\\e[1;${m}A" "git status|10" "\\e[1;${m}B" "$text|11" \
        "\\e[1;${m}H" "$text|0" "\\e[1;${m}F" "$text|11"
    done
    for seq in '\e[H' '\eOH' '\e[1~' '\e[7~'; do printf '%s\t%s\n' "$seq" "$text|0"; done
    for seq in '\e[F' '\eOF' '\e[4~' '\e[8~'; do printf '%s\t%s\n' "$seq" "$text|11"; done
  } >"$table"
  out=$(zsh -f "$ARROW_DRIVER" "$home" "$table" 2>&1) \
    || fail "$profile: cursor keys moved wrongly or inserted text:
$out"
  pass "$profile: cursor keys insert no stray text and move the cursor as intended"
}

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

  cat >>"$home/.zshrc" <<'EOF'
_probe-cursor() { print -r -- "$BUFFER|$CURSOR" >"$HOME/arrows.log" }
# Leave history navigation and empty the line, as a fresh prompt would be.
_probe-reset() { HISTNO=$HISTCMD; BUFFER=; CURSOR=0 }
zle -N _probe-cursor
zle -N _probe-reset
bindkey '^X^P' _probe-cursor
bindkey '^X^R' _probe-reset
EOF

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

  check_cursor_keys "$profile" "$home"
}

probe_profile "dev@$SYSTEM"
probe_profile "node@container-$SYSTEM"

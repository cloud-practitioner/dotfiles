#!/usr/bin/env bash
# Behavioral checks for the zsh ssh-agent key autoload in home.nix.
#
# Builds each Linux home profile's generated files into the Nix store (never
# activating them), then starts an interactive zsh against the generated
# .zshenv and .zshrc with a scratch HOME. The scratch HOME holds throwaway keys
# at the three aliased paths, and a throwaway ssh-agent listens where the
# ssh-agent service puts its socket ($XDG_RUNTIME_DIR/ssh-agent). An ssh-add
# shim on the shell's PATH logs each call before running the real ssh-add.
#
# Coverage:
# - workstation, no agent running: no key is added;
# - workstation, empty agent: all three keys are loaded;
# - workstation, agent already holding a key: the agent is left alone;
# - workstation, Ctrl+C at a passphrase prompt: ssh-add is cancelled and the
#   rest of .zshrc still runs;
# - container, empty agent: no key is added.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in nix zsh ssh-agent ssh-add ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

dotfiles_test_tmproot ssh-agent-autoload
SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
KEYS=(id_ed25519_gh_work id_ed25519_gh_personal id_ed25519_bb_work)

AGENT_PID=
cleanup() {
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  dotfiles_test_cleanup
}
trap cleanup EXIT

# Keep the runner's own agent out of reach: the generated .zshenv keeps an
# inherited SSH_AUTH_SOCK inside an SSH session. Passphrase prompts go to the
# terminal, never to an askpass program.
unset SSH_AUTH_SOCK SSH_CONNECTION SSH_AGENT_PID SSH_ASKPASS SSH_ASKPASS_REQUIRE
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
mkdir -m 700 "$XDG_RUNTIME_DIR" || fail "create scratch XDG_RUNTIME_DIR"

mkdir "$TMP_ROOT/keys" || fail "create key dir"
for k in "${KEYS[@]}"; do
  ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$TMP_ROOT/keys/$k" \
    || fail "generate throwaway key $k"
done

SHIM_LOG="$TMP_ROOT/ssh-add.log"
mkdir "$TMP_ROOT/bin" || fail "create shim dir"
cat >"$TMP_ROOT/bin/ssh-add" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$SHIM_LOG"
exec "$(command -v ssh-add)" "\$@"
EOF
chmod +x "$TMP_ROOT/bin/ssh-add"

# Drives `zsh -i` in a pseudo-terminal against the scratch HOME given as $1 and
# presses Ctrl+C at the first passphrase prompt, then waits up to ~10s for
# .zshrc to reach its end.
CTRL_C_DRIVER="$TMP_ROOT/ctrl-c.zsh"
cat >"$CTRL_C_DRIVER" <<'EOF'
zmodload zsh/zpty || exit 1
home=$1 out= chunk=
zpty -b sh "HOME=${(q)home} ZDOTDIR=${(q)home} TERM=xterm zsh -i -c exit"
for i in {1..200}; do
  while zpty -r sh chunk; do out+=$chunk; done
  [[ $out == *'Enter passphrase'* ]] && break
  sleep 0.05
done
if [[ $out != *'Enter passphrase'* ]]; then
  print -r -- "no passphrase prompt, got: $out"
  zpty -d sh
  exit 1
fi
zpty -w -n sh $'\C-c'
for i in {1..200}; do
  [[ -e $home/rc-finished ]] && break
  sleep 0.05
done
zpty -d sh
EOF

# Sorted SHA256 fingerprints of the named throwaway keys, or of the agent's.
key_fingerprints() {
  local k
  for k; do ssh-keygen -lf "$TMP_ROOT/keys/$k.pub" | awk '{print $2}'; done | sort
}
agent_fingerprints() {
  local out
  out=$(ssh-add -l 2>/dev/null) || return 0
  printf '%s\n' "$out" | awk '{print $2}' | sort
}

# Builds profile $1's generated files and lays them out, with the keys, in a
# scratch HOME whose path is stored in PROFILE_HOME.
profile_home() {
  local profile=$1 files
  files=$(nix build --no-link --print-out-paths \
    "$ROOT#homeConfigurations.\"$profile\".config.home-files") \
    || fail "$profile: home-files build failed"
  [ -e "$files/.zshrc" ] || fail "$profile: generated .zshrc missing"

  PROFILE_HOME="$TMP_ROOT/$profile"
  mkdir -p "$PROFILE_HOME/.ssh"
  chmod 700 "$PROFILE_HOME/.ssh"
  cp -p "$TMP_ROOT/keys/"* "$PROFILE_HOME/.ssh/"
  # The generated .zshrc hard-codes HISTFILE; keep history in the scratch HOME.
  # rc-finished marks that the whole generated .zshrc ran.
  {
    cat "$files/.zshrc"
    cat <<'EOF'
HISTFILE="$HOME/.zsh_history"
: >"$HOME/rc-finished"
EOF
  } >"$PROFILE_HOME/.zshrc"
  [ -e "$files/.zshenv" ] && cp -L "$files/.zshenv" "$PROFILE_HOME/.zshenv"
}

# Runs an interactive zsh against the scratch HOME $1 until .zshrc has run.
start_shell() {
  : >"$SHIM_LOG"
  HOME="$1" ZDOTDIR="$1" PATH="$TMP_ROOT/bin:$PATH" TERM=xterm \
    zsh -i -c exit </dev/null >/dev/null 2>&1
}

assert_no_key_added() {
  assert_not_contains "$(cat "$SHIM_LOG")" "/.ssh/id_ed25519" "$1"
}

WS="dev@$SYSTEM"
profile_home "$WS"
ws_home=$PROFILE_HOME

start_shell "$ws_home"
[ -s "$SHIM_LOG" ] || fail "$WS: ssh-add shim is on the shell's PATH"
assert_no_key_added "$WS: no agent running, no key is added"
pass "$WS: no agent running is a no-op"

agent_env=$(ssh-agent -a "$SSH_AUTH_SOCK" -s) || fail "start throwaway ssh-agent"
eval "$agent_env" >/dev/null
AGENT_PID=$SSH_AGENT_PID
ssh-add -l >/dev/null 2>&1
[ "$?" = 1 ] || fail "throwaway agent is reachable and empty"

start_shell "$ws_home"
[ "$(agent_fingerprints)" = "$(key_fingerprints "${KEYS[@]}")" ] \
  || fail "$WS: empty agent gets all three keys"
pass "$WS: empty agent gets all three keys"

ssh-add -D >/dev/null 2>&1 || fail "empty the throwaway agent"
ssh-add "$TMP_ROOT/keys/id_ed25519_gh_work" >/dev/null 2>&1 || fail "preload one key"
start_shell "$ws_home"
[ "$(agent_fingerprints)" = "$(key_fingerprints id_ed25519_gh_work)" ] \
  || fail "$WS: agent holding a key keeps exactly that key"
assert_no_key_added "$WS: agent holding a key, no key is added"
pass "$WS: agent already holding a key is left alone"

ssh-add -D >/dev/null 2>&1 || fail "empty the throwaway agent"
ssh-keygen -p -q -P '' -N 'throwaway passphrase' -f "$ws_home/.ssh/id_ed25519_gh_work" \
  >/dev/null || fail "put a passphrase on one key"
rm -f "$ws_home/rc-finished"
out=$(zsh -f "$CTRL_C_DRIVER" "$ws_home" 2>&1) \
  || fail "$WS: passphrase prompt shows in the terminal ($out)"
[ -z "$(agent_fingerprints)" ] || fail "$WS: Ctrl+C at the passphrase prompt cancels ssh-add"
[ -e "$ws_home/rc-finished" ] || fail "$WS: Ctrl+C at the passphrase prompt, the rest of .zshrc runs"
pass "$WS: Ctrl+C at a passphrase prompt cancels only ssh-add"

CT="node@container-$SYSTEM"
profile_home "$CT"
ssh-add -D >/dev/null 2>&1 || fail "empty the throwaway agent"
start_shell "$PROFILE_HOME"
[ -z "$(agent_fingerprints)" ] || fail "$CT: empty agent stays empty"
assert_no_key_added "$CT: no key is added"
pass "$CT: empty agent stays empty"

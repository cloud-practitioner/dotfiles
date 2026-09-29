#!/usr/bin/env bash
# Behavior checks for the unpinned agent CLIs Home Manager installs at switch
# time on Linux (tools/node-tools.sh, run by home.nix's nodeTools activation):
# on the WSL2 workstation nvm, Node.js LTS as nvm's default, and pnpm; in both
# profiles Pi and the GitHub Copilot CLI from pnpm and Claude Code from its
# native installer, all unpinned.
#
# nvm, its install script, npm, pnpm, and Claude Code's install script are
# local fakes that log what they are asked to do, so nothing is downloaded.
# Like the real ones, the fake nvm.sh is not errexit/nounset clean, the fake
# pnpm refuses global commands while its global bin directory is off PATH, and
# the fake Claude Code installer puts its launcher in ~/.local/bin.
#
# Coverage:
# - workstation, fresh HOME: nvm from its install script with PROFILE=/dev/null
#   (no rc file touched), `nvm install --lts` as nvm's default, pnpm, the two
#   exact pnpm installs, then Claude Code's installer, with $NVM_DIR/default
#   linked to nvm's default Node.js; a re-run installs nothing and prints
#   nothing;
# - container: only the pnpm installs, on the pnpm already on PATH, and Claude
#   Code's installer; without pnpm, or offline, the script fails with one
#   clear message;
# - a Claude Code that does not answer --version after its installer fails
#   the run;
# - both profiles' nodeTools activation runs after writeBoundary with the
#   right mode, only warns on failure so the switch completes, and the
#   container activation keeps the user's PATH for the image's pnpm;
# - the workstation's interactive zsh puts nvm's node, npm, and pnpm first on
#   PATH; in both profiles every zsh (interactive or not) and a bash login
#   shell, fresh or started from an environment that already marks the
#   session variables sourced without PNPM_HOME or NVM_DIR, find ~/.local/bin
#   (claude) and pnpm's global bin (pi, copilot) right after
#   ~/.nix-profile/bin (herdr), once and ahead of system and Windows-interop
#   copies, with no empty PATH entry, and on the workstation also nvm's
#   default Node.js bin ($NVM_DIR/default/bin) between them; the container
#   never puts nvm on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot node-tools
FAKE_NODE=v24.99.0
PI_ADD="pnpm add -g --ignore-scripts @earendil-works/pi-coding-agent"
COPILOT_ADD="pnpm add -g @github/copilot"
CLAUDE_INSTALL="claude-installer"
export NODE_TOOLS_LOG="$TMP_ROOT/calls.log"
unset NVM_DIR NVM_BIN NVM_INC PNPM_HOME XDG_DATA_HOME NPM_CONFIG_PREFIX

# --- fakes --------------------------------------------------------------------

FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX/pnpm-only"

# A stand-in for nvm's install script: installs the fake nvm.sh into $NVM_DIR
# (as the real one does, it needs the directory to exist) and records PROFILE.
cat >"$FIX/install.sh" <<EOF
set -e
printf 'nvm-installer PROFILE=%s\n' "\${PROFILE-unset}" >>"\$NODE_TOOLS_LOG"
[ -d "\$NVM_DIR" ]
cp "$FIX/nvm.sh" "\$NVM_DIR/nvm.sh"
EOF

cat >"$FIX/nvm.sh" <<EOF
# Fake nvm: Node.js $FAKE_NODE is the only LTS.
nvm() {
  local bin="\$NVM_DIR/versions/node/$FAKE_NODE/bin"
  case "\$1 \${2-}" in
    "version default")
      if [ -f "\$NVM_DIR/alias/default" ] && [ -x "\$bin/node" ]; then
        echo $FAKE_NODE
      else
        echo N/A
        return 3
      fi
      ;;
    "install --lts")
      echo "nvm \$*" >>"\$NODE_TOOLS_LOG"
      mkdir -p "\$bin"
      cp "$FIX/npm" "\$bin/npm"
      printf '#!/bin/sh\necho $FAKE_NODE\n' >"\$bin/node"
      chmod +x "\$bin/npm" "\$bin/node"
      ;;
    "alias default")
      echo "nvm alias default \$3" >>"\$NODE_TOOLS_LOG"
      mkdir -p "\$NVM_DIR/alias"
      echo "\$3" >"\$NVM_DIR/alias/default"
      ;;
    "use --silent")
      [ -x "\$bin/node" ] || return 3
      PATH="\$bin:\$PATH"
      export PATH
      ;;
    *)
      echo "fake nvm: unexpected: \$*" >&2
      return 1
      ;;
  esac
}
# Like the real nvm.sh: unset variables and failing commands are fine here.
[ -n "\$NVM_FAKE_UNSET" ] || false
if [ "\${1-}" != --no-use ] && [ -f "\$NVM_DIR/alias/default" ]; then
  nvm use --silent default
fi
EOF

# A fake npm in nvm's layout; `npm install -g pnpm` installs the fake pnpm.
cat >"$FIX/npm" <<EOF
#!/bin/sh
prefix=\$(cd "\$(dirname "\$0")/.." && pwd)
case "\$1 \$2 \$3" in
  "prefix -g ") echo "\$prefix" ;;
  "install -g pnpm")
    echo "npm \$*" >>"\$NODE_TOOLS_LOG"
    cp "$FIX/pnpm" "\$prefix/bin/pnpm"
    ;;
  *) echo "fake npm: unexpected: \$*" >&2; exit 1 ;;
esac
EOF

# A fake pnpm 11+: global bins go to $PNPM_HOME/bin, which must be on PATH.
cat >"$FIX/pnpm" <<'EOF'
#!/bin/sh
bin="$PNPM_HOME/bin"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "ERR_PNPM_GLOBAL_BIN_DIR_NOT_IN_PATH: $bin" >&2; exit 1 ;;
esac
[ -z "${PNPM_FAKE_OFFLINE:-}" ] || [ "$1" != add ] || { echo "ERR_PNPM_FETCH offline" >&2; exit 1; }
case "$1 $2" in
  "bin -g") echo "$bin" ;;
  "add -g")
    echo "pnpm $*" >>"$NODE_TOOLS_LOG"
    shift 2
    for arg; do package=$arg; done
    case "$package" in
      @earendil-works/pi-coding-agent) name=pi ;;
      @github/copilot) name=copilot ;;
      *) echo "fake pnpm: unexpected package $package" >&2; exit 1 ;;
    esac
    mkdir -p "$bin"
    printf '#!/bin/sh\necho %s-fake\n' "$name" >"$bin/$name"
    chmod +x "$bin/$name"
    ;;
  *) echo "fake pnpm: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FIX/npm" "$FIX/pnpm"
cp "$FIX/pnpm" "$FIX/pnpm-only/pnpm"

# A stand-in for Claude Code's install script: like the real one, it puts the
# launcher at ~/.local/bin/claude, pointing into the versions directory.
cat >"$FIX/claude-install.sh" <<'EOF'
set -e
echo claude-installer >>"$NODE_TOOLS_LOG"
versions="${XDG_DATA_HOME:-$HOME/.local/share}/claude/versions"
mkdir -p "$versions" "$HOME/.local/bin"
printf '#!/bin/sh\necho claude-fake\n' >"$versions/9.9.9"
chmod +x "$versions/9.9.9"
ln -sfn "$versions/9.9.9" "$HOME/.local/bin/claude"
EOF

export NVM_INSTALL_URL="file://$FIX/install.sh"
export CLAUDE_INSTALL_URL="file://$FIX/claude-install.sh"
BASE_PATH="/usr/bin:/bin"

# Runs tools/node-tools.sh $2 against scratch HOME $1 with PATH $3.
run_tools() {
  HOME=$1 PATH=$3 bash "$ROOT/tools/node-tools.sh" "$2" 2>&1
}

calls() {
  cat "$NODE_TOOLS_LOG" 2>/dev/null
}

INSTALLS="$PI_ADD
$COPILOT_ADD
$CLAUDE_INSTALL"

# --- tools/node-tools.sh --------------------------------------------------------

test_workstation_fresh_then_quiet() {
  local home="$TMP_ROOT/ws" out bin
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "workstation on a fresh HOME failed: $out"
  [ "$(calls)" = "nvm-installer PROFILE=/dev/null
nvm install --lts --no-progress
nvm alias default lts/*
npm install -g pnpm
$INSTALLS" ] || fail "workstation did not install nvm, Node.js LTS as default, pnpm, the pnpm tools, then Claude Code, in order: $(calls)"
  bin="$home/.local/share/pnpm/bin"
  for tool in pi copilot; do
    [ "$("$bin/$tool" --version)" = "$tool-fake" ] || fail "$tool does not run from pnpm's global bin"
  done
  [ ! -e "$bin/claude" ] || fail "workstation installed Claude Code with pnpm"
  [ "$("$home/.local/bin/claude" --version)" = claude-fake ] || fail "claude does not run from ~/.local/bin"
  [ "$("$home/.nvm/default/bin/node")" = "$FAKE_NODE" ] || fail "\$NVM_DIR/default is not nvm's default Node.js"
  for rc in .bashrc .bash_profile .profile .zshrc .zprofile; do
    [ ! -e "$home/$rc" ] || fail "the nvm installer wrote $rc, which Home Manager owns"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "workstation re-run failed: $out"
  [ -z "$(calls)" ] || fail "a workstation re-run reinstalled something: $(calls)"
  [ -z "$out" ] || fail "a workstation re-run is not quiet: $out"
  pass "workstation: nvm (PROFILE=/dev/null), Node.js LTS as default, pnpm, Pi and Copilot from pnpm, then Claude Code from its installer; re-runs install and print nothing"
}

test_container_and_failures() {
  local home="$TMP_ROOT/ct" out
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/pnpm-only:$BASE_PATH") \
    || fail "container with pnpm on PATH failed: $out"
  [ "$(calls)" = "$INSTALLS" ] || fail "container did not only run the two pnpm installs and Claude Code's installer: $(calls)"
  [ -x "$home/pnpm-home/bin/pi" ] || fail "container ignored the image's PNPM_HOME"
  [ -x "$home/.local/bin/claude" ] || fail "container did not install Claude Code into ~/.local/bin"
  [ ! -e "$home/.nvm" ] || fail "container installed nvm"

  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/pnpm-only:$BASE_PATH") \
    || fail "container re-run failed: $out"
  [ -z "$(calls)$out" ] || fail "a container re-run was not a quiet no-op: $(calls) $out"

  if out=$(run_tools "$TMP_ROOT/ct-nopnpm" container "$BASE_PATH"); then
    fail "container without pnpm succeeded: $out"
  fi
  assert_contains "$out" "pnpm not found on PATH" "missing pnpm is not reported clearly: $out"

  if out=$(PNPM_FAKE_OFFLINE=1 run_tools "$TMP_ROOT/ct-offline" container "$FIX/pnpm-only:$BASE_PATH"); then
    fail "container offline succeeded: $out"
  fi
  assert_contains "$out" "$PI_ADD failed (offline?)" "an offline pnpm install is not reported clearly: $out"

  if out=$(NVM_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_tools "$TMP_ROOT/ws-offline" workstation "$BASE_PATH"); then
    fail "workstation without the nvm install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install nvm" "a failed nvm download is not reported: $out"

  if out=$(CLAUDE_INSTALL_URL="file://$TMP_ROOT/missing.sh" PNPM_HOME="$TMP_ROOT/ct-noclaude/pnpm" \
    run_tools "$TMP_ROOT/ct-noclaude" container "$FIX/pnpm-only:$BASE_PATH"); then
    fail "container without Claude Code's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install Claude Code" "a failed Claude Code download is not reported: $out"
  pass "container: only the pnpm installs, on the image's pnpm, and Claude Code's installer; no pnpm or no network fails with one clear message"
}

test_claude_must_run() {
  local home="$TMP_ROOT/claude-broken" out
  mkdir -p "$home"
  # An installer that leaves a launcher which cannot run.
  cat >"$FIX/claude-broken.sh" <<'EOF'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexit 1\n' >"$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
EOF
  if out=$(CLAUDE_INSTALL_URL="file://$FIX/claude-broken.sh" PNPM_HOME="$home/pnpm" \
    run_tools "$home" container "$FIX/pnpm-only:$BASE_PATH"); then
    fail "a claude that does not run was accepted: $out"
  fi
  assert_contains "$out" "claude --version fails after" "a broken claude is not reported: $out"
  pass "a CLI that does not answer --version after it is installed fails the run"
}

# --- Home Manager ---------------------------------------------------------------

have_linux_nix() {
  if [ "$(uname -s)" != Linux ] || ! command -v nix >/dev/null 2>&1; then
    echo "skip: needs Nix on Linux"
    return 1
  fi
}

SYSTEM=
WS=
CT=
profiles_init() {
  [ -n "$SYSTEM" ] && return 0
  SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
  WS="dev@$SYSTEM"
  CT="node@container-$SYSTEM"
}

hm_eval() {
  nix eval "$@" 2>/dev/null
}

# Runs profile $1's nodeTools activation snippet the way the activation script
# does (HM's run and warnEcho, errexit), with scratch HOME $2 and PATH $3.
run_activation() {
  local profile=$1 home=$2 path=$3 snippet
  snippet=$(hm_eval --raw "$ROOT#homeConfigurations.\"$profile\".config.home.activation.nodeTools.data") \
    || fail "$profile: no nodeTools activation"
  HOME=$home PATH=$path bash -c '
    set -eu -o pipefail
    run() { "$@"; }
    warnEcho() { echo "WARN: $*"; }
    eval "$1"
    echo "switch continues"' _ "$snippet" 2>&1
}

test_activation() {
  local out after empty home
  have_linux_nix || return 0
  profiles_init
  # Realize the activation's tool PATH.
  nix build --no-link "$ROOT#homeConfigurations.\"$WS\".activationPackage" \
    "$ROOT#homeConfigurations.\"$CT\".activationPackage" 2>/dev/null || fail "activation packages do not build"
  for profile in "$WS" "$CT"; do
    after=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.activation.nodeTools.after")
    [ "$after" = '["writeBoundary"]' ] || fail "$profile: nodeTools does not run after writeBoundary: $after"
    empty=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.emptyActivationPath")
    case "$profile" in
      *@container-*) [ "$empty" = false ] || fail "$profile: activation drops the image's PATH" ;;
      *) [ "$empty" = true ] || fail "$profile: workstation activation inherits the user's PATH" ;;
    esac
  done

  home="$TMP_ROOT/act-ws"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(run_activation "$WS" "$home" "$BASE_PATH") || fail "$WS: activation failed: $out"
  assert_not_contains "$out" "WARN" "$WS: a working activation warns: $out"
  assert_contains "$(calls)" "nvm install --lts" "$WS: activation did not provision Node.js: $(calls)"
  assert_contains "$(calls)" "$CLAUDE_INSTALL" "$WS: activation did not install Claude Code: $(calls)"

  home="$TMP_ROOT/act-ct"
  mkdir -p "$home"
  out=$(PNPM_HOME="$home/pnpm" run_activation "$CT" "$home" "$BASE_PATH") \
    || fail "$CT: activation without pnpm failed the switch: $out"
  assert_contains "$out" "pnpm not found on PATH" "$CT: activation hides why it failed: $out"
  assert_contains "$out" "WARN: tools/node-tools.sh failed" "$CT: activation does not warn: $out"
  assert_contains "$out" "switch continues" "$CT: activation stopped the switch: $out"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_activation "$CT" "$home" "$FIX/pnpm-only:$BASE_PATH") \
    || fail "$CT: activation with the image's pnpm failed: $out"
  [ "$(calls)" = "$INSTALLS" ] || fail "$CT: activation did not use the image's pnpm: $(calls)"
  pass "nodeTools runs after writeBoundary in both profiles, uses the container's own pnpm, and only warns on failure"
}

# --- shells ---------------------------------------------------------------------

TOOLS="herdr node npm pnpm claude pi copilot"

# Checks shell $2's report $3 (NAME=first match, rawpath=PATH, then path=DIR lines) for
# profile $1 in scratch HOME $4: herdr is the Nix profile's, claude is the
# native launcher in ~/.local/bin, pi and copilot are pnpm's, node, npm, and
# pnpm are from $5 on the workstation, and ~/.local/bin, the nvm default bin
# (workstation), and the pnpm dirs sit right after ~/.nix-profile/bin, once
# each, and PATH has no empty entry.
check_shell() {
  local profile=$1 shell=$2 out=$3 home=$4 node_dir=${5-} tool dir front path
  local pnpm_home="$home/.local/share/pnpm"
  grep -qxF "herdr=$home/.nix-profile/bin/herdr" <<<"$out" || fail "$profile $shell: herdr is not the Nix profile's: $out"
  grep -qxF "claude=$home/.local/bin/claude" <<<"$out" || fail "$profile $shell: claude is not the native launcher: $out"
  for tool in pi copilot; do
    grep -qxF "$tool=$pnpm_home/bin/$tool" <<<"$out" || fail "$profile $shell: $tool is not pnpm's: $out"
  done
  front="$pnpm_home/bin:$pnpm_home"
  case "$profile" in
    *@container-*)
      assert_not_contains "$out" "$home/.nvm" "$profile $shell: the container puts nvm on PATH: $out"
      ;;
    *)
      for tool in node npm pnpm; do
        grep -qxF "$tool=$node_dir/$tool" <<<"$out" || fail "$profile $shell: $tool is not from $node_dir: $out"
      done
      front="$home/.nvm/default/bin:$front"
      ;;
  esac
  front="$home/.local/bin:$front"
  case "$(sed -n 's/^rawpath=//p' <<<"$out")" in
    "" | :* | *: | *::*) fail "$profile $shell: PATH is empty or has an empty entry: $out" ;;
  esac
  path=":$(sed -n 's/^path=//p' <<<"$out" | tr '\n' ':')"
  assert_contains "$path" ":$home/.nix-profile/bin:$front:" "$profile $shell: $front is not right after ~/.nix-profile/bin: $path"
  for dir in ${front//:/ }; do
    [ "$(grep -cxF "path=$dir" <<<"$out")" = 1 ] || fail "$profile $shell: $dir is not on PATH exactly once: $path"
  done
}

test_shell_path() {
  local files home out profile tool win start node_default
  have_linux_nix || return 0
  command -v zsh >/dev/null 2>&1 || { echo "skip: zsh not found"; return 0; }
  profiles_init
  # WSL appends the Windows PATH, which can hold extensionless npm shims.
  win="$TMP_ROOT/mnt/c/Users/dev/AppData/Roaming/npm"
  mkdir -p "$win"
  for tool in $TOOLS; do
    printf '#!/bin/sh\necho windows-%s\n' "$tool" >"$win/$tool"
    chmod +x "$win/$tool"
  done
  for profile in "$WS" "$CT"; do
    files=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".config.home-files" 2>/dev/null) \
      || fail "$profile: home-files build failed"
    home="$TMP_ROOT/sh-${profile//[@\/]/-}"
    mkdir -p "$home/.nix-profile/bin"
    printf '#!/bin/sh\necho herdr-fake\n' >"$home/.nix-profile/bin/herdr"
    chmod +x "$home/.nix-profile/bin/herdr"
    case "$profile" in
      *@container-*) PNPM_HOME="$home/.local/share/pnpm" run_tools "$home" container "$FIX/pnpm-only:$BASE_PATH" >/dev/null ;;
      *) run_tools "$home" workstation "$BASE_PATH" >/dev/null ;;
    esac || fail "$profile: could not lay out the fake tools"
    # shellcheck disable=SC2016 # expanded by the scratch zsh, not here
    { cat "$files/.zshrc"; echo 'HISTFILE="$HOME/.zsh_history"'; } >"$home/.zshrc"
    cp -L "$files/.zshenv" "$home/.zshenv"
    cp -L "$files/.bash_profile" "$home/.bash_profile"
    start="$home/.nix-profile/bin:$BASE_PATH:$win"
    node_default="$home/.nvm/default/bin"

    # A fresh environment, as a new terminal or `wsl.exe -e` gets, then one
    # from a process started before this config (a herdr or tmux server) that
    # marks Home Manager's session variables as sourced but has no PNPM_HOME
    # or NVM_DIR. zsh -d and bash --noprofile skip the host's global rc files
    # (a devcontainer's set their own NVM_DIR and PATH), leaving only the
    # generated ones; the bash login shell then reads ~/.bash_profile as it
    # would without them.
    for stale in "" "__HM_SESS_VARS_SOURCED=1 __HM_ZSH_SESS_VARS_SOURCED=1"; do
      # shellcheck disable=SC2016,SC2086 # expanded by the scratch zsh; $stale splits into assignments
      out=$(env -i $stale HOME="$home" ZDOTDIR="$home" TERM=xterm PATH="$start" zsh -d -i -c \
        'for c in '"$TOOLS"'; do print -r -- "$c=$(whence -p $c)"; done; print -r -- "rawpath=$PATH"; for p in $path; do print -r -- "path=$p"; done' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "interactive zsh${stale:+ ($stale)}" "$out" "$home" "$home/.nvm/versions/node/$FAKE_NODE/bin"
      # shellcheck disable=SC2016,SC2086 # expanded by the scratch zsh; $stale splits into assignments
      out=$(env -i $stale HOME="$home" ZDOTDIR="$home" PATH="$start" zsh -d -c \
        'for c in '"$TOOLS"'; do print -r -- "$c=$(whence -p $c)"; done; print -r -- "rawpath=$PATH"; for p in $path; do print -r -- "path=$p"; done' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "zsh -c${stale:+ ($stale)}" "$out" "$home" "$node_default"
      # shellcheck disable=SC2016,SC2086 # expanded by the scratch bash; $stale splits into assignments
      out=$(env -i $stale HOME="$home" PATH="$start" bash --noprofile -l -c \
        '. "$HOME/.bash_profile"; for c in '"$TOOLS"'; do echo "$c=$(type -P $c)"; done; echo "rawpath=$PATH"; IFS=:; for p in $PATH; do echo "path=$p"; done' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "bash login${stale:+ ($stale)}" "$out" "$home" "$node_default"
    done
  done
  pass "in both profiles every zsh and a bash login shell, fresh or from an environment that already sourced the session variables, run herdr from ~/.nix-profile/bin, then claude from ~/.local/bin and pi and copilot from pnpm, right after it and ahead of system and Windows copies, once each; the workstation adds nvm's default node, npm, and pnpm there, and its interactive zsh loads nvm"
}

test_workstation_fresh_then_quiet
test_container_and_failures
test_claude_must_run
test_activation
test_shell_path

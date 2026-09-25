#!/usr/bin/env bash
# Behavior checks for the Node.js-based CLIs Home Manager installs at switch
# time on Linux (tools/node-tools.sh, run by home.nix's nodeTools activation):
# on the WSL2 workstation nvm, Node.js LTS as nvm's default, and pnpm; in both
# profiles Claude Code, Pi, and the GitHub Copilot CLI, unpinned, from pnpm.
#
# nvm, its install script, npm, and pnpm are local fakes that log what they are
# asked to do, so nothing is downloaded. Like the real ones, the fake nvm.sh is
# not errexit/nounset clean, the fake pnpm refuses global commands while its
# global bin directory is off PATH, and the fake Claude Code only runs when
# its build script was allowed.
#
# Coverage:
# - workstation, fresh HOME: nvm from its install script with PROFILE=/dev/null
#   (no rc file touched), `nvm install --lts` as nvm's default, pnpm, then the
#   three exact pnpm installs; a re-run installs nothing and prints nothing;
# - container: only the pnpm installs, on the pnpm already on PATH; without
#   pnpm, or offline, the script fails with one clear message;
# - both profiles' nodeTools activation runs after writeBoundary with the
#   right mode, only warns on failure so the switch completes, and the
#   container activation keeps the user's PATH for the image's pnpm;
# - the workstation zsh puts nvm's node, npm, and pnpm first on PATH; both
#   profiles' zsh put pnpm's global bin (claude, pi, copilot) on PATH after
#   ~/.nix-profile/bin; the container zsh does not load nvm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot node-tools
FAKE_NODE=v24.99.0
PI_ADD="pnpm add -g --ignore-scripts @earendil-works/pi-coding-agent"
COPILOT_ADD="pnpm add -g @github/copilot"
CLAUDE_ADD="pnpm add -g --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code"
export NODE_TOOLS_LOG="$TMP_ROOT/calls.log"
unset NVM_DIR NVM_BIN NVM_INC PNPM_HOME XDG_DATA_HOME NODE_TOOLS_VERBOSE NPM_CONFIG_PREFIX

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
    runs=1
    for arg; do package=$arg; done
    case "$package" in
      @earendil-works/pi-coding-agent) name=pi ;;
      @github/copilot) name=copilot ;;
      @anthropic-ai/claude-code)
        name=claude
        case " $* " in *" --allow-build=@anthropic-ai/claude-code "*) ;; *) runs=0 ;; esac
        ;;
      *) echo "fake pnpm: unexpected package $package" >&2; exit 1 ;;
    esac
    mkdir -p "$bin"
    if [ "$runs" = 1 ]; then
      printf '#!/bin/sh\necho %s-fake\n' "$name" >"$bin/$name"
    else
      printf '#!/bin/sh\necho "claude native binary not installed" >&2\nexit 1\n' >"$bin/$name"
    fi
    chmod +x "$bin/$name"
    ;;
  *) echo "fake pnpm: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FIX/npm" "$FIX/pnpm"
cp "$FIX/pnpm" "$FIX/pnpm-only/pnpm"

export NVM_INSTALL_URL="file://$FIX/install.sh"
BASE_PATH="/usr/bin:/bin"

# Runs tools/node-tools.sh $2 against scratch HOME $1 with PATH $3.
run_tools() {
  HOME=$1 PATH=$3 bash "$ROOT/tools/node-tools.sh" "$2" 2>&1
}

calls() {
  cat "$NODE_TOOLS_LOG" 2>/dev/null
}

PNPM_ADDS="$PI_ADD
$COPILOT_ADD
$CLAUDE_ADD"

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
$PNPM_ADDS" ] || fail "workstation did not install nvm, Node.js LTS as default, pnpm, then the pnpm tools, in order: $(calls)"
  bin="$home/.local/share/pnpm/bin"
  for tool in claude pi copilot; do
    [ "$("$bin/$tool" --version)" = "$tool-fake" ] || fail "$tool does not run from pnpm's global bin"
  done
  for rc in .bashrc .bash_profile .profile .zshrc .zprofile; do
    [ ! -e "$home/$rc" ] || fail "the nvm installer wrote $rc, which Home Manager owns"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "workstation re-run failed: $out"
  [ -z "$(calls)" ] || fail "a workstation re-run reinstalled something: $(calls)"
  [ -z "$out" ] || fail "a workstation re-run is not quiet: $out"
  out=$(NODE_TOOLS_VERBOSE=1 run_tools "$home" workstation "$BASE_PATH") || fail "verbose re-run failed: $out"
  assert_contains "$out" "Node.js $FAKE_NODE is already nvm's default" "verbose re-run does not report the default Node.js: $out"
  assert_contains "$out" "claude already installed" "verbose re-run does not report claude: $out"
  pass "workstation: nvm (PROFILE=/dev/null), Node.js LTS as default, pnpm, then Claude Code, Pi, and Copilot from pnpm; re-runs install and print nothing"
}

test_container_and_failures() {
  local home="$TMP_ROOT/ct" out
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/pnpm-only:$BASE_PATH") \
    || fail "container with pnpm on PATH failed: $out"
  [ "$(calls)" = "$PNPM_ADDS" ] || fail "container did not only run the three pnpm installs: $(calls)"
  [ -x "$home/pnpm-home/bin/claude" ] || fail "container ignored the image's PNPM_HOME"
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
  pass "container: only the pnpm installs, on the image's pnpm; no pnpm or no network fails with one clear message"
}

test_claude_must_run() {
  local home="$TMP_ROOT/claude-broken" out
  mkdir -p "$home"
  # A pnpm that drops --allow-build leaves Claude Code without its native binary.
  mkdir -p "$FIX/no-allow"
  cat >"$FIX/no-allow/pnpm" <<EOF
#!/bin/sh
args=""
for a; do [ "\$a" = --allow-build=@anthropic-ai/claude-code ] || args="\$args \$a"; done
# shellcheck disable=SC2086
exec "$FIX/pnpm-only/pnpm" \$args
EOF
  chmod +x "$FIX/no-allow/pnpm"
  if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/no-allow:$BASE_PATH"); then
    fail "a claude that does not run was accepted: $out"
  fi
  assert_contains "$out" "claude --version fails after" "a broken claude is not reported: $out"
  pass "a pnpm-installed CLI that does not answer --version fails the run"
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
  local out mode after empty home
  have_linux_nix || return 0
  profiles_init
  # Realize the activation's tool PATH.
  nix build --no-link "$ROOT#homeConfigurations.\"$WS\".activationPackage" \
    "$ROOT#homeConfigurations.\"$CT\".activationPackage" 2>/dev/null || fail "activation packages do not build"
  for profile in "$WS" "$CT"; do
    after=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.activation.nodeTools.after")
    [ "$after" = '["writeBoundary"]' ] || fail "$profile: nodeTools does not run after writeBoundary: $after"
    empty=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.emptyActivationPath")
    out=$(hm_eval --raw "$ROOT#homeConfigurations.\"$profile\".config.home.activation.nodeTools.data")
    case "$profile" in
      *@container-*) mode=container; [ "$empty" = false ] || fail "$profile: activation drops the image's PATH" ;;
      *) mode=workstation; [ "$empty" = true ] || fail "$profile: workstation activation inherits the user's PATH" ;;
    esac
    assert_contains "$out" "node-tools.sh $mode;" "$profile: nodeTools does not run node-tools.sh $mode: $out"
  done

  home="$TMP_ROOT/act-ws"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(run_activation "$WS" "$home" "$BASE_PATH") || fail "$WS: activation failed: $out"
  assert_not_contains "$out" "WARN" "$WS: a working activation warns: $out"
  assert_contains "$(calls)" "nvm install --lts" "$WS: activation did not provision Node.js: $(calls)"
  assert_contains "$(calls)" "$CLAUDE_ADD" "$WS: activation did not install Claude Code: $(calls)"

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
  [ "$(calls)" = "$PNPM_ADDS" ] || fail "$CT: activation did not use the image's pnpm: $(calls)"
  pass "nodeTools runs after writeBoundary in both profiles, uses the container's own pnpm, and only warns on failure"
}

# --- zsh --------------------------------------------------------------------------

test_zsh_path() {
  local files home out profile nix_idx pnpm_idx
  have_linux_nix || return 0
  command -v zsh >/dev/null 2>&1 || { echo "skip: zsh not found"; return 0; }
  profiles_init
  for profile in "$WS" "$CT"; do
    files=$(nix build --no-link --print-out-paths "$ROOT#homeConfigurations.\"$profile\".config.home-files" 2>/dev/null) \
      || fail "$profile: home-files build failed"
    home="$TMP_ROOT/zsh-${profile//[@\/]/-}"
    mkdir -p "$home/.nix-profile/bin"
    case "$profile" in
      *@container-*) PNPM_HOME="$home/.local/share/pnpm" run_tools "$home" container "$FIX/pnpm-only:$BASE_PATH" >/dev/null ;;
      *) run_tools "$home" workstation "$BASE_PATH" >/dev/null ;;
    esac || fail "$profile: could not lay out the fake tools"
    # shellcheck disable=SC2016 # expanded by the scratch zsh, not here
    { cat "$files/.zshrc"; echo 'HISTFILE="$HOME/.zsh_history"'; } >"$home/.zshrc"
    [ -e "$files/.zshenv" ] && cp -L "$files/.zshenv" "$home/.zshenv"
    # -d skips the host's global rc files (a devcontainer's /etc/zsh/zshrc sets
    # its own NVM_DIR), leaving only the generated ones.
    # shellcheck disable=SC2016 # expanded by the scratch zsh, not here
    out=$(HOME=$home ZDOTDIR=$home TERM=xterm PATH="$home/.nix-profile/bin:$BASE_PATH" \
      zsh -d -i -c 'for c in node npm pnpm claude pi copilot; do print -r -- "$c=$(whence -p $c)"; done; print -rl -- $path' \
      </dev/null 2>/dev/null)
    for tool in claude pi copilot; do
      assert_contains "$out" "$tool=$home/.local/share/pnpm/bin/$tool" "$profile: $tool is not pnpm's: $out"
    done
    nix_idx=$(grep -nxF "$home/.nix-profile/bin" <<<"$out" | cut -d: -f1)
    pnpm_idx=$(grep -nxF "$home/.local/share/pnpm/bin" <<<"$out" | cut -d: -f1)
    [ -n "$nix_idx" ] && [ -n "$pnpm_idx" ] && [ "$nix_idx" -lt "$pnpm_idx" ] \
      || fail "$profile: pnpm's global bin is not after ~/.nix-profile/bin on PATH: $out"
    case "$profile" in
      *@container-*)
        assert_not_contains "$out" "$home/.nvm" "$profile: the container zsh loads nvm: $out"
        ;;
      *)
        for tool in node npm pnpm; do
          assert_contains "$out" "$tool=$home/.nvm/versions/node/$FAKE_NODE/bin/$tool" "$profile: $tool is not nvm's: $out"
        done
        ;;
    esac
  done
  pass "the workstation zsh loads nvm (node, npm, pnpm); both profiles put pnpm's claude, pi, and copilot on PATH after ~/.nix-profile/bin"
}

test_workstation_fresh_then_quiet
test_container_and_failures
test_claude_must_run
test_activation
test_zsh_path

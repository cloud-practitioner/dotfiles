#!/usr/bin/env bash
# Behavior checks for the toolchain Home Manager installs at switch time on
# Linux, unpinned, in two scripts that home.nix's nodeTools and bashTools
# activations run in that order:
# - tools/node-tools.sh: on the WSL2 workstation nvm, Node.js LTS as nvm's
#   default, and pnpm (the container uses its image's), then the pnpm globals,
#   the npm globals (yo, mbt, mta, and the generators), @sap/cf-tools-local
#   on amd64, and the agent skills;
# - tools/bash-tools.sh: herdr, Pi, the GitHub Copilot CLI, Claude Code, and
#   Antigravity from their own installers.
#
# nvm, its install script, npm, npx, pnpm, yo, mbt, mta, cf, and the herdr, Pi,
# Copilot, Claude Code, and Antigravity install scripts are local fakes that
# log what they are asked to do, so nothing is downloaded, except by the one
# check that runs herdr's real installer. Like the real ones, the fake nvm.sh
# is not errexit/nounset clean, the fake pnpm refuses global commands while its
# global bin directory is off PATH and global installs without a
# pnpm-workspace.yaml in its global directory, the fake yo only lists
# generators under npm's global prefix, the fake herdr installer puts herdr in
# $HERDR_INSTALL_DIR, the fake Pi installer refuses to replace a pi it did not
# install (pnpm's, or a Windows one under /mnt) and links ~/.local/bin/pi to
# its launcher in ~/.pi/agent/bin, the fake Copilot and Claude Code installers
# put their launchers in ~/.local/bin (Copilot's in $PREFIX/bin), and the fake
# Antigravity installer takes --dir, then, like the real one, appends a PATH
# export to the rc files in its HOME.
#
# Coverage:
# - workstation, fresh HOME: nvm from its install script with PROFILE=/dev/null
#   (no rc file touched), `nvm install --lts` as nvm's default, pnpm, then the
#   pnpm globals (with allowBuilds written first), the agent skills with
#   exactly the Dockerfile's arguments, the npm globals with
#   --allow-scripts=mbt,mta into nvm's prefix (found by yo, bins in
#   $NVM_DIR/default/bin), @sap/cf-tools-local on amd64, and one yo smoke
#   check; then bash-tools' five installers, each without a controlling
#   terminal where needed; a re-run of both installs and prints nothing;
# - only what is missing is installed again (a missing pnpm or npm global, a
#   missing skill group), and mattpocock's resolving-merge-conflicts always
#   follows its repo's install, so the pinned copy wins;
# - container: the image's own Node.js and pnpm, npm globals in
#   ~/.npm-global (or $NPM_CONFIG_PREFIX), no nvm; without pnpm node-tools
#   fails with one clear message while bash-tools still installs everything;
# - a failing pnpm, npm, or skills step is reported and fails the run but does
#   not stop the other steps; broken mbt, a generator yo does not list, and
#   a missing ServiceInfo cf plugin are warnings (the run still reports them
#   and installs everything);
# - a container that an older switch gave pnpm's Pi and Copilot, with a
#   Windows pi on PATH: Pi's installer runs without either on its PATH, and
#   each pnpm copy is removed right after its installer, so ~/.local/bin/pi
#   and ~/.local/bin/copilot are the only ones left; when Pi's installer
#   cannot be downloaded, pnpm's Pi stays;
# - a failing Pi installer shows its own output, fails the run, and keeps
#   pnpm's Pi;
# - a herdr, Claude Code, or Antigravity that does not answer --version after
#   its installer fails the run;
# - Antigravity's installer gets a scratch HOME and --dir ~/.local/bin: agy
#   lands in the real ~/.local/bin and no real rc file changes;
# - herdr's real installer (https://herdr.dev/install.sh, skipped offline)
#   installs herdr's latest release as ~/.local/bin/herdr, which accepts
#   home/.config/herdr/config.toml; a re-run is a quiet no-op;
# - both profiles' nodeTools and bashTools activations run in that order after
#   writeBoundary, only warn on failure so the switch completes, and the
#   container activation keeps the user's PATH for the image's pnpm;
# - the workstation's interactive zsh puts nvm's node, npm, and pnpm first on
#   PATH; in both profiles every zsh (interactive or not) and a bash login
#   shell, fresh or started from an environment that already marks the
#   session variables sourced without PNPM_HOME or NVM_DIR, find ~/.local/bin
#   (herdr, claude, pi, copilot, agy) and pnpm's global bin right before
#   ~/.nix-profile/bin, once and ahead of a Nix-built herdr left there and of
#   system and Windows-interop copies, with no empty PATH entry, and
#   between them the workstation's nvm default Node.js bin
#   ($NVM_DIR/default/bin, which is also npm's global bin) or the container's
#   npm global bin (~/.npm-global/bin); the container never puts nvm on PATH;
#   the interactive zsh loads the installed herdr's completions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_tmproot node-tools
FAKE_NODE=v24.99.0
PI_INSTALL="pi-installer tty=no"
COPILOT_INSTALL="copilot-installer tty=no"
HERDR_INSTALL="herdr-installer"
CLAUDE_INSTALL="claude-installer"
AGY_INSTALL="antigravity-installer tty=no dir=%HOME%/.local/bin"
PI_REMOVE="pnpm remove -g @earendil-works/pi-coding-agent"
COPILOT_REMOVE="pnpm remove -g @github/copilot"
export NODE_TOOLS_LOG="$TMP_ROOT/calls.log"
REAL_NODE=$(command -v node)
export REAL_NODE NODE_TOOLS_TEST_PATH=$PATH
REAL_PNPM=$(command -v pnpm)
export REAL_PNPM
[ -n "$REAL_NODE" ] && [ -n "$REAL_PNPM" ] || fail "node and pnpm are required for configuration-consumer checks"
unset NVM_DIR NVM_BIN NVM_INC PNPM_HOME XDG_DATA_HOME XDG_STATE_HOME NPM_CONFIG_PREFIX

# --- fakes --------------------------------------------------------------------

FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX/image"
export NODE_TOOLS_POLICY_CHECK="$FIX/check-policy"
cat >"$NODE_TOOLS_POLICY_CHECK" <<'EOF'
#!/bin/sh
set -e
policy=$(PATH="$NODE_TOOLS_TEST_PATH" "$REAL_PNPM" --dir "$(dirname "$1")" config get allowBuilds --json)
"$REAL_NODE" - "$policy" <<'JS'
const assert = require('node:assert/strict');
const policy = JSON.parse(process.argv[2]);
for (const [key, value] of Object.entries({ 'better-sqlite3': true, esbuild: true, edgedriver: false, geckodriver: false })) {
  assert.equal(policy[key], value);
}
JS
EOF
chmod +x "$NODE_TOOLS_POLICY_CHECK"

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
      cp "$FIX/npx" "\$bin/npx"
      printf '#!/bin/sh\nif [ "\$1" = --version ]; then echo $FAKE_NODE; else exec "%s" "\$@"; fi\n' "\$REAL_NODE" >"\$bin/node"
      chmod +x "\$bin/npm" "\$bin/npx" "\$bin/node"
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

# A fake npm: its global prefix is $NPM_CONFIG_PREFIX, else the directory above
# its own bin (nvm's layout). `npm install -g pnpm` installs the fake pnpm;
# the other global installs put each package under lib/node_modules, with a
# bin for mbt, mta, and yo. NPM_FAKE_FAIL makes those fail.
cat >"$FIX/npm" <<EOF
#!/bin/sh
prefix=\${NPM_CONFIG_PREFIX:-\$(cd "\$(dirname "\$0")/.." && pwd)}
case "\$1 \$2" in
  "prefix -g") echo "\$prefix" ;;
  "root -g") echo "\$prefix/lib/node_modules" ;;
  "install -g")
    echo "npm \$*" >>"\$NODE_TOOLS_LOG"
    shift 2
    for pkg; do
      case "\$pkg" in
        --*) continue ;;
        pnpm) mkdir -p "\$prefix/bin"; cp "$FIX/pnpm" "\$prefix/bin/pnpm"; continue ;;
      esac
      [ -z "\${NPM_FAKE_FAIL-}" ] || { echo "npm ERR! network" >&2; exit 1; }
      mkdir -p "\$prefix/lib/node_modules/\$pkg" "\$prefix/bin"
      echo '{}' >"\$prefix/lib/node_modules/\$pkg/package.json"
      case "\$pkg" in
        mbt | mta | yo) cp "$FIX/fake-\$pkg" "\$prefix/bin/\$pkg" ;;
      esac
    done
    ;;
  *) echo "fake npm: unexpected: \$*" >&2; exit 1 ;;
esac
EOF

# The fake mbt, mta, and yo; MBT_FAKE_BROKEN breaks mbt, and YO_FAKE_HIDE hides
# one generator namespace. yo lists the generators that are installed under its
# own npm prefix, like the real one.
cat >"$FIX/fake-mbt" <<'EOF'
#!/bin/sh
[ -z "${MBT_FAKE_BROKEN-}" ] || exit 1
echo "Cloud MTA Build Tool version 9.9.9"
EOF
cat >"$FIX/fake-mta" <<'EOF'
#!/bin/sh
echo "MTA version 9.9.9"
EOF
cat >"$FIX/fake-yo" <<'EOF'
#!/bin/sh
echo "yo $*" >>"$NODE_TOOLS_LOG"
root=$(dirname "$0")/../lib/node_modules
echo "Available Generators:"
for dir in "$root"/generator-* "$root"/@*/generator-*; do
  [ -d "$dir" ] || continue
  ns=$(printf '%s\n' "${dir#"$root"/}" | sed 's|generator-||')
  [ "$ns" = "${YO_FAKE_HIDE-}" ] || echo "  $ns"
done
EOF

# A fake pnpm 11+: global bins go to $PNPM_HOME/bin, which must be on PATH, and
# global packages live under $PNPM_HOME/global/v11, which needs a
# pnpm-workspace.yaml with allowBuilds one level up before anything is added.
# PNPM_FAKE_FAIL makes `add` fail.
cat >"$FIX/pnpm" <<'EOF'
#!/bin/sh
bin="$PNPM_HOME/bin"
root="$PNPM_HOME/global/v11"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "ERR_PNPM_GLOBAL_BIN_DIR_NOT_IN_PATH: $bin" >&2; exit 1 ;;
esac
case "$1 $2" in
  "bin -g") echo "$bin" ;;
  "root -g") echo "$root" ;;
  "ls -g")
    echo "$root"
    for dir in "$root"/h/node_modules/* "$root"/h/node_modules/@*/*; do
      [ -f "$dir/package.json" ] && echo "$dir"
    done
    exit 0
    ;;
  "add -g" | "remove -g")
    echo "pnpm $*" >>"$NODE_TOOLS_LOG"
    command=$1
    shift 2
    if [ "$command" = add ]; then
      [ -z "${PNPM_FAKE_FAIL-}" ] || { echo "ERR_PNPM_FETCH_404" >&2; exit 1; }
      "$NODE_TOOLS_POLICY_CHECK" "$PNPM_HOME/global/pnpm-workspace.yaml" \
        || { echo "fake pnpm: incorrect allowBuilds in $PNPM_HOME/global/pnpm-workspace.yaml" >&2; exit 1; }
    fi
    for package; do
      case "$package" in -*) continue ;; esac
      package=${package%@latest}
      case "$package" in
        @earendil-works/pi-coding-agent) name=pi ;;
        @github/copilot) name=copilot ;;
        *) name= ;;
      esac
      if [ "$command" = remove ]; then
        [ -z "$name" ] || rm -f "$bin/$name"
        rm -rf "$root/h/node_modules/$package"
      else
        mkdir -p "$root/h/node_modules/$package"
        echo '{}' >"$root/h/node_modules/$package/package.json"
        [ -z "$name" ] || { mkdir -p "$bin"; printf '#!/bin/sh\necho pnpm-%s-fake\n' "$name" >"$bin/$name"; chmod +x "$bin/$name"; }
      fi
    done
    ;;
  *) echo "fake pnpm: unexpected: $*" >&2; exit 1 ;;
esac
EOF

# A fake npx that only knows `npx --yes skills add SOURCE [--skill NAME]`. Like
# the real CLI it needs --agent universal, --yes, and --global, and writes
# skills to ~/.agents/skills. NPX_FAKE_FAIL makes it fail.
cat >"$FIX/npx" <<'EOF'
#!/bin/sh
echo "npx $*" >>"$NODE_TOOLS_LOG"
[ -z "${NPX_FAKE_FAIL-}" ] || { echo "npm ERR! network" >&2; exit 1; }
[ "$1 $2 $3" = "--yes skills add" ] || { echo "fake npx: unexpected: $*" >&2; exit 1; }
shift 3
source=$1
shift
[ "$source" != "${NPX_FAKE_FAIL_SOURCE-}" ] || { echo "npm ERR! network" >&2; exit 1; }
skill= agent= yes= global=
while [ $# -gt 0 ]; do
  case "$1" in
    --skill) skill=$2; shift ;;
    --agent) agent=$2; shift ;;
    --yes) yes=1 ;;
    --global) global=1 ;;
    *) echo "fake skills: unexpected $1" >&2; exit 1 ;;
  esac
  shift
done
[ "$agent" = universal ] && [ -n "$yes" ] && [ -n "$global" ] \
  || { echo "fake skills: needs --agent universal --yes --global" >&2; exit 1; }
add() {
  mkdir -p "$HOME/.agents/skills/$1"
  echo "$2" >"$HOME/.agents/skills/$1/SKILL.md"
  [ "$2" != pinned ] || [ -z "${NPX_FAKE_SKIP_PIN_LOCK-}" ] || return 0
  node - "$1" "$source" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const file = process.env.XDG_STATE_HOME
  ? path.join(process.env.XDG_STATE_HOME, 'skills', '.skill-lock.json')
  : path.join(process.env.HOME, '.agents', '.skill-lock.json');
let lock = { version: 3, skills: {} };
try { lock = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
if (!(lock.version >= 3) || !lock.skills) lock = { version: 3, skills: {} };
const [name, input] = process.argv.slice(2);
const pinned = input.startsWith('https://');
const source = pinned ? 'mattpocock/skills' : input;
lock.skills[name] = {
  source, sourceType: 'github', sourceUrl: `https://github.com/${source}.git`,
  ...(pinned ? { ref: input.split('/tree/')[1].split('/')[0] } : {}),
  skillPath: `skills/engineering/${name}/SKILL.md`, skillFolderHash: 'fake-folder-hash',
};
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(lock));
JS
}
case "$source" in
  arc-mcp/arc-1) add explain-abap-code arc ;;
  mattpocock/skills) add tdd matt; add resolving-merge-conflicts unpinned ;;
  vercel-labs/skills) [ "$skill" = find-skills ] || exit 1; add find-skills vercel ;;
  https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts)
    add resolving-merge-conflicts pinned ;;
  *) echo "fake skills: unexpected source $source" >&2; exit 1 ;;
esac
EOF

# A fake cf with the ServiceInfo plugin that @sap/cf-tools-local adds, unless
# CF_FAKE_NO_PLUGIN is set.
cat >"$FIX/cf" <<'EOF'
#!/bin/sh
[ -f "$(npm root -g)/@sap/cf-tools-local/package.json" ] && [ -z "${CF_FAKE_NO_PLUGIN-}" ] && echo "ServiceInfo    1.0.0"
exit 0
EOF
chmod +x "$FIX/npm" "$FIX/npx" "$FIX/pnpm" "$FIX/cf" "$FIX"/fake-*
# The devcontainer image's own Node.js tools, fakes of the nvm layout's.
cp "$FIX/pnpm" "$FIX/npm" "$FIX/npx" "$FIX/cf" "$FIX/image/"
ln -s "$REAL_NODE" "$FIX/image/node"

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

# A stand-in for Pi's install script (run with sh): like the real one, it
# refuses a pi on PATH that is not its own managed install, keeps its launcher
# in ~/.pi/agent/bin, and links it from ~/.local/bin, the first of its
# preferred bin directories on PATH. It takes a /mnt/* PATH entry for WSL's
# Windows npm directory with its pi, which the tests cannot create. It records
# whether it could reach a terminal to prompt on.
cat >"$FIX/pi-install.sh" <<'EOF'
set -e
if ( : <>/dev/tty ) 2>/dev/null; then tty=yes; else tty=no; fi
echo "pi-installer tty=$tty" >>"$NODE_TOOLS_LOG"
[ -z "${PI_FAKE_FAIL:-}" ] || { echo "error: Pi requires Node.js 22.19.0 or newer."; exit 1; }
existing=$(command -v pi || true)
case ":$PATH:" in
  *:/mnt/*) existing=${existing:-$(printf '%s\n' "$PATH" | tr : '\n' | grep -m1 '^/mnt/')/pi} ;;
esac
if [ -n "$existing" ]; then
  echo "Managed install refused to replace Pi at $existing. Uninstall it first." >&2
  exit 1
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "fake Pi installer: ~/.local/bin is not on PATH" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.pi/agent/bin" "$HOME/.local/bin"
printf '#!/bin/sh\necho pi-fake\n' >"$HOME/.pi/agent/bin/pi"
chmod +x "$HOME/.pi/agent/bin/pi"
ln -s ../../.pi/agent/bin/pi "$HOME/.local/bin/pi"
echo "Pi was installed successfully."
EOF

# A stand-in for Copilot's install script (run with bash): like the real one,
# it installs the binary into $PREFIX/bin.
cat >"$FIX/copilot-install.sh" <<'EOF'
set -e
if ( : <>/dev/tty ) 2>/dev/null; then tty=yes; else tty=no; fi
echo "copilot-installer tty=$tty" >>"$NODE_TOOLS_LOG"
[ "$PREFIX" = "$HOME/.local" ] || { echo "fake Copilot installer: PREFIX=$PREFIX" >&2; exit 1; }
mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\necho copilot-fake\n' >"$PREFIX/bin/copilot"
chmod +x "$PREFIX/bin/copilot"
EOF

# A stand-in for herdr's install script (run with sh): like the real one, it
# puts the binary at $HERDR_INSTALL_DIR/herdr (default ~/.local/bin). The fake
# herdr prints zsh completions that register _herdr.
cat >"$FIX/herdr-install.sh" <<'EOF'
set -e
dir=${HERDR_INSTALL_DIR:-$HOME/.local/bin}
[ "$dir" = "$HOME/.local/bin" ] || { echo "fake herdr installer: HERDR_INSTALL_DIR=$dir" >&2; exit 1; }
echo herdr-installer >>"$NODE_TOOLS_LOG"
mkdir -p "$dir"
cat >"$dir/herdr" <<'HERDR'
#!/bin/sh
case "$*" in
  "completion zsh") echo '_herdr() { :; }; compdef _herdr herdr' ;;
  *) echo herdr-fake ;;
esac
HERDR
chmod +x "$dir/herdr"
EOF

# A stand-in for Antigravity's install script (run with bash): like the real
# one, it takes --dir, puts agy at <dir>/agy, and ends by appending a PATH
# export to the rc files in its HOME, and it records its HOME and terminal.
cat >"$FIX/antigravity-install.sh" <<'EOF'
set -e
dir=$HOME/.local/bin
while [ $# -gt 0 ]; do
  case "$1" in
    -d | --dir) dir=$2; shift ;;
    *) echo "fake Antigravity installer: unexpected $1" >&2; exit 1 ;;
  esac
  shift
done
if ( : <>/dev/tty ) 2>/dev/null; then tty=yes; else tty=no; fi
echo "antigravity-installer tty=$tty dir=$dir" >>"$NODE_TOOLS_LOG"
echo "$HOME" >"$NODE_TOOLS_LOG.agy-home"
[ -z "${AGY_FAKE_FAIL:-}" ] || { echo "Fatal: Could not connect to the release server." >&2; exit 1; }
mkdir -p "$dir"
printf '#!/bin/sh\necho agy-fake\n' >"$dir/agy"
chmod +x "$dir/agy"
for rc in .zshrc .bashrc .profile; do
  printf '\n# Added by Antigravity CLI installer\nexport PATH="%s:$PATH"\n' "$dir" >>"$HOME/$rc"
done
EOF

export NVM_INSTALL_URL="file://$FIX/install.sh"
export HERDR_INSTALL_URL="file://$FIX/herdr-install.sh"
export PI_INSTALL_URL="file://$FIX/pi-install.sh"
export COPILOT_INSTALL_URL="file://$FIX/copilot-install.sh"
export CLAUDE_INSTALL_URL="file://$FIX/claude-install.sh"
export ANTIGRAVITY_INSTALL_URL="file://$FIX/antigravity-install.sh"
mkdir -p "$FIX/common"
cp "$FIX/cf" "$FIX/common/cf"
BASE_PATH="$FIX/common:/usr/bin:/bin"
WINDOWS_NPM="/mnt/c/Users/dev/AppData/Roaming/npm"

# Runs tools/node-tools.sh $2 against scratch HOME $1 with PATH $3.
run_tools() {
  HOME=$1 PATH=$3 bash "$ROOT/tools/node-tools.sh" "$2" 2>&1
}

# Runs tools/bash-tools.sh against scratch HOME $1 with PATH $2.
run_bash_tools() {
  HOME=$1 PATH=$2 bash "$ROOT/tools/bash-tools.sh" 2>&1
}

calls() {
  cat "$NODE_TOOLS_LOG" 2>/dev/null
}

agy_install_line() {
  echo "${AGY_INSTALL//%HOME%/$1}"
}

# What the scripts install, in order.
PNPM_ADD="pnpm add -g arc-1@latest npm-run-all eslint npm-check-updates @ui5/cli @sap/cds-dk @sap/cf-tools @sap/ux-ui5-tooling @sap/html5-app-deployer odata-openapi @wdio/cli"
SKILLS_ADD="npx --yes skills add arc-mcp/arc-1 --agent universal --yes --global
npx --yes skills add mattpocock/skills --agent universal --yes --global
npx --yes skills add vercel-labs/skills --skill find-skills --agent universal --yes --global
npx --yes skills add https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts --agent universal --yes --global"
NPM_ADD="npm install -g --allow-scripts=mbt,mta mbt mta yo generator-easy-ui5 @sap-ux/generator-adp @sap/generator-adaptation-project @sap/generator-add-hdb-module @sap/generator-aicore @sap/generator-base-mta-module @sap/generator-cap-project @sap/generator-fiori"
CF_LOCAL_ADD="npm install -g --allow-scripts=@sap/cf-tools-local @sap/cf-tools-local"
YO_SMOKE="yo --generators --no-insight"
case "$(uname -m)" in
  x86_64 | amd64) AMD64=yes ;;
  *) AMD64= ;;
esac
# What node-tools.sh installs on top of Node.js and pnpm.
NODE_INSTALLS="$PNPM_ADD
$SKILLS_ADD
$NPM_ADD${AMD64:+
$CF_LOCAL_ADD}
$YO_SMOKE"
# What bash-tools.sh installs for HOME $1.
bash_installs() {
  printf '%s\n' "$HERDR_INSTALL" "$PI_INSTALL" "$COPILOT_INSTALL" "$CLAUDE_INSTALL" "$(agy_install_line "$1")"
}
YO_NAMESPACES="easy-ui5 @sap-ux/adp @sap/adaptation-project @sap/add-hdb-module @sap/aicore @sap/base-mta-module @sap/cap-project @sap/fiori"

# --- tools/node-tools.sh and tools/bash-tools.sh ----------------------------------

test_workstation_fresh_then_quiet() {
  local home="$TMP_ROOT/ws" out nvm_prefix ns
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools on a fresh workstation HOME failed: $out"
  [ "$(calls)" = "nvm-installer PROFILE=/dev/null
nvm install --lts --no-progress
nvm alias default lts/*
npm install -g pnpm
$NODE_INSTALLS" ] || fail "workstation did not install nvm, Node.js LTS as default, pnpm, the pnpm globals, the skills, the npm globals, and cf-tools-local, in order: $(calls)"
  [ "$("$home/.nvm/default/bin/node" --version)" = "$FAKE_NODE" ] || fail "\$NVM_DIR/default is not nvm's default Node.js"
  # The npm globals are in nvm's prefix, which $NVM_DIR/default/bin (on PATH) shows, and yo finds them there.
  nvm_prefix="$home/.nvm/versions/node/$FAKE_NODE"
  [ "$("$home/.nvm/default/bin/mbt" --version)" = "Cloud MTA Build Tool version 9.9.9" ] || fail "mbt is not in nvm's default Node.js bin"
  [ "$("$home/.nvm/default/bin/mta" --version)" = "MTA version 9.9.9" ] || fail "mta is not in nvm's default Node.js bin"
  for ns in $YO_NAMESPACES; do
    assert_contains "$("$home/.nvm/default/bin/yo" --generators)" "$ns" "yo does not list the $ns generator from nvm's prefix"
  done
  [ -d "$nvm_prefix/lib/node_modules/@sap/generator-fiori" ] || fail "the generators are not under npm's global prefix"
  [ ! -e "$home/.local/share/pnpm/global/v11/h/node_modules/yo" ] || fail "yo was installed with pnpm"
  "$NODE_TOOLS_POLICY_CHECK" "$home/.local/share/pnpm/global/pnpm-workspace.yaml" || fail "pnpm's global build policy is wrong"
  [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = pinned ] || fail "resolving-merge-conflicts is not the pinned copy"
  [ -f "$home/.agents/skills/find-skills/SKILL.md" ] || fail "find-skills is missing"

  : >"$NODE_TOOLS_LOG"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools on a fresh workstation HOME failed: $out"
  [ "$(calls)" = "$(bash_installs "$home")" ] || fail "bash-tools did not install herdr, Pi, Copilot, Claude Code, and Antigravity, in order: $(calls)"
  for tool in herdr pi copilot claude agy; do
    [ "$("$home/.local/bin/$tool" --version)" = "$tool-fake" ] || fail "$tool does not run from ~/.local/bin"
    [ ! -e "$home/.local/share/pnpm/bin/$tool" ] || fail "workstation installed $tool with pnpm"
  done
  for rc in .bashrc .bash_profile .profile .zshrc .zprofile; do
    [ ! -e "$home/$rc" ] || fail "an installer wrote $rc, which Home Manager owns"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools re-run failed: $out"
  out="$out$(run_bash_tools "$home" "$BASE_PATH")" || fail "bash-tools re-run failed: $out"
  [ "$(calls)" = "$YO_SMOKE" ] || fail "a re-run reinstalled something or skipped the generator check: $(calls)"
  [ -z "$out" ] || fail "a re-run is not quiet: $out"
  pass "workstation: nvm (PROFILE=/dev/null), Node.js LTS as default, pnpm, the pnpm globals (allowBuilds first), the skills, the npm globals in nvm's prefix (yo lists every generator), cf-tools-local on amd64; then herdr, Pi, Copilot, Claude Code, and Antigravity; re-runs install and print nothing"
}

test_only_missing_is_installed() {
  local home="$TMP_ROOT/ws" out root
  root="$home/.nvm/versions/node/$FAKE_NODE/lib/node_modules"
  rm -rf "$home/.local/share/pnpm/global/v11/h/node_modules/eslint" "$home/.local/share/pnpm/global/v11/h/node_modules/@ui5" \
    "$root/mbt" "$root/@sap/generator-aicore" "$home/.agents/skills/find-skills"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools after deleting some tools failed: $out"
  [ "$(calls)" = "pnpm add -g eslint @ui5/cli
npx --yes skills add vercel-labs/skills --skill find-skills --agent universal --yes --global
npm install -g --allow-scripts=mbt,mta mbt @sap/generator-aicore
$YO_SMOKE" ] \
    || fail "node-tools did not install only the missing pnpm globals, skill, and npm globals: $(calls)"
  # mta and the other tools are untouched, and mta/yo from the first install still run.
  [ -f "$root/mbt/package.json" ] || fail "mbt was not reinstalled"

  # mattpocock/skills is always followed by the pinned resolving-merge-conflicts.
  rm -rf "$home/.agents/skills/tdd"
  : >"$NODE_TOOLS_LOG"
  out=$(run_tools "$home" workstation "$BASE_PATH") || fail "node-tools after deleting a mattpocock skill failed: $out"
  [ "$(calls)" = "npx --yes skills add mattpocock/skills --agent universal --yes --global
npx --yes skills add https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts --agent universal --yes --global
$YO_SMOKE" ] \
    || fail "mattpocock/skills was not followed by the pinned skill: $(calls)"
  [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = pinned ] || fail "the pinned copy lost to mattpocock/skills'"
  pass "a re-switch installs only the missing pnpm and npm globals and skills, and the pinned resolving-merge-conflicts always follows mattpocock/skills"
}

test_container_and_failures() {
  local home="$TMP_ROOT/ct" out ns
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "container with the image's Node.js tools failed: $out"
  [ "$(calls)" = "$NODE_INSTALLS" ] || fail "container did not run only the pnpm, skills, and npm installs: $(calls)"
  # npm's global prefix is ~/.npm-global, where yo finds the generators.
  for ns in $YO_NAMESPACES; do
    assert_contains "$("$home/.npm-global/bin/yo" --generators)" "$ns" "yo does not list $ns from ~/.npm-global"
  done
  [ -x "$home/.npm-global/bin/mbt" ] && [ -x "$home/.npm-global/bin/mta" ] || fail "mbt and mta are not in ~/.npm-global/bin"
  [ ! -e "$home/.nvm" ] || fail "container installed nvm"
  : >"$NODE_TOOLS_LOG"
  out="$out$(PNPM_HOME="$home/pnpm-home" run_bash_tools "$home" "$FIX/image:$BASE_PATH")" || fail "container bash-tools failed: $out"
  [ "$(calls)" = "$(bash_installs "$home")" ] || fail "container bash-tools did not only run the five installers: $(calls)"
  for tool in herdr pi copilot claude agy; do
    [ -x "$home/.local/bin/$tool" ] || fail "container did not install $tool into ~/.local/bin"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_tools "$home" container "$FIX/image:$BASE_PATH")
  out="$out$(PNPM_HOME="$home/pnpm-home" run_bash_tools "$home" "$FIX/image:$BASE_PATH")"
  [ "$(calls)" = "$YO_SMOKE" ] && [ -z "$out" ] || fail "a container re-run reinstalled tools, skipped the generator check, or warned: $(calls) $out"

  # NPM_CONFIG_PREFIX wins over ~/.npm-global.
  home="$TMP_ROOT/ct-prefix"
  mkdir -p "$home"
  out=$(NPM_CONFIG_PREFIX="$home/custom" PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") \
    || fail "container with NPM_CONFIG_PREFIX failed: $out"
  [ -x "$home/custom/bin/yo" ] && [ ! -e "$home/.npm-global" ] || fail "container ignored NPM_CONFIG_PREFIX"

  # No pnpm: node-tools stops with one clear message, nothing is installed,
  # and bash-tools still installs all five.
  home="$TMP_ROOT/ct-nopnpm"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  if out=$(run_tools "$home" container "$BASE_PATH"); then
    fail "container without pnpm succeeded: $out"
  fi
  assert_contains "$out" "pnpm not found on PATH" "missing pnpm is not reported clearly: $out"
  [ -z "$(calls)" ] || fail "node-tools installed something without pnpm: $(calls)"
  out=$(run_bash_tools "$home" "$BASE_PATH") || fail "bash-tools without pnpm failed: $out"
  [ "$(calls)" = "$(bash_installs "$home")" ] || fail "bash-tools without pnpm did not install the five CLIs: $(calls)"

  if out=$(NVM_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_tools "$TMP_ROOT/ws-offline" workstation "$BASE_PATH"); then
    fail "workstation without the nvm install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install nvm" "a failed nvm download is not reported: $out"
  pass "container: the image's Node.js and pnpm, npm globals in ~/.npm-global (or \$NPM_CONFIG_PREFIX) where yo finds them, no nvm; without pnpm node-tools fails clearly and bash-tools still installs everything"
}

test_step_failures_do_not_block() {
  local home out
  # A failing pnpm add: npm globals and skills are still installed.
  home="$TMP_ROOT/fail-pnpm"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  if out=$(PNPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing pnpm add was accepted: $out"
  fi
  assert_contains "$out" "pnpm add -g arc-1@latest" "a failed pnpm add is not reported: $out"
  [ -x "$home/.npm-global/bin/yo" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] || fail "a failing pnpm add stopped the npm globals or the skills"

  # A failing npm install: pnpm globals and skills are still installed.
  home="$TMP_ROOT/fail-npm"
  mkdir -p "$home"
  if out=$(NPM_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing npm install was accepted: $out"
  fi
  assert_contains "$out" "npm install -g mbt mta yo" "a failed npm install is not reported: $out"
  [ -d "$home/pnpm/global/v11/h/node_modules/eslint" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] \
    || fail "a failing npm install stopped the pnpm globals or the skills"
  for tool in mbt mta yo; do
    assert_contains "$out" "warning: $tool is not on PATH" "a failing npm install suppressed the $tool smoke warning: $out"
  done
  if [ -n "$AMD64" ]; then
    assert_contains "$out" "warning: cf plugins does not list ServiceInfo" "a failing cf-tools-local install suppressed the plugin warning: $out"
  fi

  # Failing skills: pnpm and npm globals are still installed.
  home="$TMP_ROOT/fail-skills"
  mkdir -p "$home"
  if out=$(NPX_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "failing skills were accepted: $out"
  fi
  assert_contains "$out" "npx skills add arc-mcp/arc-1 failed" "a failed skills install is not reported: $out"
  [ -d "$home/pnpm/global/v11/h/node_modules/eslint" ] && [ -x "$home/.npm-global/bin/yo" ] \
    || fail "failing skills stopped the pnpm or npm globals"

  # A skills install that leaves find-skills out is caught, as the Dockerfile did.
  home="$TMP_ROOT/fail-skill-missing"
  mkdir -p "$home/.agents/skills/explain-abap-code" "$home/.agents/skills/tdd" "$home/.agents/skills/resolving-merge-conflicts"
  : >"$home/.agents/skills/explain-abap-code/SKILL.md"
  : >"$home/.agents/skills/tdd/SKILL.md"
  mkdir -p "$home/bin"
  # An npx that succeeds without installing anything.
  printf '#!/bin/sh\nexit 0\n' >"$home/bin/npx"
  chmod +x "$home/bin/npx"
  if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$home/bin:$FIX/image:$BASE_PATH"); then
    fail "a skills install that left skills out was accepted: $out"
  fi
  assert_contains "$out" "find-skills/SKILL.md is missing" "a missing skill is not reported: $out"
  pass "a failing pnpm, npm, or skills step is reported and fails the run without stopping the others; a missing find-skills or resolving-merge-conflicts skill is caught"
}

test_smoke_checks_warn() {
  local home out
  home="$TMP_ROOT/smoke"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(MBT_FAKE_BROKEN=1 YO_FAKE_HIDE=@sap/aicore CF_FAKE_NO_PLUGIN=1 PNPM_HOME="$home/pnpm" \
    run_tools "$home" container "$FIX/image:$BASE_PATH") && fail "failing smoke checks were not reported as a non-zero exit"
  assert_contains "$out" "warning: mbt --version" "broken mbt is not a warning: $out"
  assert_contains "$out" "warning: yo --generators does not list @sap/aicore" "a missing generator is not a warning: $out"
  if [ -n "$AMD64" ]; then
    assert_contains "$out" "warning: cf plugins does not list ServiceInfo" "a missing ServiceInfo plugin is not a warning: $out"
  fi
  [ -x "$home/.npm-global/bin/yo" ] && [ -f "$home/.agents/skills/find-skills/SKILL.md" ] || fail "smoke warnings stopped the installs"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a re-run after smoke warnings failed: $out"
  [ "$(calls)" = "$YO_SMOKE" ] && [ -z "$out" ] || fail "a re-run after smoke warnings skipped the generator check or was not quiet: $(calls) $out"
  if out=$(YO_FAKE_HIDE=@sap/fiori PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "an existing but undiscoverable generator was accepted: $out"
  fi
  assert_contains "$out" "warning: yo --generators does not list @sap/fiori" "a re-switch suppressed the generator warning: $out"
  mkdir -p "$home/image-no-cf"
  cp "$FIX/image/npm" "$FIX/image/pnpm" "$FIX/image/npx" "$home/image-no-cf/"
  ln -s "$REAL_NODE" "$home/image-no-cf/node"
  if [ -n "$AMD64" ]; then
    if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$home/image-no-cf:/usr/bin:/bin"); then
      fail "a missing cf CLI was silently accepted: $out"
    fi
    assert_contains "$out" "ServiceInfo plugin could not be verified because cf is missing" "a missing cf CLI did not warn: $out"
  fi
  printf '#!/bin/sh\necho aarch64\n' >"$home/image-no-cf/uname"
  chmod +x "$home/image-no-cf/uname"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$home/image-no-cf:/usr/bin:/bin") || fail "an ARM re-switch tried to verify an amd64-only plugin: $out"
  assert_not_contains "$out" "ServiceInfo" "an ARM re-switch checked the amd64-only plugin: $out"
  rm -rf "$home/.npm-global/lib/node_modules/mta"
  if out=$(NPM_FAKE_FAIL=1 YO_FAKE_HIDE=@sap/cap-project PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
    fail "a failing install with a smoke warning succeeded: $out"
  fi
  assert_contains "$out" "warning: yo --generators does not list @sap/cap-project" "an npm failure suppressed an existing generator's smoke check: $out"
  pass "smoke checks warn on every switch, including existing globals, failed installs, and a missing cf CLI"
}

test_pnpm_policy() {
  local home="$TMP_ROOT/policy" file out shape setting
  mkdir -p "$home/pnpm/global"
  file="$home/pnpm/global/pnpm-workspace.yaml"
  printf '%s\n' 'packages:' '  - "apps/*"' 'allowBuilds:' '  geckodriver: true' '  "esbuild": false # keep this note' '  custom-native: true' "  '@scope/native': false" '  better-sqlite3: false' 'linkWorkspacePackages: false' 'catalog:' '  foo: latest' >"$file"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "an existing block policy was not repaired: $out"
  "$NODE_TOOLS_POLICY_CHECK" "$file" || fail "required policy values were not repaired"
  PATH="$NODE_TOOLS_TEST_PATH" "$REAL_PNPM" --dir "$(dirname "$file")" config list --json | "$REAL_NODE" -e '
const assert = require("node:assert/strict");
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const config = JSON.parse(input);
  assert.deepEqual(config.allowBuilds, { "better-sqlite3": true, esbuild: true, edgedriver: false, geckodriver: false, "custom-native": true, "@scope/native": false });
  assert.deepEqual(config.packages, ["apps/*"]);
  assert.equal(config.linkWorkspacePackages, false);
  assert.deepEqual(config.catalog, { foo: "latest" });
});' || fail "repair changed unrelated policy entries or top-level settings"

  printf '%s\n' 'packages:' '  - "apps/*"' 'linkWorkspacePackages: false' >"$file"
  rm -rf "$home/pnpm/global/v11/h/node_modules/eslint"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a missing policy was not added: $out"
  "$NODE_TOOLS_POLICY_CHECK" "$file" || fail "added policy has incorrect values"
  setting=$(PATH="$NODE_TOOLS_TEST_PATH" "$REAL_PNPM" --dir "$(dirname "$file")" config get packages --json)
  "$REAL_NODE" -e 'require("node:assert/strict").deepEqual(JSON.parse(process.argv[1]), ["apps/*"])' "$setting" || fail "adding a policy changed existing settings"

  for shape in flow duplicate alias nested document indented; do
    case "$shape" in
      flow) printf '%s\n' 'allowBuilds: { esbuild: false }' >"$file" ;;
      duplicate) printf '%s\n' 'allowBuilds:' '  esbuild: true' '  esbuild: false' >"$file" ;;
      alias) printf '%s\n' 'allowBuilds:' '  esbuild: *build' >"$file" ;;
      nested) printf '%s\n' 'allowBuilds:' '  esbuild:' '    enabled: true' >"$file" ;;
      document) printf '%s\n' '---' 'allowBuilds:' '  esbuild: false' >"$file" ;;
      indented) printf '%s\n' '  allowBuilds:' '    esbuild: false' >"$file" ;;
    esac
    cp "$file" "$home/original.yaml"
    rm -rf "$home/pnpm/global/v11/h/node_modules/eslint"
    : >"$NODE_TOOLS_LOG"
    if out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
      fail "unsafe $shape policy was accepted: $out"
    fi
    assert_contains "$out" "warning: cannot safely set allowBuilds" "unsafe $shape policy did not warn: $out"
    cmp -s "$file" "$home/original.yaml" || fail "unsafe $shape policy was changed"
    assert_not_contains "$(calls)" "pnpm add" "unsafe $shape policy allowed an install"
    assert_contains "$(calls)" "$YO_SMOKE" "unsafe policy suppressed smoke checks"
  done

  printf '%s\n' 'allowBuilds: { geckodriver: false, esbuild: true, better-sqlite3: true, edgedriver: false }' >"$file"
  HOME="$home" PNPM_HOME="$home/pnpm" PATH="$FIX/image:$home/pnpm/bin:$BASE_PATH" "$FIX/pnpm" add -g eslint \
    || fail "the fake install guard rejected an equivalent flow-style policy"
  printf '%s\n' 'allowBuilds:' '  # better-sqlite3: true' '  # esbuild: true' '  # edgedriver: false' '  # geckodriver: false' >"$file"
  if HOME="$home" PNPM_HOME="$home/pnpm" PATH="$FIX/image:$home/pnpm/bin:$BASE_PATH" "$FIX/pnpm" add -g eslint >/dev/null 2>&1; then
    fail "the fake install guard accepted commented-out policy entries"
  fi
  pass "pnpm policy repairs required booleans, preserves unrelated settings, and leaves unsafe shapes untouched; assertions consume YAML semantically"
}

test_skill_pin_retries() {
  local home out source state entry field
  local pin=https://github.com/mattpocock/skills/tree/153fc1b93de6584562765cdce299324e1ff9e661/skills/engineering/resolving-merge-conflicts
  for source in vercel-labs/skills "$pin"; do
    for state in default xdg; do
      home="$TMP_ROOT/pin-${source##*/}-$state"
      mkdir -p "$home"
      if out=$(XDG_STATE_HOME=$([ "$state" = default ] || echo "$home/state") NPX_FAKE_FAIL_SOURCE="$source" PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH"); then
        fail "an interrupted skills install succeeded: $out"
      fi
      [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = unpinned ] || fail "the interrupted install did not reproduce the unpinned skill"
      : >"$NODE_TOOLS_LOG"
      out=$(XDG_STATE_HOME=$([ "$state" = default ] || echo "$home/state") PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a retry did not converge to the pin: $out"
      assert_contains "$(calls)" "npx --yes skills add $pin" "a retry skipped the pin after $source failed"
      [ "$(cat "$home/.agents/skills/resolving-merge-conflicts/SKILL.md")" = pinned ] || fail "a retry retained the unpinned skill"
      : >"$NODE_TOOLS_LOG"
      out=$(XDG_STATE_HOME=$([ "$state" = default ] || echo "$home/state") PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a converged pin was not idempotent: $out"
      [ "$(calls)" = "$YO_SMOKE" ] && [ -z "$out" ] || fail "a converged pin was reinstalled: $(calls) $out"
    done
  done

  home="$TMP_ROOT/pin-skills-default"
  for field in missing malformed ref source sourceType sourceUrl version; do
    entry="$home/.agents/.skill-lock.json"
    case "$field" in
      missing) rm -f "$entry" ;;
      malformed) echo '{' >"$entry" ;;
      *) "$REAL_NODE" - "$entry" "$field" <<'JS'
const fs = require('node:fs');
const [file, field] = process.argv.slice(2);
const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
if (field === 'version') lock.version = 2;
else lock.skills['resolving-merge-conflicts'][field] = 'wrong';
fs.writeFileSync(file, JSON.stringify(lock));
JS
      ;;
    esac
    : >"$NODE_TOOLS_LOG"
    out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "invalid $field metadata was not repaired: $out"
    assert_contains "$(calls)" "npx --yes skills add $pin" "invalid $field metadata bypassed the pin"
  done
  rm -f "$home/.agents/skills/resolving-merge-conflicts/SKILL.md"
  out=$(PNPM_HOME="$home/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH") || fail "a missing pinned skill was not restored: $out"
  if out=$(NPX_FAKE_SKIP_PIN_LOCK=1 PNPM_HOME="$TMP_ROOT/pin-no-lock/pnpm" run_tools "$TMP_ROOT/pin-no-lock" container "$FIX/image:$BASE_PATH"); then
    fail "a pin install without matching lock metadata was accepted: $out"
  fi
  assert_contains "$out" "lock metadata does not identify the pinned source and revision" "a pin without metadata was not reported: $out"
  pass "interrupted skill installs converge on retry; the pin requires its file and source/revision metadata, including XDG state"
}

test_bash_tools_failures() {
  local home out

  home="$TMP_ROOT/bt-noherdr"
  if out=$(HERDR_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without herdr's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install herdr" "a failed herdr download is not reported: $out"
  [ -x "$home/.local/bin/agy" ] && [ -x "$home/.local/bin/claude" ] || fail "a failed herdr install stopped the other installers"

  if out=$(PI_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$TMP_ROOT/bt-nopi" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools offline succeeded: $out"
  fi
  assert_contains "$out" "cannot download the Pi installer" "an offline Pi install is not reported clearly: $out"

  if out=$(COPILOT_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$TMP_ROOT/bt-nocopilot" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without Copilot's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install the GitHub Copilot CLI" "a failed Copilot download is not reported: $out"

  if out=$(CLAUDE_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$TMP_ROOT/bt-noclaude" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without Claude Code's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot install Claude Code" "a failed Claude Code download is not reported: $out"

  home="$TMP_ROOT/bt-noagy"
  if out=$(ANTIGRAVITY_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "bash-tools without Antigravity's install script succeeded: $out"
  fi
  assert_contains "$out" "cannot download the Antigravity installer" "a failed Antigravity download is not reported: $out"
  [ -x "$home/.local/bin/claude" ] || fail "a failed Antigravity download stopped the other installers"

  home="$TMP_ROOT/bt-agyfail"
  if out=$(AGY_FAKE_FAIL=1 run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "a failing Antigravity installer was accepted: $out"
  fi
  assert_contains "$out" "Could not connect to the release server" "the Antigravity installer's own error is hidden: $out"
  assert_contains "$out" "cannot install the Antigravity CLI" "a failed Antigravity install is not reported: $out"
  assert_contains "$out" "failed: antigravity" "the failed step is not named: $out"
  pass "bash-tools reports each failed installer without stopping the others"
}

test_antigravity_scratch_home() {
  local home="$TMP_ROOT/agy" out scratch
  mkdir -p "$home"
  # The rc files Home Manager owns, which the real installer would append to.
  for rc in .zshrc .bashrc .profile; do echo "# mine" >"$home/$rc"; done
  : >"$NODE_TOOLS_LOG"
  out=$(TMPDIR="$TMP_ROOT" run_bash_tools "$home" "$FIX/image:$BASE_PATH") || fail "bash-tools failed: $out"
  scratch=$(cat "$NODE_TOOLS_LOG.agy-home")
  [ -n "$scratch" ] && [ "$scratch" != "$home" ] || fail "Antigravity's installer did not get a scratch HOME: $scratch"
  [ ! -e "$scratch" ] || fail "Antigravity's scratch HOME was not removed: $scratch"
  assert_contains "$(calls)" "antigravity-installer tty=no dir=$home/.local/bin" "Antigravity's installer did not run without a terminal into ~/.local/bin: $(calls)"
  [ "$("$home/.local/bin/agy" --version)" = agy-fake ] || fail "agy is not in the real ~/.local/bin"
  for rc in .zshrc .bashrc .profile; do
    [ "$(cat "$home/$rc")" = "# mine" ] || fail "Antigravity's installer changed $home/$rc"
  done
  pass "Antigravity's installer runs in a scratch HOME without a terminal with --dir ~/.local/bin: agy lands there and no real rc file changes"
}

# Installs package $2 (with optional flags $3...) with the fake pnpm into scratch
# pnpm home $1, after the allowBuilds file that the fake pnpm requires.
pnpm_seed() {
  local pnpm_home=$1 pkg=$2
  mkdir -p "$pnpm_home/global"
  printf 'allowBuilds:\n  better-sqlite3: true\n  esbuild: true\n  edgedriver: false\n  geckodriver: false\n' >"$pnpm_home/global/pnpm-workspace.yaml"
  PNPM_HOME="$pnpm_home" PATH="$pnpm_home/bin:$FIX/image:$BASE_PATH" pnpm add -g "$pkg"
}

test_migrate_pnpm_copies() {
  local home="$TMP_ROOT/migrate" out pnpm_bin
  mkdir -p "$home"
  pnpm_bin="$home/pnpm-home/bin"
  # What an older switch left: pnpm's Pi and Copilot, with a Windows pi on
  # WSL's PATH.
  pnpm_seed "$home/pnpm-home" @earendil-works/pi-coding-agent
  pnpm_seed "$home/pnpm-home" @github/copilot

  # Without Pi's installer, pnpm's Pi keeps working.
  : >"$NODE_TOOLS_LOG"
  if out=$(PI_INSTALL_URL="file://$TMP_ROOT/missing.sh" PNPM_HOME="$home/pnpm-home" \
    run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "an offline migration succeeded: $out"
  fi
  [ -x "$pnpm_bin/pi" ] || fail "an offline migration removed pnpm's Pi"
  assert_not_contains "$(calls)" "pnpm remove -g @earendil-works" "an offline migration removed pnpm's Pi: $(calls)"

  # The other installers ran anyway, so start over with both pnpm copies.
  rm -rf "$home/.local" "$home/.pi"
  pnpm_seed "$home/pnpm-home" @github/copilot
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm-home" run_bash_tools "$home" "$FIX/image:$BASE_PATH:$WINDOWS_NPM") \
    || fail "migrating pnpm's Pi and Copilot failed: $out"
  [ "$(calls)" = "$HERDR_INSTALL
$PI_INSTALL
$PI_REMOVE
$COPILOT_INSTALL
$COPILOT_REMOVE
$CLAUDE_INSTALL
$(agy_install_line "$home")" ] || fail "migration did not remove pnpm's Pi and Copilot each right after its installer: $(calls)"
  for tool in pi copilot; do
    [ ! -e "$pnpm_bin/$tool" ] || fail "migration left pnpm's $tool"
    [ "$("$home/.local/bin/$tool" --version)" = "$tool-fake" ] || fail "$tool does not run from ~/.local/bin after migration"
  done
  pass "a container with pnpm's Pi and Copilot and a Windows pi ends with only the installers' copies in ~/.local/bin; an offline switch keeps pnpm's Pi"
}

test_pi_installer_failure() {
  local home="$TMP_ROOT/pi-fail" out pnpm_bin
  mkdir -p "$home"
  pnpm_bin="$home/pnpm/bin"
  pnpm_seed "$home/pnpm" @earendil-works/pi-coding-agent
  : >"$NODE_TOOLS_LOG"
  if out=$(PI_FAKE_FAIL=1 PNPM_HOME="$home/pnpm" run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
    fail "a failing Pi installer was accepted: $out"
  fi
  assert_contains "$out" "Pi requires Node.js 22.19.0" "the Pi installer's own error is hidden: $out"
  assert_contains "$out" "cannot install Pi from" "a failed Pi install is not reported: $out"
  [ "$("$pnpm_bin/pi")" = pnpm-pi-fake ] || fail "a failing Pi installer removed pnpm's Pi"
  assert_not_contains "$(calls)" "pnpm remove" "a failing Pi installer removed something: $(calls)"
  pass "a failing Pi installer shows its own output, fails the run, and keeps pnpm's Pi"
}

test_cli_must_run() {
  local tool home out url_var
  for tool in herdr claude agy; do
    home="$TMP_ROOT/$tool-broken"
    mkdir -p "$home"
    # An installer that leaves a binary which cannot run.
    cat >"$FIX/$tool-broken.sh" <<EOF
dir=\$HOME/.local/bin
[ "\${1-}" != --dir ] || dir=\$2
mkdir -p "\$dir"
printf '#!/bin/sh\\nexit 1\\n' >"\$dir/$tool"
chmod +x "\$dir/$tool"
EOF
    case "$tool" in
      agy) url_var=ANTIGRAVITY_INSTALL_URL ;;
      *) url_var="$(tr '[:lower:]' '[:upper:]' <<<"$tool")_INSTALL_URL" ;;
    esac
    if out=$(export "$url_var=file://$FIX/$tool-broken.sh"; PNPM_HOME="$home/pnpm" \
      run_bash_tools "$home" "$FIX/image:$BASE_PATH"); then
      fail "a $tool that does not run was accepted: $out"
    fi
    assert_contains "$out" "$tool --version fails after" "a broken $tool is not reported: $out"
  done
  pass "a herdr, Claude Code, or Antigravity that does not answer --version after it is installed fails the run"
}

# herdr's real installer, as a switch runs it, in a scratch HOME.
test_real_herdr_installer() {
  local home="$TMP_ROOT/herdr-real" latest out
  latest=$(curl -fsSL --connect-timeout 10 https://herdr.dev/latest.json 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  [ -n "$latest" ] || { echo "skip: https://herdr.dev is unreachable"; return 0; }
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  out=$(HERDR_INSTALL_URL=https://herdr.dev/install.sh PNPM_HOME="$home/pnpm" \
    run_bash_tools "$home" "$FIX/image:$BASE_PATH") || fail "herdr's real installer failed: $out"
  [ "$(calls)" = "$PI_INSTALL
$COPILOT_INSTALL
$CLAUDE_INSTALL
$(agy_install_line "$home")" ] || fail "the real herdr install ran fakes other than the Pi, Copilot, Claude Code, and Antigravity installers: $(calls)"
  [ "$(HOME=$home "$home/.local/bin/herdr" --version </dev/null)" = "herdr $latest" ] \
    || fail "$home/.local/bin/herdr is not herdr's latest release $latest"
  [ "$(HOME=$home HERDR_CONFIG_PATH="$ROOT/home/.config/herdr/config.toml" "$home/.local/bin/herdr" config check </dev/null)" = "config: ok" ] \
    || fail "herdr rejects home/.config/herdr/config.toml"
  for rc in .bashrc .bash_profile .profile .zshrc .zprofile .zshenv; do
    [ ! -e "$home/$rc" ] || fail "herdr's installer wrote $rc, which Home Manager owns"
  done

  : >"$NODE_TOOLS_LOG"
  out=$(HERDR_INSTALL_URL=https://herdr.dev/install.sh PNPM_HOME="$home/pnpm" \
    run_bash_tools "$home" "$FIX/image:$BASE_PATH") || fail "a re-run after the real herdr install failed: $out"
  [ -z "$(calls)$out" ] || fail "a re-run after the real herdr install was not a quiet no-op: $(calls) $out"
  pass "herdr's real installer puts herdr $latest at ~/.local/bin/herdr, which accepts the repo's herdr config; re-runs keep it and print nothing"
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

# Runs profile $1's activation snippet $4 (nodeTools or bashTools) the way the
# activation script does (HM's run and warnEcho, errexit), with scratch HOME $2
# and PATH $3.
run_activation() {
  local profile=$1 home=$2 path=$3 name=$4 snippet
  snippet=$(hm_eval --raw "$ROOT#homeConfigurations.\"$profile\".config.home.activation.$name.data") \
    || fail "$profile: no $name activation"
  HOME=$home PATH=$path bash -c '
    set -eu -o pipefail
    run() { "$@"; }
    warnEcho() { echo "WARN: $*"; }
    eval "$1"
    echo "switch continues"' _ "$snippet" 2>&1
}

test_activation() {
  local out after empty home name
  have_linux_nix || return 0
  profiles_init
  # Realize the activation's tool PATH.
  nix build --no-link "$ROOT#homeConfigurations.\"$WS\".activationPackage" \
    "$ROOT#homeConfigurations.\"$CT\".activationPackage" 2>/dev/null || fail "activation packages do not build"
  for profile in "$WS" "$CT"; do
    after=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.activation.nodeTools.after")
    [ "$after" = '["writeBoundary"]' ] || fail "$profile: nodeTools does not run after writeBoundary: $after"
    after=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.activation.bashTools.after")
    [ "$after" = '["writeBoundary","nodeTools"]' ] || fail "$profile: bashTools does not run after writeBoundary and nodeTools: $after"
    empty=$(hm_eval --json "$ROOT#homeConfigurations.\"$profile\".config.home.emptyActivationPath")
    case "$profile" in
      *@container-*) [ "$empty" = false ] || fail "$profile: activation drops the image's PATH" ;;
      *) [ "$empty" = true ] || fail "$profile: workstation activation inherits the user's PATH" ;;
    esac
  done

  home="$TMP_ROOT/act-ws"
  mkdir -p "$home"
  : >"$NODE_TOOLS_LOG"
  for name in nodeTools bashTools; do
    out=$(run_activation "$WS" "$home" "$BASE_PATH" $name) || fail "$WS: $name activation failed: $out"
    assert_not_contains "$out" "WARN" "$WS: a working $name activation warns: $out"
  done
  assert_contains "$(calls)" "nvm install --lts" "$WS: activation did not provision Node.js: $(calls)"
  assert_contains "$(calls)" "$NPM_ADD" "$WS: activation did not install the npm globals: $(calls)"
  assert_contains "$(calls)" "$HERDR_INSTALL" "$WS: activation did not install herdr: $(calls)"
  assert_contains "$(calls)" "$CLAUDE_INSTALL" "$WS: activation did not install Claude Code: $(calls)"
  assert_contains "$(calls)" "antigravity-installer" "$WS: activation did not install Antigravity: $(calls)"
  case "$(calls)" in
    *"npm install -g pnpm"*"antigravity-installer"*) ;;
    *) fail "$WS: Node.js did not come before the curl installers: $(calls)" ;;
  esac

  home="$TMP_ROOT/act-ct"
  mkdir -p "$home"
  out=$(PNPM_HOME="$home/pnpm" run_activation "$CT" "$home" "$BASE_PATH" nodeTools) \
    || fail "$CT: activation without pnpm failed the switch: $out"
  assert_contains "$out" "pnpm not found on PATH" "$CT: activation hides why it failed: $out"
  assert_contains "$out" "WARN: tools/node-tools.sh failed" "$CT: activation does not warn: $out"
  assert_contains "$out" "switch continues" "$CT: activation stopped the switch: $out"
  out=$(PNPM_HOME="$home/pnpm" HERDR_INSTALL_URL="file://$TMP_ROOT/missing.sh" run_activation "$CT" "$home" "$BASE_PATH" bashTools) \
    || fail "$CT: a failing bashTools activation failed the switch: $out"
  assert_contains "$out" "WARN: tools/bash-tools.sh failed" "$CT: the bashTools activation does not warn: $out"
  assert_contains "$out" "switch continues" "$CT: the bashTools activation stopped the switch: $out"
  : >"$NODE_TOOLS_LOG"
  out=$(PNPM_HOME="$home/pnpm" run_activation "$CT" "$home" "$FIX/image:$BASE_PATH" nodeTools) \
    || fail "$CT: activation with the image's pnpm failed: $out"
  [ "$(calls)" = "$NODE_INSTALLS" ] || fail "$CT: activation did not use the image's pnpm and npm: $(calls)"
  pass "nodeTools then bashTools run after writeBoundary in both profiles, use the container's own pnpm, and only warn on failure"
}

# --- shells ---------------------------------------------------------------------

TOOLS="herdr node npm pnpm claude pi copilot agy"

# Checks shell $2's report $3 (NAME=first match, rawpath=PATH, then path=DIR lines) for
# profile $1 in scratch HOME $4: herdr, claude, pi, copilot, and agy are the
# installers' launchers in ~/.local/bin, not the Nix-built herdr left in
# ~/.nix-profile/bin, node, npm, and pnpm are from $5 on the workstation, and
# ~/.local/bin, the nvm default bin (workstation) or ~/.npm-global/bin
# (container), and the pnpm dirs sit right
# before ~/.nix-profile/bin, once each, and PATH has no empty entry.
check_shell() {
  local profile=$1 shell=$2 out=$3 home=$4 node_dir=${5-} tool dir front path
  local pnpm_home="$home/.local/share/pnpm"
  for tool in herdr claude pi copilot agy; do
    grep -qxF "$tool=$home/.local/bin/$tool" <<<"$out" || fail "$profile $shell: $tool is not its installer's launcher: $out"
  done
  front="$pnpm_home/bin:$pnpm_home"
  case "$profile" in
    *@container-*)
      assert_not_contains "$out" "$home/.nvm" "$profile $shell: the container puts nvm on PATH: $out"
      front="$home/.npm-global/bin:$front"
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
  assert_contains "$path" ":$front:$home/.nix-profile/bin:" "$profile $shell: $front is not right before ~/.nix-profile/bin: $path"
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
    # The Nix-built herdr an older switch installed.
    mkdir -p "$home/.nix-profile/bin"
    printf '#!/bin/sh\necho nix-herdr\n' >"$home/.nix-profile/bin/herdr"
    chmod +x "$home/.nix-profile/bin/herdr"
    case "$profile" in
      *@container-*)
        PNPM_HOME="$home/.local/share/pnpm" run_tools "$home" container "$FIX/image:$BASE_PATH" >/dev/null \
          && PNPM_HOME="$home/.local/share/pnpm" run_bash_tools "$home" "$FIX/image:$BASE_PATH" >/dev/null
        ;;
      *)
        run_tools "$home" workstation "$BASE_PATH" >/dev/null && run_bash_tools "$home" "$BASE_PATH" >/dev/null
        ;;
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
        'for c in '"$TOOLS"'; do print -r -- "$c=$(whence -p $c)"; done; print -r -- "rawpath=$PATH"; for p in $path; do print -r -- "path=$p"; done; print -r -- "herdr-completion=${_comps[herdr]-}"' \
        </dev/null 2>/dev/null)
      check_shell "$profile" "interactive zsh${stale:+ ($stale)}" "$out" "$home" "$home/.nvm/versions/node/$FAKE_NODE/bin"
      grep -qxF "herdr-completion=_herdr" <<<"$out" || fail "$profile interactive zsh${stale:+ ($stale)}: herdr's completions are not loaded: $out"
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
  pass "in both profiles every zsh and a bash login shell, fresh or from an environment that already sourced the session variables, run herdr, claude, pi, copilot, and agy from ~/.local/bin, with pnpm's global bins, right before ~/.nix-profile/bin and ahead of its leftover herdr and of system and Windows copies, once each; the workstation adds nvm's default node, npm, and pnpm there and the container ~/.npm-global/bin, and its interactive zsh loads nvm; the interactive zsh loads herdr's completions"
}

test_workstation_fresh_then_quiet
test_only_missing_is_installed
test_container_and_failures
test_step_failures_do_not_block
test_smoke_checks_warn
test_pnpm_policy
test_skill_pin_retries
test_bash_tools_failures
test_antigravity_scratch_home
test_migrate_pnpm_copies
test_pi_installer_failure
test_cli_must_run
test_real_herdr_installer
test_activation
test_shell_path

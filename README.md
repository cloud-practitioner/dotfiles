# dotfiles

<p align="center">
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

Watch the walkthrough: https://youtu.be/5N-okeDdIuI

My personal Mac setup, managed with nix-darwin and home-manager.
One repo, one command, and a fresh Mac ends up configured the same way every time.

It's primarily a macOS (nix-darwin) config, but it also runs on Linux via standalone home-manager - see [Linux](#linux).

## Contributing / Using This Repo

These are my personal dotfiles, shared publicly so people can read them, learn from them, and fork them freely.
Feature requests and pull requests are not accepted here, and PRs are auto-closed.
If you find a bug, please open a GitHub Issue using the bug report template.

## What you get

Running the switch builds:

- System settings (dark mode, key repeat, dock, Finder, trackpad)
- Homebrew apps (casks and CLI tools)
- Nix user packages (ripgrep, fd, fzf, jq, bun, lazygit, Neovim, Hack Nerd Font)
- On Linux, a shared switch-time toolchain of agent CLIs, npm and pnpm global tools (UI5, CAP, MTA, Yeoman generators, ...), and agent skills - see [Upstream CLI tools](#upstream-cli-tools)
- Shell (zsh, aliases, starship prompt)
- Editor (Neovim config with the rose-pine moon theme)
- Terminal (WezTerm config with the rose-pine moon theme and dimmed unfocused windows)
- Agent configs (Claude, Codex, opencode all share one AGENTS.md)
- Optional Pi theme and local extensions, generic UI settings and model overrides, plus two deliberately pinned third-party Pi packages

## Prerequisites

- Apple Silicon Mac, by default.
- Intel Mac: change one line.
  In `configuration.nix`, set `nixpkgs.hostPlatform = "x86_64-darwin";` (the comment right there tells you the same thing).
- Linux (x86_64 or aarch64), any distro with Nix installed: see [Linux](#linux).

## Fresh-machine setup

On a brand new Mac, from a bare clone of this repo:

```sh
git clone https://github.com/cloud-practitioner/dotfiles.git
cd dotfiles
```

Before you run it: review "Make it yours" below.
Change the host label or CPU architecture if needed, and read the Homebrew cleanup warning.
`bootstrap.sh` applies the config to your machine, so do this first.

```sh
./bootstrap.sh
```

`bootstrap.sh` runs a WSL-only systemd preflight (see [Linux](#linux)), then four setup steps in order:

1. Installs Determinate Nix, if it isn't already installed.
2. Makes `~/.dotfiles` reach this repo: leaves it alone if it already resolves here (including a clone directly into `~/.dotfiles`), otherwise creates or re-points a symlink.
   A different real directory or file is refused rather than overwritten.
   This has to happen before the first build, because `home.nix` points at config files through `~/.dotfiles`.
3. Checks the `user` configured in `flake.nix` against your actual username, and offers to fix it for you if they differ.
4. Runs the first switch.
   On macOS it fetches the `darwin-rebuild` tool from the nix-darwin 26.05 release branch, then applies this repo's locked flake config.
   On Linux it runs the first `home-manager switch` instead (see [Linux](#linux)), including the toolchain setup described in [Upstream CLI tools](#upstream-cli-tools).

After that, `darwin-rebuild` exists and you're on the normal workflow below.

### Validate without applying

Once Nix is installed (`bootstrap.sh` step 1 handles that), you can check that the config builds without touching your system - handy when you have edited something:

```sh
nix flake check --no-build
nix build .#darwinConfigurations.mac.system --dry-run
```

If you renamed the host label in "Make it yours", substitute your label for `mac` in these commands.

## Daily use

Edit the config files in place, then apply:

```sh
./rebuild.sh
```

That's it.
No separate build-and-copy step.

### Zsh line editing

After applying `home.nix` changes, open a new zsh session. The shared shell
config uses Windows-style cursor editing on macOS, Linux, and in devcontainers:

- **Ctrl or Alt + Left/Right**, including combinations with Shift, moves by
  word. Word movement stops at punctuation such as `-`, `/`, and `.`.
- **Shift + Left/Right** alone moves by character, without selecting text;
  this configuration does not provide Shift selection.
- **Shift, Ctrl, or Alt + Up/Down**, including their combinations, behaves like
  the plain arrow: move through a multi-line buffer or navigate history.
- **Home/End**, plain or with any of those modifier combinations, moves to the
  start/end of the current line (not the whole buffer, even with Ctrl).

The modified-key bindings handle the xterm sequences sent by Windows Terminal
and Herdr for Shift, Alt, Ctrl, and their combinations, rather than inserting
stray escape-sequence text. `tests/zsh-keymap.test.sh` covers the bindings and
line-editor effects in both Linux profiles.

## Linux

nix-darwin is macOS-only, so on Linux this repo applies just the user-level
config (`home.nix`) with standalone home-manager. The system-level pieces in
`configuration.nix` (macOS defaults, Homebrew) don't apply.

The same two scripts work - they detect the OS with `uname` and branch automatically:

```sh
./bootstrap.sh   # installs Determinate Nix, then runs the first home-manager switch
./rebuild.sh     # re-applies after changes, including missing toolchain installs
```

`bootstrap.sh`, Linux `rebuild.sh`, and the container-only `hm-update` helper all run the Home Manager CLI at the revision pinned in `flake.lock`.

### From-scratch bootstrap (WSL2 workstation)

On a fresh WSL2 distro with systemd enabled (see the WSL2 + systemd note below), clone straight into `~/.dotfiles` and bootstrap:

```sh
git clone https://github.com/cloud-practitioner/dotfiles.git ~/.dotfiles && ~/.dotfiles/bootstrap.sh
```

Every step checks before acting, so re-running `bootstrap.sh` does nothing beyond the Home Manager switch.

On the WSL2 workstation, pick up changes pushed to this repo by pulling and re-applying:

```sh
git -C ~/.dotfiles pull --ff-only && ~/.dotfiles/rebuild.sh
```

There is deliberately no `hm-update` on WSL2; that shortcut exists only inside a devcontainer (see [Devcontainers](#devcontainers)).

What you get on Linux:

- Nix user packages: ripgrep, fd, fzf, jq, bun, lazygit, Neovim, Hack Nerd Font.
- WezTerm from nixpkgs, the Linux equivalent of its macOS cask.
- Shared toolchain installation in both Linux profiles - see [Upstream CLI tools](#upstream-cli-tools).
- The same symlinked shell (zsh + starship), Neovim, WezTerm, and agent configs as macOS.
- Git identity by remote URL and SSH client config, both rendered from your own `~/.config/dotfiles/identity.env`, and an `ssh-agent` systemd user service on the workstation profile - see [Git identity](#git-identity) and [SSH](#ssh-workstation-profile).
- A `container` profile that reuses the same shell and tools inside a devcontainer - see [Devcontainers](#devcontainers).

Notes:

- **Distro-agnostic**: works on any Linux distro (and WSL) once Nix is installed. home-manager is user-level and never touches apt/dnf/pacman.
- **Login shell**: home-manager can't change your login shell. To use zsh, run once `chsh -s "$(command -v zsh)"`, then open a new terminal. `bootstrap.sh` prints this reminder.
- **herdr and Claude Code** come from Homebrew on macOS (`configuration.nix`); Pi, the Copilot CLI, and Antigravity are not installed there, and none of the Node.js setup below applies.
- Applying is per-user, so there's no `sudo` on Linux.
- **WSL2 + systemd**: the `ssh-agent` service is a systemd *user* service, so WSL2 needs systemd enabled. Add `[boot]` / `systemd=true` to `/etc/wsl.conf`, then `wsl --shutdown` and reopen; otherwise the agent never starts and `SSH_AUTH_SOCK` stays empty. The Determinate Nix daemon needs it too, so `bootstrap.sh` refuses to run on WSL without it.

### Upstream CLI tools

Home Manager owns toolchain installation on Linux, in both profiles (workstation and container), outside the Nix store; the devcontainer image overlap is described below.
The agent CLIs and npm/pnpm global tools are unpinned: missing tools install at the latest release, not as Nix derivations. The `resolving-merge-conflicts` skill is deliberately pinned, as described below.
The authoritative install lists live in [`tools/node-tools.sh`](tools/node-tools.sh) and [`tools/bash-tools.sh`](tools/bash-tools.sh).
Every switch runs both scripts as `home.activation` steps, `nodeTools` first and `bashTools` after it, since Pi's installer needs Node.js.
A failing step prints a warning and the switch still completes; the next switch retries.
Install steps skip existing CLIs and global packages, so a healthy re-switch is quiet and cheap; switches do not upgrade them (use the tools' own updaters, below, or remove a tool before switching to refresh it). Skill presence and pin checks are described below.

**herdr, Claude Code, Pi, the GitHub Copilot CLI, and Antigravity** come from the vendor installers invoked by `tools/bash-tools.sh`.

Each installer puts its launcher in `~/.local/bin` (`herdr`, `pi`, `copilot`, `claude`, `agy`), and each CLI must answer `--version` after it is installed.
The Pi and Copilot installers run without a controlling terminal, so they never prompt or edit `~/.zshrc`, `~/.bashrc`, or `~/.profile`. Antigravity also runs without a controlling terminal; its rc-file isolation is described below.

- **herdr**'s installer (its [documented install](https://herdr.dev/docs/install/)) puts its static release binary, checked against the SHA-256 in `https://herdr.dev/latest.json`, at `~/.local/bin/herdr`.
  It needs no Node.js.
  The interactive zsh loads its completions from that binary (`herdr completion zsh`).
  Older switches installed a Nix-pinned herdr in `~/.nix-profile/bin`; the next switch removes it, and a herdr server started before then keeps running the old version until you restart it.
- **Pi** gets a Pi-managed install under `~/.pi/agent/install` (or `$PI_CODING_AGENT_DIR/install`) with pinned dependencies, on the Node.js and npm that the profile provides (below); `~/.local/bin/pi` links to its launcher in the `bin` directory beside it.
  Pi's installer migrates an npm-installed Pi itself but refuses to replace any other, so it runs without pnpm's global bin directories or the Windows `PATH` (`/mnt/*`) on its `PATH`; once the new `pi` answers `--version`, a switch removes the `pnpm add -g` copy that an older switch installed (`pnpm remove -g @earendil-works/pi-coding-agent`), so a failed install keeps the old one.
- **The GitHub Copilot CLI** is its release binary at `~/.local/bin/copilot`; once it answers `--version`, a switch removes the `pnpm add -g @github/copilot` copy that an older switch installed.
- **Claude Code** comes from its native installer: its updater only knows npm and native installs, so it would put every update of a pnpm copy into npm's global prefix, where the pnpm copy keeps shadowing it.
  The native launcher is always `~/.local/bin/claude`, and its updater re-points it in place; the installer also removes a leftover npm-global copy.
- **Antigravity** is the `agy` binary at `~/.local/bin/agy` (checked against the SHA-512 in its release manifest; it updates itself in the background).
  Its installer ends by running `agy install`, which appends a PATH export to `~/.zshrc`, `~/.bashrc`, and `~/.profile`, and the script has no flag to turn that off.
  So a switch runs it with a scratch `HOME` and `--dir ~/.local/bin`: the binary lands in the real `~/.local/bin`, the rc files that the installer edits are the scratch home's, and that directory is removed afterwards.
  Download failures are reported separately from installer execution failures; for the latter, the installer's output appears above the failure message.

Their own updaters (`herdr update`, `claude update`, `pi update`, `copilot update`, and `agy`'s) keep them current.

**The pnpm and npm global tools and the agent skills** (`tools/node-tools.sh`) install on the profile's Node.js (below). See its `PNPM_PACKAGES` and `NPM_PACKAGES` arrays for the package lists and `ensure_skills` for the skill sources and pinned revision, migrated from the `agentic-devcontainer` Dockerfile.
Yeoman and its generators must use npm, not pnpm: `yo` only discovers generators under npm's global prefix. The npm globals use `--allow-scripts=mbt,mta`; on amd64, `@sap/cf-tools-local` is installed separately with `--allow-scripts=@sap/cf-tools-local`.

A pnpm package counts as missing when pnpm's global list lacks it; an npm package counts as missing when its `package.json` is absent under `npm root -g`. A skills source is installed when its marker skill's `SKILL.md` (`explain-abap-code`, `tdd`, `find-skills`) is absent from `~/.agents/skills`. The pinned `resolving-merge-conflicts` needs both its `SKILL.md` and the pinned source/revision in the skills CLI's lock metadata (`~/.agents/.skill-lock.json`, or `$XDG_STATE_HOME/skills/.skill-lock.json` when set); a bulk install or an interrupted switch cannot make an unpinned copy satisfy that check, and the next switch retries the pin.
The `skills` CLI reads `owner/repo@X` as a skill name, so there is no `@latest` on them, and `--agent universal` is required (`--yes` alone targets 50+ agent config directories).
Afterwards the script checks that `find-skills` and `resolving-merge-conflicts` are there and that the latter's lock metadata identifies the pin.
Before a pnpm global install, the script sets `allowBuilds` in the global directory's `pnpm-workspace.yaml`: `better-sqlite3: true`, `esbuild: true`, `edgedriver: false`, and `geckodriver: false`. It preserves other entries and top-level settings in the simple block mapping that pnpm writes. An unsupported shape (such as a flow-style `allowBuilds` mapping) is left unchanged with a warning, and that pnpm install is skipped; convert it to a simple block mapping and switch again.
Every switch also runs the smoke checks once Node, npm and pnpm are available, even if packages were already installed or a global install failed, and prints warnings (never fails the switch): `mbt --version` and `mta --version`; `yo --generators --no-insight` lists `easy-ui5`, `@sap-ux/adp`, `@sap/adaptation-project`, `@sap/add-hdb-module`, `@sap/aicore`, `@sap/base-mta-module`, `@sap/cap-project`, and `@sap/fiori`; and `cf plugins` lists `ServiceInfo` on amd64. A missing `cf` on amd64 warns that ServiceInfo could not be verified. Every switch also attempts a policy check of the FAB write lane's deny list with the installed ARC-1 (arc-1 floats to `@latest`, never pinned): its only ARC-1 invocation runs `arc1-cli call SAPTransport --json '{"action":"release",...}'` in an empty temp directory with a scrubbed environment (`env -i`, dummy credentials, `SAP_URL=http://127.0.0.1:9`, no network to SAP, fixed 60 s timeout with a 5 s forced-kill grace period) and the arc-dgw-fab settings (`SAP_ALLOW_WRITES`, `SAP_ALLOW_TRANSPORT_WRITES`, `SAP_ALLOWED_PACKAGES`, and a `SAP_DENY_ACTIONS` covering `SAPTransport.release`, `release_recursive`, `delete`, `reassign`, `remove_object`). A prerequisite setup abort warns that the FAB write lane is unsafe with this ARC-1 install because its deny list is unproven and the policy check did not run. A missing `arc1-cli`, scratch-directory setup failure, timeout (even after partial denial output), or anything but `denied by server policy (SAP_DENY_ACTIONS)` (a non-denial, a CLI error, a rejected action name) produces the same unsafe/unproven warning; a completed denial is accepted even when ARC-1 exits nonzero. The switch still completes.

npm's global prefix is `$NPM_CONFIG_PREFIX` in the container (the image sets it to `~/.npm-global`; the profile and the script default to it) and nvm's default Node.js directory on the workstation, since nvm refuses `NPM_CONFIG_PREFIX`; a different default Node.js has its own prefix, so the next switch installs the npm globals again into it.
Either `bin` is on every shell's `PATH` (below), so `yo`, `mbt`, and `mta` run, and `yo` finds its generators there.

Where Node.js and pnpm come from depends on the profile:

- **WSL2 workstation**: `tools/node-tools.sh` first installs nvm with its official install script (`PROFILE=/dev/null`, so it never edits `~/.zshrc`, `~/.bashrc`, or `~/.profile`), then `nvm install --lts` as nvm's default, then `npm install -g pnpm`, the way [Microsoft's Node.js on WSL guide](https://learn.microsoft.com/en-us/windows/dev-environment/javascript/nodejs-on-wsl) does it. The interactive workstation zsh loads nvm (`$NVM_DIR`, default `~/.nvm`), so `node`, `npm`, and `pnpm` are nvm's there. Every switch also links `$NVM_DIR/default` to nvm's default Node.js, and `$NVM_DIR/default/bin` is on every shell's `PATH` (see below), so scripts and `wsl.exe -e zsh -c ...` find them without loading nvm; after `nvm alias default ...`, switch again to move that link. As that guide advises, don't install another Node.js alongside it.
- **Devcontainer**: the image (`cloud-practitioner/agentic-devcontainer`) brings its own Node.js 24 and Corepack pnpm (with `PNPM_HOME`), so the container profile has no nvm and its activation keeps the image's `PATH` to find them. The dotfiles change lands first; a separate image change removes the tool installs afterwards. Until then both install the same globals idempotently, which is harmless; after that the container profile is their only source.

Both profiles set `PNPM_HOME` (unless already set, default `${XDG_DATA_HOME:-~/.local/share}/pnpm`, as pnpm itself) and put `~/.local/bin` (herdr, Claude Code, Pi, Copilot, Antigravity), on the workstation `$NVM_DIR/default/bin` (or in the container `$NPM_CONFIG_PREFIX/bin`, default `~/.npm-global/bin`, which the profile also exports), then pnpm's global bin directories (`$PNPM_HOME/bin`, then `$PNPM_HOME` for older pnpm) on `PATH` right before `~/.nix-profile/bin` (or first, without it), once each.
That puts them ahead of the Nix profile, the system directories, and the Windows `PATH` that WSL appends (`/mnt/c/...`), so a Nix-built `herdr` or a Windows Node.js or npm-global `claude`, `pi`, `copilot`, `agy`, `node`, `npm`, or `pnpm` never shadows these.
Every zsh (through `~/.zshenv`, interactive or not, and again at the end of the interactive `~/.zshrc`, after nvm) and every bash login shell (through the Home Manager-owned `~/.bash_profile`, which then reads your own `~/.profile`) gets them, even when started from an environment that already has the Home Manager session variables; a pre-existing `~/.bash_profile` blocks `./rebuild.sh` (`bootstrap.sh` and `hm-update` rename it to `~/.bash_profile.backup` instead), so merge its contents into `~/.profile` and remove it.
A copy installed in a directory ahead of `~/.nix-profile/bin` on `PATH` still comes first, so don't install another `herdr`, `claude`, `pi`, `copilot`, or `agy` there.

Apply changes the same way in each environment:

- **WSL2 workstation**: pull and re-run `rebuild.sh`, as [Linux](#linux) shows.
- **Devcontainer**: `hm-update`, as [Devcontainers](#devcontainers) shows.

To check without applying, `bash tests/upstream-tools.test.sh` checks that neither profile installs Nix-built copies of the agent CLIs, and `bash tests/node-tools.test.sh` checks both install scripts against local fakes, and herdr's against its real installer. The latter requires Node.js and pnpm on `PATH` for semantic checks of generated pnpm configuration, plus GNU `timeout` for the policy-check fixtures.

### Git identity

`identity.env` applies to the **Linux workstation (including WSL2) and the
devcontainer only**. macOS Git configuration remains unmanaged: set your name
and email with `git config --global user.name "Your Name"` and
`git config --global user.email you@example.com`. Its SSH setup is described in
[SSH](#ssh-workstation-profile); macOS identity support is a separate follow-up.

On Linux, no personal identity value lives in this public repo. Your names,
emails, the GitHub organisations and Bitbucket workspaces you work in, and the
paths of your SSH keys go in one non-secret file on the workstation,
`~/.config/dotfiles/identity.env`, which every Linux switch turns into git config.
Git then picks the commit name, email, and SSH key from a repo's **remote URL**,
not from the folder it sits in:

- `activation/identity.sh` runs on every Linux switch (`render`, then `check`).
  It writes `~/.config/git/identities.gitconfig`, which `programs.git` includes,
  with one `includeIf "hasconfig:remote.*.url:..."` rule per owner and per URL
  spelling (`git@host:owner/**`, `ssh://git@host/owner/**`, `https://host/owner/**`,
  `https://user@host/owner/**`, plus `git@alias:owner/**` and
  `ssh://git@alias/owner/**` when you set a legacy SSH alias), each pointing at
  `~/.config/git/identity/<label>.gitconfig`: `user.name`,
  `user.email`, and `core.sshCommand = ssh -i '<key>' -o IdentitiesOnly=yes`
  (with `-F ~/.ssh/config.d/identities` in the container, so legacy aliases resolve and the pinned host keys apply).
- `programs.git` itself sets `user.useConfigOnly = true` (a repo whose owner
  matches no identity **refuses the commit** instead of guessing one) and includes
  the rendered file. `pushInsteadOf` sends pushes for plain `https://github.com/`
  and `https://bitbucket.org/` remotes over SSH, while their fetch URLs stay HTTPS.
  User-qualified HTTPS remotes (`https://user@host/...`) deliberately select the
  commit identity but keep pushing over HTTPS for credential-based access.
  There are no folder (`gitdir:`) rules and no `insteadOf`.
- Needs git 2.36 or later; older git ignores the rules silently, so the check
  reports the version. A repo with remotes on two identities gets the later one in
  `IDENTITIES`, and owners match case-sensitively, as spelled in the remote URL.
- The rendered files are rewritten only when their content changes, and removed
  when `identity.env` goes away. Edit `identity.env`, never the rendered files.
- `git config --global` writes fail on the read-only Home Manager file; reads
  still work. That is intended. `GIT_CONFIG_GLOBAL` set, or a `~/.gitconfig` with
  `user.`, `includeIf.`, `url.` or `core.sshCommand` keys, including keys reached through its
  includes (git reads it last),
  would mask the identities, so the check flags both. Unreadable or malformed
  Git configuration is reported separately.

**Template walkthrough.** On a fresh Linux workstation the first switch (and every new
interactive zsh, with one line) says there is no identity file yet. Then:

1. Copy the template and edit it:
   `install -D -m 600 ~/.dotfiles/identity.env.example ~/.config/dotfiles/identity.env && ${EDITOR:-nvim} ~/.config/dotfiles/identity.env`
2. List your identity labels in `IDENTITIES`, and per label set `<label>_HOST`
   (`github.com`, `bitbucket.org`), `<label>_OWNERS` (space-separated orgs or users,
   as in the remote URL), `<label>_KEY` (the private key's absolute or `~/` path), `<label>_NAME`,
   `<label>_EMAIL`, and optionally `<label>_ALIAS` (a legacy SSH host alias such as
   `github.com-work`, for old `git@github.com-work:org/repo` remotes). The file is
   parsed, never sourced: surrounding double quotes are stripped, but `$(...)`
   and variables are not expanded. `_KEY` may only contain letters, digits,
   `.`, `_`, `/`, `-` (and a leading `~`), and names and emails may not contain
   `"` or `\`. A bad value is reported and that identity skipped.
3. Switch (`./rebuild.sh`). The check prints the exact command for each problem and
   never runs it: the `ssh-keygen -t ed25519 -C '<email>' -f <key>` for a missing key
   plus where to register its `.pub`, `chmod 600` for a loose key, `ssh-add <key>`
   for a key the agent lacks, and so on. Run the command, then switch again, or
   re-check any time with `~/.dotfiles/activation/identity.sh check workstation`
   (exit status 1 on problems; the switch itself only warns).

**Secrets.** Private keys are never created, read, copied, or printed by this
tooling: it only tests that a key file exists and its mode, and reads the `.pub`
beside it. The workstation switch also exports each identity's `.pub` (only if
its first token is an OpenSSH public-key type) to
`~/.config/dotfiles/pub/<label>.pub`. For container sharing and revision
following, see [Devcontainers](#devcontainers).
`identity.env` is in `.gitignore` in case you ever copy it into the repo.

`bash tests/identity.test.sh` covers the renderer and checks against scratch
homes, throwaway keys, and a throwaway agent: a fresh workstation, a missing and
an unloaded key, the routing table for each URL spelling, the container render
from a read-only directory, `GIT_CONFIG_GLOBAL`, bad values, and stale outputs.

### SSH (workstation profile)

On macOS, `programs.ssh` keeps the existing `github.com-personal`,
`github.com-work`, and `bitbucket.org-work` aliases and their hard-coded key paths.
To adapt them, edit `sshKeys` and `programs.ssh.settings` in `home.nix`, and put
your private keys in `~/.ssh` yourself (mode 600).

On the Linux workstation, `programs.ssh` writes `~/.ssh/config`: the `*` defaults
this repo has always kept and an `Include ~/.ssh/config.d/identities`, which
`activation/identity.sh` renders from `identity.env`. A systemd user service runs
`ssh-agent` so `SSH_AUTH_SOCK` is set on every login.

Git picks its SSH key by remote URL (see [Git identity](#git-identity)), so you
only need an SSH host alias for old remotes such as `git@github.com-work:org/repo`.
Set `<label>_ALIAS` in `identity.env` and the include gets a `Host <alias>` block
(`HostName`, `User git`, the identity's key, `IdentitiesOnly yes`). Outside a
repo (`ssh -T git@github.com`, a `git ls-remote` of a bare URL) no identity
applies, so use the alias, or `-i <key>`.

The **private keys are not managed by Nix** - create them yourself (the check
prints the `ssh-keygen` command) with mode 600. The agent starts empty on every
WSL2 start, so whenever it is empty an interactive workstation zsh loads the keys
named in `identity.env` (the switch renders their paths to
`~/.config/dotfiles/ssh-keys`) at startup - it may ask for their passphrases
once - and they are ready before `devcontainer up`. `AddKeysToAgent yes` still
loads a key into the agent the first time it's used. The `*` block lists every
default this config keeps, because Home Manager's implicit defaults are off
(`enableDefaultConfig = false`); see `man ssh_config` for the directive names.
`bash tests/ssh-config.test.sh` checks the generated `~/.ssh/config`, a rendered
alias, the global git config, and that no profile evaluates with a Home Manager
warning; `bash tests/ssh-agent-autoload.test.sh` checks the key autoload and the
missing-`identity.env` line.

#### SSH in the container profile

The `container` profile also writes `~/.ssh/config` (it used to be a static file the
devcontainer image wrote): `Include ~/.ssh/config.d/*` and the `*` defaults
`AddKeysToAgent yes`, `StrictHostKeyChecking accept-new`, `ServerAliveInterval 60`,
and `UserKnownHostsFile ~/.ssh/known_hosts`. It has no keys of its own: the agent
is the workstation's, and the rendered `~/.ssh/config.d/identities` holds only the
optional aliases.

The official host keys of `github.com` and `bitbucket.org` are committed in
`ssh/pinned_known_hosts` (every key type each forge publishes, with the source and
fingerprints in the file's comments) and linked read-only as
`~/.ssh/pinned_known_hosts`; the image no longer needs `ssh-keyscan`. For those two
hosts, `~/.ssh/pinned-hosts.conf` makes that file the only one consulted and sets
`StrictHostKeyChecking yes`: with the keys pinned there is nothing to trust on first
use, and a changed or unlisted key fails closed instead of being learned. It
matches on the target hostname, so legacy aliases are covered, and it is included
from `~/.ssh/config` and from the end of `~/.ssh/config.d/identities`, because git's
`core.sshCommand` runs `ssh -F ~/.ssh/config.d/identities`, which never reads
`~/.ssh/config`. Every other host keeps `accept-new` and the writable
`~/.ssh/known_hosts`, which this repo never links or replaces. When a forge rotates
a host key, update `ssh/pinned_known_hosts` from the sources named there; until then
SSH to it refuses with a host-key error.

The switch also makes `~/.ssh` and `~/.ssh/config.d` mode 700. If an older image
already wrote `~/.ssh/config`, a switch with `-b backup` (what the devcontainer's
`post-create.sh` runs) moves it aside as `~/.ssh/config.backup`; without `-b` the
switch stops on the collision.

### Secrets (Linux)

Nix doesn't manage secrets, but every zsh on Linux, including non-interactive
`zsh -c` shells, exports the credentials you keep in `*.env` files under
`/workspaces/*/.secrets/` (the devcontainer's persistent mount) or
`~/.secrets/`, e.g. `export NO_MISTAKES_BITBUCKET_API_TOKEN=...`. Files load in
name order, silently. The rules:

- The `.secrets` folder must be a real directory (not a symlink) that you own
  and that group and others cannot access: `chmod 700 .secrets`. Any other
  folder is ignored, so a `.secrets` folder that `git` checks out under
  `/workspaces` (mode 755) never loads.
- Each `*.env` file must be a regular file (not a symlink) that you own and that
  group and others cannot write; use `chmod 600`.
- A file with a syntax error is skipped whole, and nothing a file prints is
  ever shown.

`bash tests/secrets-env.test.sh` checks these rules.

### Devcontainers

`home.nix` takes a `profile` argument. The `container` profile reuses everything
(zsh, starship, packages, tools) but drops the host SSH machinery - no agent
service, no startup key loading, no host aliases - because a container has no
systemd and uses the forwarded workstation agent instead. It keeps a small
`~/.ssh/config` with the pinned GitHub and Bitbucket host keys, see
[SSH in the container profile](#ssh-in-the-container-profile). Identity sharing
requires the workstation's `~/.config/dotfiles` mounted read-only at the same
home-relative path in the container, plus the agent socket exposed through
`SSH_AUTH_SOCK`. This directory contains the non-secret identity file and the
exported public halves described in [Git identity](#git-identity); do not mount
`~/.ssh` or copy private keys into the container. The renderer selects agent
keys using those public halves and supplies its own SSH alias include for Git.

Mount and socket wiring is managed separately in
`cloud-practitioner/agentic-devcontainer`. Images that still mount `~/.ssh` or
recreate hard-coded aliases must be adapted to the public-key-only contract
before using identity sharing. Without the identity directory or a reachable
forwarded agent, the switch warns with workstation setup guidance.

`flake.nix` exposes both profiles as home-manager configs:

```
dev@x86_64-linux             # WSL2 / Linux workstation (full profile)
dev@container-x86_64-linux   # container as user "dev"
node@container-x86_64-linux  # container as user "node"
```

For toolchain ownership and the image rollout, see
[Upstream CLI tools](#upstream-cli-tools). Inside
a container, `hm-update` fetches `~/.dotfiles` and makes a detached checkout of
`~/.config/dotfiles/applied-rev`, which the workstation writes on every switch
from the flake revision. A `-dirty` suffix warns and uses its base commit, not
the workstation's uncommitted edits; an unavailable revision warns and falls
back to `origin/main`. With no readable, nonempty revision file, it pulls
fast-forward on the current branch (returning a detached checkout to `main`
first). It then re-switches the container profile. The shortcut exists only in
the container profile, and a new terminal's welcome note reminds you of it;
`bash tests/hm-update.test.sh` checks it.

**Claude Code and `CLAUDE_CONFIG_DIR`.** Claude reads its user config from
`$CLAUDE_CONFIG_DIR` when set (a devcontainer may point it into the workspace),
else `~/.claude`. `~/.claude/settings.json` and `~/.claude/CLAUDE.md` link into
this repo like every other config. When `$CLAUDE_CONFIG_DIR` points elsewhere,
activation also installs the Claude files there:

- `home/.claude/settings.json` is merged into `$CLAUDE_CONFIG_DIR/settings.json`
  (a one-time `settings.json.pre-dotfiles-<epoch>` backup is kept): each apply
  adds only the settings keys and hook commands missing there and never changes
  a value already there, so changing an existing value in
  `home/.claude/settings.json` does not carry over; edit it in
  `$CLAUDE_CONFIG_DIR/settings.json` directly. `CLAUDE.md` is linked only if
  absent.
- `~/.claude/settings.json` and `~/.claude/CLAUDE.md` then point into
  `$CLAUDE_CONFIG_DIR`, so tools that edit them (hook installers) change the
  files Claude reads.
- Skills move one way: each entry of a real `~/.claude/skills` directory moves
  into `$CLAUDE_CONFIG_DIR/skills` unless that name already exists there.
  Then a link that cannot be the skill to keep goes instead: a dangling
  `~/.claude` link is removed, a dangling configured link (or one reaching the
  skill only through the `~/.claude` entry) is replaced by that entry, and a
  `~/.claude` link reaching the same skill, as a container rebuild re-creates
  them, is removed as a duplicate. Only two live, different skills stay put,
  with a warning. Once `~/.claude/skills` is empty it becomes a link
  to `$CLAUDE_CONFIG_DIR/skills`, so later installs land there.
  From then on, each apply re-points a dangling link in
  `$CLAUDE_CONFIG_DIR/skills` (such as a relative link the `skills` CLI
  installs through `~/.claude/skills`) at `~/.agents/skills/<name>`, and warns
  about one with no copy there; re-install or remove that skill.

Activation only sees the variable if the shell that runs it has it, so run
`hm-update` (devcontainer) or `rebuild.sh` from a shell where it is set (on macOS,
`sudo darwin-rebuild` drops it, so the `~/.claude` fallback applies there).
Applying later from a shell without it stops at Home Manager's collision check
on those two `~/.claude` links; delete them, or apply from a shell that has the
variable. The rules live in `activation/claude-config.sh`;
`tests/claude-config.test.sh` checks them.

Container usernames come from the `containerUsers` list in `flake.nix` (a
devcontainer base image's non-root user, e.g. `node`), so nothing rewrites `user`
at runtime. `rebuild.sh` auto-detects a container (`/.dockerenv`,
`$REMOTE_CONTAINERS`, `$CODESPACES`) and selects the matching `…@container-…`
config; on a plain WSL2 host it uses the workstation config.

## Make it yours

This repo is mine.
If you clone it, review these before you run `bootstrap.sh`:

- **Username**: run `./bootstrap.sh` (it detects your workstation username and offers to set it) OR change the single `user` setting in `flake.nix`.
  Everything else (`configuration.nix`, `home.nix`, home directory paths) is threaded from that one variable.
- **Host label** `"mac"`, in three places: `flake.nix` (the `darwinConfigurations."mac"` name), `rebuild.sh` (the `#mac` at the end of the flake reference), and `bootstrap.sh`'s first-switch command (also `#mac`).
  All three have to match.
- **CPU architecture**, `hostPlatform` in `configuration.nix` (see Prerequisites above).
- **Container users** (Linux): if a devcontainer's non-root user differs from your workstation username, add it to the `containerUsers` list in `flake.nix` so a `…@container-…` config exists for it.
- **Git and SSH identity**: follow [Git identity](#git-identity) for the Linux template walkthrough and macOS Git setup, and [SSH](#ssh-workstation-profile) for workstation keys and aliases.

**Homebrew cleanup warning:** `configuration.nix` sets `homebrew.onActivation.cleanup = "zap"`.
That means every time you switch, Homebrew removes any package or cask on your machine that isn't listed in the `brews` and `casks` arrays in `configuration.nix`.
If you already have Homebrew stuff installed that isn't in that list, the first switch will uninstall it.
Read through `brews` and `casks` before you run `bootstrap.sh` or `rebuild.sh` for the first time, and add anything you want to keep.

**About `herdr`:** it's in the `brews` list.
It's a real public Homebrew formula (`brew info herdr` finds it in homebrew-core, no tap needed), so it will install fine.
If you don't use it, just remove it from `brews` in your copy.

**Heads-up:**

- `home/AGENTS.md` is my personal agent policy, and `home.nix` installs it for Claude, Codex, and opencode.
  If you clone this repo, you'd silently inherit my agent instructions - edit or delete `home/AGENTS.md` if you don't want that.
- The `cc` and `co` shell aliases in `home.nix` are high-agency shortcuts: `claude --dangerously-skip-permissions` and `codex --full-auto`.
  They're convenient for me, but know what they do before you use them.

## Repo tour

- `flake.nix` - the entry point.
  Wires up nixpkgs, nix-darwin, home-manager, and nix-homebrew, declares the `mac` machine, and generates the Linux home-manager configs (workstation + `container` profiles for each user in `containerUsers`).
- `configuration.nix` - system-level config: macOS defaults, Homebrew.
- `home.nix` - user-level config: shell, packages, prompt, git, SSH, and the symlinks described below. Takes a `profile` argument (`workstation` or `container`).
- `tools/node-tools.sh` - installs, at every Linux switch, the pnpm and npm global tools and the agent skills (plus nvm, Node.js, and pnpm on the WSL2 workstation).
- `tools/bash-tools.sh` - installs herdr, Claude Code, Pi, the Copilot CLI, and Antigravity from their own installers at every Linux switch.
- `identity.env.example` and `activation/identity.sh` - the template for your git and SSH identities, and the renderer and checker that apply it.
- `tests/` - behavior tests; run one with `bash tests/<name>.test.sh`.
- `activation/claude-config.sh` - the activation steps that install the Claude Code files into `$CLAUDE_CONFIG_DIR` when it points somewhere other than `~/.claude` (see [Devcontainers](#devcontainers)).
- `rebuild.sh` - re-applies the config after the first switch.
  Auto-detects a devcontainer and picks the container profile; otherwise uses the workstation profile. Run this every time you make a change; to pick up pushed changes on WSL2, pull first (see [Linux](#linux)).
- `home/` - the actual config files that get symlinked into place; the sections below explain the shared symlink model and Pi's narrower selective setup.

## How the symlinks work

The files under `home/` are the real files - editing them here is editing your live config, no rebuild needed to see the change in your editor.
`home.nix` uses `mkOutOfStoreSymlink` to point paths like `~/.config/nvim` straight at `home/.config/nvim` in this repo, so the two never drift out of sync.
You only run `./rebuild.sh` when you change something that isn't just a symlinked file, like a package list or a system default.
The one exception is Claude Code's settings when `CLAUDE_CONFIG_DIR` points elsewhere: re-applying adds only keys and hook commands missing from `$CLAUDE_CONFIG_DIR/settings.json`, and changes to existing values must be made in that file directly (see [Devcontainers](#devcontainers)).

For herdr, only `~/.config/herdr/config.toml` links into this repo; `~/.config/herdr` stays a real directory for runtime state (`session.json`, `session-snapshots/`, sockets, logs). On the next switch, activation removes only the legacy Home Manager-owned whole-directory symlink before linking the file; real directories and user-owned symlinks are left alone. Existing runtime files in the checkout are not moved. This prepares the directory for a persistent devcontainer bind mount, which ships separately; this dotfiles change alone does not preserve sessions across container rebuilds.

The herdr config sets `resume_agents_on_restore = false`: restored panes come back as plain shells rather than auto-resuming agents, on the WSL2 workstation as well as in devcontainers. Firstmate is responsible for relaunching its workers.

## Optional Pi configuration

On Linux, both home profiles install Pi, unpinned, with its official installer (see [Upstream CLI tools](#upstream-cli-tools)). On macOS, Pi is opt-in: install it from its owner with the [official Pi instructions](https://pi.dev), for example:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

[Pi Launcher](https://github.com/kunchenguid/homebrew-tap) is also optional and installed from its owner, not declared by this config:

```sh
brew install --cask kunchenguid/tap/pi-launcher
```

Home Manager owns exactly two repository-authored Pi directories: `~/.pi/agent/themes` and `~/.pi/agent/extensions`. It also links `models.json` and `settings.json` as individual files. The local extension directory is for public, repository-authored extensions only - third-party package code never belongs there. Run `/reload` after editing a local extension or other Pi resources. The terminal-title extension shows a spinner while Pi is working, then a completion mark with the session name or current directory. The `rose-pine-moon` theme was authored clean-room from the public [Rosé Pine Moon palette](https://rosepinetheme.com/palette) and Pi's [public theme schema](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json), not from a private or live theme file.

### Pi Calm

`home/.pi/agent/extensions/calm` is a standalone local Pi extension. Home Manager's existing global extensions-directory link makes Pi auto-load it without another declaration. `/calm` toggles a conversation-only presentation mode and is off by default. Its choice is stored locally in `~/.pi/agent/calm` (or the directory selected by `PI_CODING_AGENT_DIR`), not in this repository or Home Manager. Adapted from Firstmate under the bundled MIT license, Calm imports no Firstmate modules and has no Firstmate runtime dependency.

When enabled, Calm hides collapsed thinking and the call/result shells for Pi's seven built-in tools (`read`, `bash`, `edit`, `write`, `grep`, `find`, and `ls`) without leaving blank transcript rows. During an active run it replaces Pi's working row with a two-line animated blue-water, yellow-boat widget. `/calm` restores Pi's stock rendering and preserves the existing Ctrl+O tool-expansion choice.

Calm never changes prompts, tool execution, model context, session data, or ordering. `/share` and `/export` use the complete stock transcript. Generic custom tools, images, and unsupported Pi transcript classes deliberately remain visible because Pi has no safe general-purpose transcript filter. If a future Pi release no longer exports the exact collapsed-thinking rendering seam, Calm logs one diagnostic and leaves only that adapter disabled; all other behavior remains available.

Pi's package system declares two third-party sources in the linked global `settings.json`:

- `npm:pi-web-access@0.14.0` - the exact public npm release for web access.
- `npm:@ryan_nookpi/pi-extension-codex-fast-mode@0.2.6` - the exact public npm release from `ryan_nookpi`.

The versions are immutable pins, so Pi does not move them during package updates. Deliberate updates require a new source and security audit, followed by an explicit pin change in `home/.pi/agent/settings.json`. Pi's global settings declarations install missing pinned packages automatically at startup. No one-time install command is required. Pi keeps the downloaded npm package trees in its own unmanaged `~/.pi/agent/npm` runtime directory, outside Home Manager and Git tracking.

Both packages execute with your full user permissions and must be trusted like any other executable code.

Home Manager deliberately does not manage `~/.pi/agent` itself, or Pi authentication, sessions, trust decisions, caches, npm/git package trees, or any other runtime state. The model overrides contain no credentials or endpoint settings, do not choose a default model, and only take effect after you authenticate Pi yourself. This remains an additive post-video layer: it does not add a launcher or package source code to this repository.

## Notes

The first time you launch `nvim`, it bootstraps [lazy.nvim](https://github.com/folke/lazy.nvim) by cloning plugins from GitHub.
That needs network access once; after that it's offline.
Neovim and WezTerm both use the rose-pine moon theme.
Neovim keeps italics off and uses a transparent background on macOS, Windows, and WSL so it matches the terminal setup.

## License

This repo is licensed under MIT No Attribution.
See `LICENSE`.

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
- Nix user packages (ripgrep, fd, fzf, jq, lazygit, Neovim, Hack Nerd Font)
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

`bootstrap.sh` does four things, in order:

1. Installs Determinate Nix, if it isn't already installed.
2. Symlinks this repo to `~/.dotfiles`.
   This has to happen before the first build, because `home.nix` points at config files through `~/.dotfiles`.
3. Checks the `user` configured in `flake.nix` against your actual username, and offers to fix it for you if they differ.
4. Runs the first switch.
   On macOS it fetches the `darwin-rebuild` tool from the nix-darwin 26.05 release branch, then applies this repo's locked flake config.
   On Linux it runs the first `home-manager switch` instead (see [Linux](#linux)).

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

## Linux

nix-darwin is macOS-only, so on Linux this repo applies just the user-level
config (`home.nix`) with standalone home-manager. The system-level pieces in
`configuration.nix` (macOS defaults, Homebrew) don't apply.

The same two scripts work - they detect the OS with `uname` and branch automatically:

```sh
./bootstrap.sh   # installs Determinate Nix, then runs the first home-manager switch
./rebuild.sh     # re-applies after changes
```

What you get on Linux:

- Nix user packages: ripgrep, fd, fzf, jq, lazygit, Neovim, Hack Nerd Font.
- The macOS casks/brews as their nixpkgs equivalents: WezTerm, Claude Code, and herdr.
- The same symlinked shell (zsh + starship), Neovim, WezTerm, and agent configs as macOS.
- SSH client config (per-host aliases) and an `ssh-agent` systemd user service, on the workstation profile - see [SSH](#ssh-workstation-profile).
- A `container` profile that reuses the same shell and tools inside a devcontainer - see [Devcontainers](#devcontainers).

Notes:

- **Distro-agnostic**: works on any Linux distro (and WSL) once Nix is installed. home-manager is user-level and never touches apt/dnf/pacman.
- **Login shell**: home-manager can't change your login shell. To use zsh, run once `chsh -s "$(command -v zsh)"`, then open a new terminal. `bootstrap.sh` prints this reminder.
- **herdr** comes from `nixpkgs-unstable` (it isn't in the pinned nixpkgs yet); macOS installs it through Homebrew instead.
- Applying is per-user, so there's no `sudo` on Linux.
- **WSL2 + systemd**: the `ssh-agent` service is a systemd *user* service, so WSL2 needs systemd enabled. Add `[boot]` / `systemd=true` to `/etc/wsl.conf`, then `wsl --shutdown` and reopen; otherwise the agent never starts and `SSH_AUTH_SOCK` stays empty.

### SSH (workstation profile)

`programs.ssh` writes `~/.ssh/config` with per-host identity aliases, and a systemd
user service runs `ssh-agent` so `SSH_AUTH_SOCK` is set on every login. Each alias
maps a host to a specific key:

```
git@github.com-personal   ->  ~/.ssh/id_ed25519_gh_personal
git@github.com-work       ->  ~/.ssh/id_ed25519_gh_work
git@bitbucket.org-work    ->  ~/.ssh/id_ed25519_bb_work
```

The **private keys are not managed by Nix** - copy them into `~/.ssh` yourself
(mode 600). The agent starts empty on every WSL2 start, so whenever it is empty
an interactive workstation zsh loads these three keys into it at startup - it
may ask for their passphrases once - and they are ready before `devcontainer up`.
`AddKeysToAgent yes` still loads a key into the agent the first time it's used.
Edit the key paths in `sshKeys` at the top of `home.nix` and the hosts in
`programs.ssh.matchBlocks` to match your own hosts/keys.

### Devcontainers

`home.nix` takes a `profile` argument. The `container` profile reuses everything
(zsh, starship, packages, tools) but drops the host SSH machinery - no agent
service, no `~/.ssh/config`, no startup key loading - because a container has no
systemd and borrows the host's keys and agent instead. The devcontainer, defined
in `cloud-practitioner/agentic-devcontainer`, bind-mounts the host's `~/.ssh`
read-only and proxies the WSL2 ssh-agent socket into the container, under both
VS Code and the devcontainer CLI. The host's `~/.ssh/config` is a Nix-store
symlink that dangles inside the container, so that repo's `Dockerfile` recreates
the host aliases.

`flake.nix` exposes both profiles as home-manager configs:

```
dev@x86_64-linux             # WSL2 / Linux workstation (full profile)
dev@container-x86_64-linux   # container as user "dev"
node@container-x86_64-linux  # container as user "node"
```

Container usernames come from the `containerUsers` list in `flake.nix` (a
devcontainer base image's non-root user, e.g. `node`), so nothing rewrites `user`
at runtime. `rebuild.sh` auto-detects a container (`/.dockerenv`,
`$REMOTE_CONTAINERS`, `$CODESPACES`) and selects the matching `…@container-…`
config; on a plain WSL2 host it uses the workstation config.

## Make it yours

This repo is mine.
If you clone it, review these before you run `bootstrap.sh`:

- **Username**: run `./bootstrap.sh` (it detects your macOS username and offers to set it) OR change the single `user = "kunchen"` line in `flake.nix`.
  Everything else (`configuration.nix`, `home.nix`, home directory paths) is threaded from that one variable.
- **Host label** `"mac"`, in three places: `flake.nix` (the `darwinConfigurations."mac"` name), `rebuild.sh:5` (the `#mac` at the end of the flake reference), and `bootstrap.sh`'s first-switch command (also `#mac`).
  All three have to match.
- **CPU architecture**, `hostPlatform` in `configuration.nix` (see Prerequisites above).
- **Container users** (Linux): if a devcontainer's non-root user differs from your workstation username, add it to the `containerUsers` list in `flake.nix` so a `…@container-…` config exists for it.
- **SSH keys** (Linux/WSL2): the workstation profile defines its key paths once, in `sshKeys` at the top of `home.nix`; `programs.ssh.matchBlocks` maps hosts to them and the zsh init loads them at startup. Point them at your own hosts/keys and copy the private keys into `~/.ssh` yourself - Nix doesn't manage secrets.

**Git identity:** this config deliberately does not set your git name or email.
Git will stop your first commit and tell you to set them (`git config --global user.name "Your Name"` and `git config --global user.email you@example.com`).
If you'd rather manage that declaratively, add this back to `home.nix` with your own identity:

```nix
programs.git = {
  enable = true;
  settings.user = {
    name = "Your Name";
    email = "you@example.com";
  };
};
```

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
- `home.nix` - user-level config: shell, packages, prompt, SSH (workstation profile), and the symlinks described below. Takes a `profile` argument (`workstation` or `container`).
- `rebuild.sh` - re-applies the config after the first switch.
  Auto-detects a devcontainer and picks the container profile; otherwise uses the workstation profile. Run this every time you make a change.
- `home/` - the actual config files that get symlinked into place; the sections below explain the shared symlink model and Pi's narrower selective setup.

## How the symlinks work

The files under `home/` are the real files - editing them here is editing your live config, no rebuild needed to see the change in your editor.
`home.nix` uses `mkOutOfStoreSymlink` to point paths like `~/.config/nvim` straight at `home/.config/nvim` in this repo, so the two never drift out of sync.
You only run `./rebuild.sh` when you change something that isn't just a symlinked file, like a package list or a system default.

## Optional Pi configuration

Pi is an opt-in CLI, not a dependency this repository vendors. Install it from its owner with the [official Pi instructions](https://pi.dev), for example:

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

The versions are immutable pins, so Pi does not move them during package updates. Deliberate updates require a new source and security audit, followed by an explicit pin change in `home/.pi/agent/settings.json`. On Pi 0.82.0, global settings declarations install missing pinned packages automatically at startup. No one-time install command is required. Pi keeps the downloaded npm package trees in its own unmanaged `~/.pi/agent/npm` runtime directory, outside Home Manager and Git tracking.

Both packages execute with your full user permissions and must be trusted like any other executable code.

Home Manager deliberately does not manage `~/.pi/agent` itself, or Pi authentication, sessions, trust decisions, caches, npm/git package trees, or any other runtime state. The model overrides contain no credentials or endpoint settings, do not choose a default model, and only take effect after you authenticate Pi yourself. This remains an additive post-video layer: it does not install Pi, a launcher, or package source code into this repository.

## Notes

The first time you launch `nvim`, it bootstraps [lazy.nvim](https://github.com/folke/lazy.nvim) by cloning plugins from GitHub.
That needs network access once; after that it's offline.
Neovim and WezTerm both use the rose-pine moon theme.
Neovim keeps italics off and uses a transparent background on macOS, Windows, and WSL so it matches the terminal setup.

## License

This repo is licensed under MIT No Attribution.
See `LICENSE`.

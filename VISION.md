# Vision

`dotfiles` exists so that its owner gets the same shell, tools, agent setup and identity on every machine they work from, from one repo and one command.
It serves that one owner and the coding agents working in their environments: the WSL2 workstation, the Windows host it runs on, and the agentic devcontainer.
It turns a declarative config plus one small, private identity file into a configured home directory, and re-applying it is always safe.
It owns exactly one thing: the user-level environment - packages, toolchain installs, shell, editor, agent configuration, git and SSH identity rendering, and the Windows side of the workstation, its settings and its desk apps.

## One environment, every profile

The workstation and the devcontainer run the same home configuration through two profiles that differ only where the host forces them to.
A tool, skill, setting or key binding added for one profile lands in both unless the host makes that impossible, and the README names every difference.
The devcontainer image provides only what the profiles cannot, so the toolchain has one place to look.
The Windows side of the workstation - Windows Terminal settings, `.wslconfig`, the Windows SSH agent and a declarative winget list of desk apps - is managed from the same switch through WSL interop, because the owner's desk is Windows and WSL2 key handling and networking depend on it.
Line editing and terminal behaviour follow what a Windows and WSL2 user expects.
This is a Linux and WSL2 setup: macOS, nix-darwin and Homebrew are not supported.
It is an independent fork that does not track or merge its upstream, and the conventions it was forked with do not bind it.

## Reproducible means declarative and current, not frozen

Every install is one entry in a declarative list, applied by a switch that is safe to run at any time.
Agent CLIs and npm and pnpm tools float: each workstation switch upgrades them to their latest release through their vendors' own installers, never re-pinned or rebuilt as Nix derivations, and a devcontainer gets the latest when it is created.
Inside a running devcontainer nothing schedules or forces an upgrade; its tooling changes when it is rebuilt or when the owner runs `hm-update` there, which upgrades the floating tools like any switch.
Pins are deliberate exceptions with a stated reason: the Nix inputs and the Home Manager CLI through `flake.lock`, and third-party code that runs with the owner's full permissions after a security review.
A fresh machine comes up with one clone and one bootstrap command, and a re-run of bootstrap does nothing beyond the switch.
Nothing applies on its own: the workstation applies `main` only when the owner runs `rebuild.sh`, and no scheduler runs on the workstation or inside a devcontainer, so no tool changes under a working agent unless the owner starts it.
Windows app installs and upgrades run only inside a switch the owner starts, because winget can raise UAC prompts and restart apps.
Merging and applying are both the owner's decisions; a devcontainer provisions from `main` when it is created and `hm-update` follows `main`, even when the workstation has not applied it yet.

## A switch always completes

A failed install or upgrade, a missing prerequisite or an unhealthy tool prints a clear warning, and the next switch retries.
When `main` expects a workstation export - `identity.env` or an exported public key - that a devcontainer's mounted identity directory does not have yet, post-create and `hm-update` still apply everything else at `main` and never set up half a git or SSH identity.
A new container then comes up with no commit identity and no SSH push key, a running one keeps the identity it already has, and both say that the new identity needs `rebuild.sh` on the workstation and then `hm-update` in the container.
Smoke checks verify what matters after every switch - working binaries, discovered generators, and the work overlay's own checks - and warn rather than fail.
A healthy re-switch is quiet apart from two expected costs: upgrading the floating tools and listing where working copies differ from their defaults.

## Authored defaults in the repo, tool-written state out of git

Authored config lives in this repo; runtime state such as sessions, sockets, caches, logins and package trees stays outside it.
Files a tool writes - sessions, logs, sockets, credentials, toggles, and the settings files the tools themselves save into, such as herdr's `config.toml` and the Claude Code and Pi `settings.json` - are gitignored, so a tool's save never shows up as a change to the repo.
Each of those settings files is a working copy the tool owns: the first switch seeds it from a tracked default, and no switch overwrites it afterwards or keeps the tool's own change as a pending diff.
A setting meant for every machine is changed in the tracked default, deliberately; a key new to the default is added to every existing copy on the next switch, but a key a copy already has is never changed, so a setting changed in the tool on purpose is never undone.
A key removed from a copy comes back on the next switch while the default still has it.
The switch remembers the keys it added, and a key taken out of the default is removed from every copy it was added to; a key the tool or the owner added is never removed.
Each switch prints the keys where a working copy differs from its tracked default, so drift between machines is visible and a setting worth sharing is copied into the default, or a copy reset, by hand.
Outside the files it owns, activation repairs only its own links and leaves real directories and unknown files alone.
Moves are one-way and simple; installers never edit the owner's rc files, and a clone that cannot fast-forward is left as it is with a warning.

## Identity, secrets and work stay private in a public repo

No name, email, key, credential or validation evidence is committed; personal identity lives in one user-authored `identity.env` that the switch renders into git and SSH config.
The public repo stays generic: work-specific configuration - the SAP toolchain, the ARC-1 policy check, the Ixia marketplace and work key names - lives in the owner's own private work overlay that this repo imports, not in a team-owned repository, and none of it returns to the public repo.
Commit identity, SSH keys and work tooling are chosen by remote URL, so personal and work repositories never borrow each other's identity or tools.
Private keys are never read, only their public halves, and they never enter a container.
Secrets are owner-written `.env` files kept out of git and never committed in any form, encrypted or not - the owner-only `.secrets` folders the shell loads silently, and the gitignored MCP `.env` files on the workspace mount - and the switch never fetches or creates them.
No password manager, vault token or decryption key is wired into the switch or into a container; adopting one is a later decision the owner keeps.
Every agent session starts with a login check through the session-start hooks this repo ships: the git identity, SSH push key, `gh` login and MCP `.env` files the session's tools use are present, and each tool's own status command confirms with its service that the login still works.
The check reads whether a credential exists and whether its service accepts it, never its value; an autonomous worker that fails it stops with the exact command that fixes it before it takes a task, and an interactive session only warns.
Checks print the exact command that fixes a problem and never run it for the owner; the login check is the only one that contacts a service, and switch-time checks never probe the network.

## Scope

This repo is not system configuration for Linux hosts, not a secrets manager, and not a devcontainer definition; secrets live in owner-written files outside the repo, and mounts and sockets belong to agentic-devcontainer.
Ixia's plan-gate and review skills load automatically for interactive sessions in repositories with an IQX Bitbucket remote, and never in personal repositories.
Autonomous workers in those repositories keep their own workflow; before such a run starts, the owner is asked whether it should also run plan-gate and review.
It is a personal setup with no exceptions, public to read and fork; colleagues who use the SAP toolchain keep their own work overlays, copied from the owner's if they like, and contribute to neither this repo nor the owner's overlay.
Behaviour is covered by shell tests against local fakes, with no network and no real credentials.

A change aligns when it makes the workstation and the devcontainer more alike, lets a fresh machine come up with fewer manual steps, keeps a switch safe to re-run, keeps floating tools current, makes drift between a working copy and its default visible or carries a key added to or taken out of a default to every machine, catches a missing or expired login before an agent starts work, brings a Windows-side setting or app the workstation depends on under the switch, moves runtime state or tool-written settings out of git or work-specific and personal values out of the public repo, or scopes a tool to the work it is meant for by remote.
A change should be resisted when it pins a tool that is meant to float, lets a switch fail on an optional step, provisions a container with half a git or SSH identity or holds a container's setup or update back for a missing identity export, tracks a file a tool saves into, overwrites a tool's working copy, changes a key it already has or removes a key the switch did not add, lets an autonomous worker take a task without the logins it needs, overwrites runtime state or files the repo does not own, commits a personal value, a work-specific detail or a secret in any form, applies or upgrades anything on a schedule, on the workstation or in a container, runs Windows installers outside a switch the owner starts, keeps a tool's own write as a pending diff, wires a password manager or vault into the switch or a container, splits one setting into per-profile copies without a host reason, brings back macOS support or upstream syncing, loads work-only tooling in personal repositories, moves the work overlay into team ownership or opens it to colleagues' contributions, moves the SAP toolchain back into the public repo, or settles a call the owner keeps for themselves, such as adopting a password manager or Ixia gates on an autonomous run.

# Project notes for agents

Deliberate decisions in this repo - do NOT silently revert them:

- `homebrew.onActivation.cleanup = "zap"` in `configuration.nix` is intentional. It forces the good habit of declaring every Homebrew package in the Nix config instead of installing things ad-hoc, which keeps the machine reproducible. Do not soften it to `uninstall` or `none`. Users are warned about its effect in README.md; this note is for anyone tempted to change the setting itself.
- On Linux, herdr is its vendor's release pinned in `tools/` (never a nixpkgs build); change it only with `nix run .#update-tools`. Claude Code, Pi, and the GitHub Copilot CLI are deliberately unpinned: Home Manager's `nodeTools` activation (`tools/node-tools.sh`) installs them with pnpm, after nvm, Node.js LTS, and pnpm on the WSL2 workstation, or on the devcontainer image's own Node.js and pnpm. Don't re-pin them or block their updaters; README "Upstream CLI tools" has the details.
- `~/.claude/settings.json` and `~/.claude/CLAUDE.md` stay plain `home.file` links, so an unset `CLAUDE_CONFIG_DIR` behaves exactly as before, Home Manager collision handling included. `activation/claude-config.sh` acts only when `CLAUDE_CONFIG_DIR` points elsewhere (only activation can see it): `install` after `linkGeneration`, and `unlink` before `checkLinkTargets` to drop its own re-pointed links. Skills move one way only, with no link-back or convergence logic; keep it that simple and keep the no-clobber rules for the owner's files. `tests/claude-config.test.sh` covers them.
- Never commit `.no-mistakes/` validation evidence to this public repo. `.no-mistakes/` is gitignored; if a validation pipeline stages evidence into a branch, drop it before merging.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

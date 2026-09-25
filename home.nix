{ config, pkgs, lib, user, profile ? "workstation", ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  # The "container" profile drops host-only SSH machinery (agent + aliased
  # identities) so the same shell/tools can be reused inside a devcontainer
  # that borrows the WSL2 host's forwarded agent instead.
  isWorkstation = profile == "workstation";
in

{
  home.username = user;
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${user}" else "/home/${user}";
  home.stateVersion = "24.11";
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    lazygit
    neovim
    # the font everything renders in
    nerd-fonts.hack
  ] ++ lib.optionals stdenv.isLinux [
    # Linux equivalents of the macOS Homebrew casks/brews in configuration.nix.
    wezterm
    # Not in the pinned nixpkgs; the flake overlays it in from unstable.
    herdr
  ] ++ lib.optionals (stdenv.isLinux && isWorkstation) [
    # Workstation only. The devcontainer installs Claude Code via the official
    # installer (Dockerfile), so its Nix profile omits this nixpkgs build.
    claude-code
    # Build/run devcontainers from the CLI; needs a Docker host.
    devcontainer
    # Pi coding agent (@earendil-works/pi-coding-agent), overlaid from unstable
    # (flake.nix) for a fresher version than the pinned nixpkgs ships.
    pi-coding-agent
  ];
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";

  # On macOS the nix-darwin module drives home-manager, but standalone Linux
  # needs its own `home-manager` CLI (used by rebuild.sh).
  programs.home-manager.enable = pkgs.stdenv.isLinux;

  programs.zsh = {
    enable = true;
    # EDITOR=nvim (above) would otherwise make zle start in vi-insert mode.
    defaultKeymap = "emacs";
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = ''
      bindkey '^f' autosuggest-accept

      # Word-wise deletion, as the pre-Nix oh-my-zsh setup had it. An empty
      # WORDCHARS makes `-`, `/`, `.` etc. word boundaries.
      WORDCHARS='''
      bindkey '^H' backward-kill-word          # Ctrl+Backspace (Windows Terminal, conhost, Herdr)
      bindkey '^[[127;5u' backward-kill-word   # Ctrl+Backspace (CSI-u / kitty keyboard terminals)
      bindkey '^[[3;5~' kill-word              # Ctrl+Delete
      bindkey '^[[3~' delete-char              # Delete
      # Shift+Enter inserts a newline instead of running the line. The widget
      # name must not start with `_`: zsh-autosuggestions skips such widgets,
      # which would leave stale ghost text after the newline.
      _insert-newline() { LBUFFER+=$'\n' }
      zle -N insert-newline _insert-newline
      bindkey '^[[27;2;13~' insert-newline     # Shift+Enter as Herdr sends it to the shell
      bindkey '^[[13;2u' insert-newline        # Shift+Enter (CSI-u / kitty keyboard terminals)
    '' + lib.optionalString (!isWorkstation) ''

      # Devcontainer only. Make single-user Nix usable, including after a
      # recreate where $HOME resets but the /nix volume (and its store nix
      # binary) persists.
      if [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
      elif ! command -v nix >/dev/null 2>&1; then
        for d in /nix/store/*-nix-2.*/bin(N); do [ -x "$d/nix" ] && export PATH="$d:$PATH" && break; done
        export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
      fi

      # On-demand dotfiles refresh; deliberately never auto-runs on shell start.
      hm-update() {
        local sys
        case "$(uname -m)" in
          x86_64) sys=x86_64-linux ;;
          aarch64|arm64) sys=aarch64-linux ;;
          *) echo "unsupported $(uname -m)" >&2; return 1 ;;
        esac
        git -C "$HOME/.dotfiles" pull --ff-only || return 1
        nix run github:nix-community/home-manager/release-26.05 -- switch -b backup --flake "$HOME/.dotfiles#$(id -un)@container-$sys"
      }

      # Cheap, non-blocking welcome note (once per terminal); no network calls.
      if [[ -o interactive && -z "''${HM_WELCOME_SHOWN:-}" && -d "$HOME/.dotfiles/.git" ]]; then
        export HM_WELCOME_SHOWN=1
        print -P "%F{blue}dotfiles%f $(git -C "$HOME/.dotfiles" rev-parse --short HEAD 2>/dev/null) - run %F{green}hm-update%f to pull latest and re-switch"
      fi
    '' + lib.optionalString isWorkstation ''

      # The systemd ssh-agent starts empty; when it is reachable but has no
      # identities (exit 1), load the keys so `ssh-add -l` is populated before
      # launching devcontainers. Skips when keys are present (0) or no agent (2).
      if [[ -o interactive ]]; then
        ssh-add -l >/dev/null 2>&1
        if [ "$?" = 1 ]; then
          ssh-add ~/.ssh/id_ed25519_gh_work \
                  ~/.ssh/id_ed25519_gh_personal \
                  ~/.ssh/id_ed25519_bb_work 2>/dev/null
        fi
      fi
    '';
    shellAliases = {
      ".." = "cd ..";
      add = "git add .";
      push = "git push";
      pull = "git pull";
      m = "git switch main";
      cc = "claude --dangerously-skip-permissions";
      co = "codex --full-auto";
    };
  };

  # SSH client config lives in the repo so a throwaway WSL2 instance comes up
  # with the same host aliases every time. The private keys themselves are not
  # managed by Nix - drop them into ~/.ssh out of band. Workstation-only: the
  # devcontainer reuses these keys and aliases via a read-only ~/.ssh bind mount
  # plus the proxied WSL2 ssh-agent socket (see .devcontainer/devcontainer.json
  # and Dockerfile), working under both VS Code and the devcontainer CLI.
  programs.ssh = lib.mkIf isWorkstation {
    enable = true;
    matchBlocks = {
      "*".addKeysToAgent = "yes";
      "github.com-personal" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_gh_personal";
        identitiesOnly = true;
      };
      "github.com-work" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_gh_work";
        identitiesOnly = true;
      };
      "bitbucket.org-work" = {
        hostname = "bitbucket.org";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_bb_work";
        identitiesOnly = true;
      };
    };
  };

  # WSL2 runs systemd, so let it own ssh-agent: SSH_AUTH_SOCK is always set and
  # the socket can be forwarded into devcontainers. macOS has its own agent, and
  # a container has no systemd, so restrict this to a Linux workstation.
  services.ssh-agent.enable = pkgs.stdenv.isLinux && isWorkstation;

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](purple)";
        error_symbol = "[❯](red)";
      };
      cmd_duration.format = "[$duration]($style) ";
    };
  };

  # Edit-in-place: the real file stays in my repo, ~/.config just points at it.
  home.file.".config/wezterm".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
  home.file.".claude/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";

  # Keep Pi's credential and runtime state local by linking only authored files and directories.
  home.file.".pi/agent/themes".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/themes";
  home.file.".pi/agent/extensions".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/extensions";
  home.file.".pi/agent/models.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/models.json";
  home.file.".pi/agent/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/settings.json";

  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".codex/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".config/opencode/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
}

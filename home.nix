{ config, pkgs, lib, user, profile ? "workstation", ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  # The "container" profile drops host-only SSH machinery (agent + aliased
  # identities) so the same shell/tools can be reused inside a devcontainer
  # that borrows the WSL2 host's forwarded agent instead.
  isWorkstation = profile == "workstation";
  # Private keys behind the SSH host aliases (programs.ssh), which the
  # workstation zsh init also loads into an empty agent.
  sshKeys = {
    ghWork = "~/.ssh/id_ed25519_gh_work";
    ghPersonal = "~/.ssh/id_ed25519_gh_personal";
    bbWork = "~/.ssh/id_ed25519_bb_work";
  };
  # Moves these PATH entries right after ~/.nix-profile/bin (herdr), or to the
  # front without it, once each, so they win over the system's and WSL's
  # Windows-interop (/mnt/*) copies: pnpm's global bins (Claude Code, Pi,
  # GitHub Copilot CLI; $PNPM_HOME/bin for pnpm 11+, $PNPM_HOME for older
  # pnpm) and, on the workstation first, $NVM_DIR/default/bin (nvm's default
  # Node.js, npm, and pnpm, linked by tools/node-tools.sh). It sets PNPM_HOME
  # and NVM_DIR itself, with the same defaults as tools/node-tools.sh (and
  # pnpm): an image's own PNPM_HOME wins.
  nodePath = pkgs.writeText "node-tools-path.sh" (''
    export PNPM_HOME="''${PNPM_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}"
  '' + lib.optionalString isWorkstation ''
    export NVM_DIR="''${NVM_DIR:-$HOME/.nvm}"
  '' + ''
    __nt_front="${lib.concatStringsSep ":" (lib.optional isWorkstation "$NVM_DIR/default/bin" ++ [ "$PNPM_HOME/bin" "$PNPM_HOME" ])}"
    __nt_rest="$PATH:"
    __nt_path=
    __nt_placed=
    while [ -n "$__nt_rest" ]; do
      __nt_dir=''${__nt_rest%%:*}
      __nt_rest=''${__nt_rest#*:}
      case ":$__nt_front:" in
        *":$__nt_dir:"*) continue ;;
      esac
      __nt_path=''${__nt_path:+$__nt_path:}$__nt_dir
      if [ -z "$__nt_placed" ] && [ "$__nt_dir" = "$HOME/.nix-profile/bin" ]; then
        __nt_path=$__nt_path:$__nt_front
        __nt_placed=1
      fi
    done
    [ -n "$__nt_placed" ] || __nt_path=$__nt_front''${__nt_path:+:$__nt_path}
    export PATH="$__nt_path"
    unset __nt_front __nt_rest __nt_path __nt_placed __nt_dir
  '');
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
    # herdr's vendor release pinned in tools/ (flake.nix overlay), the same in
    # both Linux profiles. Claude Code, Pi, and the GitHub Copilot CLI are not
    # Nix packages: the nodeTools activation below installs them unpinned with
    # pnpm.
    upstream-tools.herdr
  ] ++ lib.optionals (stdenv.isLinux && isWorkstation) [
    # Build/run devcontainers from the CLI; needs a Docker host.
    devcontainer
  ];
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";
  # Every Linux shell, not just interactive zsh, runs nodePath (above), even
  # when an older environment marks the session variables as already sourced:
  # zsh from ~/.zshenv (programs.zsh.envExtra), a bash login shell from here,
  # after the session variables and before the distro's own ~/.profile (and
  # through it ~/.bashrc), which Home Manager leaves alone. The interactive
  # workstation zsh then loads nvm itself.
  home.file.".bash_profile" = lib.mkIf pkgs.stdenv.isLinux {
    text = ''
      . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
      . ${nodePath}
      [ -f "$HOME/.profile" ] && . "$HOME/.profile"
    '';
  };

  # Claude Code, Pi, and the GitHub Copilot CLI, unpinned from pnpm, at every
  # Linux switch when missing (tools/node-tools.sh). The WSL2 workstation first
  # gets nvm, Node.js LTS as nvm's default, and pnpm; a container uses its
  # image's Node.js and pnpm. A failure (no pnpm, offline) only warns, so the
  # switch still completes; the next switch retries.
  home.activation.nodeTools = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! run env PATH="${lib.makeBinPath (with pkgs; [
          bash coreutils curl findutils gawk git gnugrep gnused gnutar gzip xz
        ])}:$PATH" \
        ${pkgs.bash}/bin/bash ${./tools/node-tools.sh} ${if isWorkstation then "workstation" else "container"}; then
        warnEcho "tools/node-tools.sh failed (see above): ${if isWorkstation then "nvm, Node.js, pnpm, " else ""}Claude Code, Pi, or the GitHub Copilot CLI may be missing. Fix that, then switch again."
      fi
    ''
  );
  # The container's activation keeps the user's PATH (after Home Manager's own
  # tools), so tools/node-tools.sh finds the image's Node.js and pnpm.
  home.emptyActivationPath = lib.mkIf (pkgs.stdenv.isLinux && !isWorkstation) false;

  # On macOS the nix-darwin module drives home-manager, but standalone Linux
  # needs its own `home-manager` CLI (used by rebuild.sh).
  programs.home-manager.enable = pkgs.stdenv.isLinux;

  programs.zsh = {
    enable = true;
    # EDITOR=nvim (above) would otherwise make zle start in vi-insert mode.
    defaultKeymap = "emacs";
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    envExtra = lib.optionalString pkgs.stdenv.isLinux ''
      . ${nodePath}
    '';
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
    '' + lib.optionalString (pkgs.stdenv.isLinux && isWorkstation) ''

      # nvm (installed by the nodeTools activation, tools/node-tools.sh) puts
      # its default Node.js, npm, and pnpm first on PATH. Containers skip this:
      # the devcontainer image brings its own Node.js and pnpm.
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

      # The systemd ssh-agent starts empty; when it is reachable but has no
      # identities (exit 1), load the keys so `ssh-add -l` is populated before
      # launching devcontainers. Skips when keys are present (0) or no agent (2).
      if [[ -o interactive ]]; then
        ssh-add -l >/dev/null 2>&1
        if [ "$?" = 1 ]; then
          # Catch Ctrl+C so cancelling a passphrase prompt stops only ssh-add, not the rest of .zshrc.
          trap : INT
          ssh-add ${sshKeys.ghWork} \
                  ${sshKeys.ghPersonal} \
                  ${sshKeys.bbWork} 2>/dev/null
          trap - INT
        fi
      fi
    '' + lib.optionalString pkgs.stdenv.isLinux ''

      # Again after the global rc files and nvm, which may reorder PATH.
      . ${nodePath}
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
  # devcontainer (cloud-practitioner/agentic-devcontainer) reuses these keys via
  # a read-only ~/.ssh bind mount plus the proxied WSL2 ssh-agent socket, under
  # both VS Code and the devcontainer CLI. This ~/.ssh/config is a Nix-store
  # symlink that dangles inside the container, so that repo's Dockerfile
  # recreates these host aliases.
  programs.ssh = lib.mkIf isWorkstation {
    enable = true;
    matchBlocks = {
      "*".addKeysToAgent = "yes";
      "github.com-personal" = {
        hostname = "github.com";
        user = "git";
        identityFile = sshKeys.ghPersonal;
        identitiesOnly = true;
      };
      "github.com-work" = {
        hostname = "github.com";
        user = "git";
        identityFile = sshKeys.ghWork;
        identitiesOnly = true;
      };
      "bitbucket.org-work" = {
        hostname = "bitbucket.org";
        user = "git";
        identityFile = sshKeys.bbWork;
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

  # Claude Code reads $CLAUDE_CONFIG_DIR when set, else ~/.claude, and only
  # activation can see that variable. When it points elsewhere,
  # activation/claude-config.sh installs the Claude files into it and re-points
  # the two ~/.claude links above there, dropping its own links again before
  # the next collision check. Unset, it does nothing.
  home.activation.claudeConfigUnlink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    run ${pkgs.bash}/bin/bash ${./activation/claude-config.sh} unlink
  '';
  home.activation.claudeConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.bash}/bin/bash ${./activation/claude-config.sh} install \
      ${lib.escapeShellArg "${dotfiles}/home/.claude/settings.json"} \
      ${lib.escapeShellArg "${dotfiles}/home/AGENTS.md"}
  '';
}

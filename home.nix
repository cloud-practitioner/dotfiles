{ config, pkgs, lib, user, profile ? "workstation", dotfilesRev ? "unknown", ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  # The "container" profile drops the agent service, ~/.ssh/config, and startup
  # key loading so the same shell/tools can be reused inside a devcontainer
  # that borrows the WSL2 host's forwarded agent instead.
  isWorkstation = profile == "workstation";
  # Linux zsh reads the key list rendered by activation/identity.sh here;
  # sshKeys below retains the existing macOS alias paths.
  identityDir = "$HOME/.config/dotfiles";
  sshKeys = {
    ghWork = "~/.ssh/id_ed25519_gh_work";
    ghPersonal = "~/.ssh/id_ed25519_gh_personal";
    bbWork = "~/.ssh/id_ed25519_bb_work";
  };
  # Moves these PATH entries right before ~/.nix-profile/bin, or to the front
  # without it, once each, so they win over the Nix profile's, the system's,
  # and WSL's Windows-interop (/mnt/*) copies: ~/.local/bin first (herdr from
  # its vendor's installer, ahead of a Nix-built herdr from an older switch,
  # and the launchers of Claude Code, Pi, and the GitHub Copilot CLI from
  # their own installers, ahead of any npm or pnpm copy), then, on the
  # workstation, $NVM_DIR/default/bin (nvm's default Node.js, npm, and pnpm,
  # linked by tools/node-tools.sh), then pnpm's global bins ($PNPM_HOME/bin
  # for pnpm 11+, $PNPM_HOME for older pnpm). It sets PNPM_HOME and NVM_DIR
  # itself, with the same defaults as tools/node-tools.sh (and pnpm): an
  # image's own PNPM_HOME wins.
  nodePath = pkgs.writeText "node-tools-path.sh" (''
    export PNPM_HOME="''${PNPM_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}"
  '' + lib.optionalString isWorkstation ''
    export NVM_DIR="''${NVM_DIR:-$HOME/.nvm}"
  '' + ''
    __nt_front="${lib.concatStringsSep ":" ([ "$HOME/.local/bin" ] ++ lib.optional isWorkstation "$NVM_DIR/default/bin" ++ [ "$PNPM_HOME/bin" "$PNPM_HOME" ])}"
    __nt_rest="$PATH:"
    __nt_path=
    __nt_placed=
    while [ -n "$__nt_rest" ]; do
      __nt_dir=''${__nt_rest%%:*}
      __nt_rest=''${__nt_rest#*:}
      case ":$__nt_front:" in
        *":$__nt_dir:"*) continue ;;
      esac
      if [ -z "$__nt_placed" ] && [ "$__nt_dir" = "$HOME/.nix-profile/bin" ]; then
        __nt_path=''${__nt_path:+$__nt_path:}$__nt_front
        __nt_placed=1
      fi
      __nt_path=''${__nt_path:+$__nt_path:}$__nt_dir
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
    bun       # javascript runtime and package manager
    lazygit
    neovim
    # the font everything renders in
    nerd-fonts.hack
  ] ++ lib.optionals stdenv.isLinux [
    # Linux equivalents of the macOS Homebrew casks/brews in configuration.nix.
    # herdr, Claude Code, Pi, and the GitHub Copilot CLI are not Nix packages:
    # the nodeTools activation below installs them unpinned.
    wezterm
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

  # herdr, Claude Code, Pi, and the GitHub Copilot CLI, unpinned from their
  # own installers, at every Linux switch when missing (tools/node-tools.sh).
  # The WSL2 workstation first gets nvm, Node.js LTS as nvm's default, and
  # pnpm; a container uses its image's Node.js and pnpm. A failure (no pnpm,
  # offline) only warns, so the switch still completes; the next switch
  # retries.
  home.activation.nodeTools = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! run env PATH="${lib.makeBinPath (with pkgs; [
          bash coreutils curl findutils gawk git gnugrep gnused gnutar gzip util-linux xz
        ])}:$PATH" \
        ${pkgs.bash}/bin/bash ${./tools/node-tools.sh} ${if isWorkstation then "workstation" else "container"}; then
        warnEcho "tools/node-tools.sh failed (see above): ${if isWorkstation then "nvm, Node.js, pnpm, " else ""}herdr, Claude Code, Pi, or the GitHub Copilot CLI may be missing. Fix that, then switch again."
      fi
    ''
  );
  # The container's activation keeps the user's PATH (after Home Manager's own
  # tools), so tools/node-tools.sh finds the image's Node.js and pnpm.
  home.emptyActivationPath = lib.mkIf (pkgs.stdenv.isLinux && !isWorkstation) false;

  # Keep the standalone CLI available on Linux for manual use; rebuild.sh
  # deliberately does not rely on this installed copy.
  programs.home-manager.enable = pkgs.stdenv.isLinux;

  programs.zsh = {
    enable = true;
    # EDITOR=nvim (above) would otherwise make zle start in vi-insert mode.
    defaultKeymap = "emacs";
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    envExtra = lib.optionalString pkgs.stdenv.isLinux ''
      . ${nodePath}
      # Loads credentials kept out of this repo, such as Bitbucket's for the
      # no-mistakes daemon, which inherits the environment of whichever
      # shell starts it.
      # A /workspaces/*/.secrets (the devcontainer's persistent mount) or
      # ~/.secrets folder counts only if it is a real directory we own that
      # group and others cannot access (chmod 700), so a .secrets folder git
      # checks out (mode 755) is ignored. Each *.env file in one is loaded
      # in name order if it is a regular file we own that neither group nor
      # others can write; anything else, or a file that fails, is skipped
      # silently.
      () {
        local d f
        for d in /workspaces/*/.secrets(N/U^AIERWX) $HOME/.secrets(N/U^AIERWX); do
          for f in $d/*.env(N.U^IW); do
            # Parse the whole file first, so one with a syntax error is
            # skipped outright rather than half applied.
            { eval "__secrets_parse() { $(<$f)
            }" } >/dev/null 2>&1 || continue
            unfunction __secrets_parse
            . "$f" >/dev/null 2>&1
          done
        done
        return 0
      }
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
        # Follow the workstation: check out the revision it applied (its
        # identity directory is mounted here), else pull main.
        local rev
        rev=$(cat "$HOME/.config/dotfiles/applied-rev" 2>/dev/null)
        if [ -n "$rev" ]; then
          git -C "$HOME/.dotfiles" fetch -q origin || return 1
          case "$rev" in *-dirty) echo "hm-update: the workstation applied uncommitted dotfiles changes; using ''${rev%-dirty}" >&2 ;; esac
          if ! git -C "$HOME/.dotfiles" checkout -q --detach "''${rev%-dirty}" 2>/dev/null; then
            echo "hm-update: workstation dotfiles revision ''${rev%-dirty} is not on origin (unpushed?); using origin/main" >&2
            git -C "$HOME/.dotfiles" checkout -q --detach origin/main || return 1
          fi
        else
          # No mount (older image): track main, even from a detached checkout.
          git -C "$HOME/.dotfiles" symbolic-ref -q HEAD >/dev/null || git -C "$HOME/.dotfiles" checkout -q main || return 1
          git -C "$HOME/.dotfiles" pull --ff-only || return 1
        fi
        nix run --inputs-from "$HOME/.dotfiles" home-manager -- switch -b backup --flake "$HOME/.dotfiles#$(id -un)@container-$sys"
      }

      # Cheap, non-blocking welcome note (once per terminal); no network calls.
      if [[ -o interactive && -z "''${HM_WELCOME_SHOWN:-}" && -d "$HOME/.dotfiles/.git" ]]; then
        export HM_WELCOME_SHOWN=1
        print -P "%F{blue}dotfiles%f $(git -C "$HOME/.dotfiles" rev-parse --short HEAD 2>/dev/null) - run %F{green}hm-update%f to follow the workstation's revision and re-switch"
      fi
    '' + lib.optionalString (pkgs.stdenv.isLinux && isWorkstation) ''

      # nvm (installed by the nodeTools activation, tools/node-tools.sh) puts
      # its default Node.js, npm, and pnpm first on PATH. Containers skip this:
      # the devcontainer image brings its own Node.js and pnpm.
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

      # The systemd ssh-agent starts empty; when it is reachable but has no
      # identities (exit 1), load the keys listed in identity.env (rendered to
      # ssh-keys by activation/identity.sh) so `ssh-add -l` is populated before
      # launching devcontainers. Skips when keys are present (0) or no agent (2).
      if [[ -o interactive ]]; then
        ssh-add -l >/dev/null 2>&1
        if [ "$?" = 1 ]; then
          __id_keys=(''${(f)"$(cat "${identityDir}/ssh-keys" 2>/dev/null)"})
          if (( ''${#__id_keys} )); then
            # Catch Ctrl+C so cancelling a passphrase prompt stops only ssh-add, not the rest of .zshrc.
            trap : INT
            ssh-add $__id_keys 2>/dev/null
            trap - INT
          fi
          unset __id_keys
        fi
        # One line, no network: a fresh workstation has no identity file yet.
        [ -f "${identityDir}/identity.env" ] ||
          print -P "%F{yellow}dotfiles%f no ~/.config/dotfiles/identity.env yet (git and SSH identities): see the README, or run %F{green}~/.dotfiles/activation/identity.sh check workstation%f"
      fi
    '' + lib.optionalString pkgs.stdenv.isLinux ''

      # Again after the global rc files and nvm, which may reorder PATH.
      . ${nodePath}

      # Completions from the installed herdr, which updates itself outside Nix.
      if (( $+commands[herdr] )); then
        source <(herdr completion zsh)
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

  # SSH client config on the Linux workstation. The legacy per-host aliases and the
  # key paths are personal, so they come from ~/.config/dotfiles/identity.env:
  # activation/identity.sh renders ~/.ssh/config.d/identities, which is
  # included here. The private keys are not managed by Nix - create them
  # yourself (the activation prints the command). Git picks its identity and
  # key by remote URL (programs.git below), so the aliases are optional. The
  # container profile gets no ~/.ssh/config from here.
  # Blocks use OpenSSH directive names (ssh_config(5)). Home Manager's legacy
  # defaults are off (enableDefaultConfig), so the `*` block spells out the
  # ones this config always had, preserving the default SSH options.
  programs.ssh = lib.mkIf isWorkstation {
    enable = true;
    enableDefaultConfig = false;
    includes = lib.optional pkgs.stdenv.isLinux "~/.ssh/config.d/identities";
    settings = {
      "*" = {
        AddKeysToAgent = "yes";
        ForwardAgent = false;
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
    } // lib.optionalAttrs pkgs.stdenv.isDarwin {
      "github.com-personal" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = sshKeys.ghPersonal;
        IdentitiesOnly = true;
      };
      "github.com-work" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = sshKeys.ghWork;
        IdentitiesOnly = true;
      };
      "bitbucket.org-work" = {
        HostName = "bitbucket.org";
        User = "git";
        IdentityFile = sshKeys.bbWork;
        IdentitiesOnly = true;
      };
    };
  };

  # Git identity (name, email, SSH key) is chosen by the remote URL
  # (includeIf hasconfig:remote.*.url, git >= 2.36) from rules that
  # activation/identity.sh renders out of the workstation's
  # ~/.config/dotfiles/identity.env into ~/.config/git/identities.gitconfig.
  # The values are personal, so they never enter this public repo; git ignores
  # the include while the file is missing, and useConfigOnly then refuses a
  # commit instead of guessing an identity. No folder (gitdir:) rules and no
  # insteadOf: clones stay anonymous HTTPS, and only pushes go over SSH.
  programs.git = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    # With stateVersion 24.11 Home Manager would otherwise add a gpg section.
    signing.format = null;
    settings = {
      user.useConfigOnly = true;
      url."git@github.com:".pushInsteadOf = "https://github.com/";
      url."git@bitbucket.org:".pushInsteadOf = "https://bitbucket.org/";
    };
    includes = [ { path = "~/.config/git/identities.gitconfig"; } ];
  };
  # On every Linux switch: render the identity files, export the public keys
  # and record the applied dotfiles revision (workstation), and check the
  # keys, agent, and git. It only warns, so a fresh machine still switches.
  home.activation.identity = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run env PATH="${lib.makeBinPath (with pkgs; [ bash coreutils findutils gawk git gnugrep gnused openssh ])}:$PATH" \
        DOTFILES_REV=${lib.escapeShellArg dotfilesRev} \
        ${pkgs.bash}/bin/bash ${./activation/identity.sh} render ${if isWorkstation then "workstation" else "container"}
    ''
  );

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

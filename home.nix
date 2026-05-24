{ pkgs, username, ... }:

{
  home.username = username;
  home.homeDirectory = "/Users/${username}";
  home.stateVersion = "25.05";

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # ── CLI packages ──────────────────────────────────────────────
  home.packages = with pkgs; [
    # Core utils
    jq
    iperf3

    # Archive
    p7zip

    # Media
    ffmpeg

    # Cloud
    azure-cli

    # Networking / transfer
    mosh
    rclone

    # Modelops toolchain (see modelops/README.md)
    uv                              # Python project + venv manager
    python3Packages.huggingface-hub # `hf` CLI for downloads/uploads
    llama-cpp                       # GGUF tooling (llama-quantize, llama-cli, etc.)

    # GitHub Copilot CLI (`copilot` — standalone coding-agent CLI, not the gh extension)
    github-copilot-cli

    # Fonts (Nerd Fonts)
    nerd-fonts.fira-code
  ];

  # ── Zsh ───────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initContent = ''
      export PATH="$HOME/.local/bin:$PATH"
    '';
    shellAliases = {
      hermes = "container exec -it hermes-agent bash -c 'source /opt/hermes/.venv/bin/activate && hermes'";
      hermes-up = "~/repo/mac-nix-agent/hermes/run.sh up";
      hermes-down = "~/repo/mac-nix-agent/hermes/run.sh down";
      hermes-logs = "container logs -f hermes-agent";
      hermes-rebuild = "~/repo/mac-nix-agent/hermes/run.sh rebuild";

      # Modelops: cd bookmark only. Workflow commands are intentionally NOT aliased
      # — see modelops/README.md and run them yourself to learn the toolchain.
      modelops = "cd ~/repo/mac-nix-agent/modelops";
    };
  };

  # ── Starship prompt ──────────────────────────────────────────
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      # Minimal preset — tweak to taste
      add_newline = false;
      format = "$directory$git_branch$git_status$character";

      character = {
        success_symbol = "[›](bold green)";
        error_symbol = "[›](bold red)";
      };

      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };

      git_branch = {
        format = "[$branch]($style) ";
        style = "bold purple";
      };

      git_status = {
        format = "[$all_status$ahead_behind]($style) ";
        style = "bold red";
      };
    };
  };

  # ── Tmux ─────────────────────────────────────────────────────
  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    escapeTime = 10;
    historyLimit = 10000;
  };

  # ── GitHub CLI ───────────────────────────────────────────────
  programs.gh = {
    enable = true;
  };

  # ── SSH ──────────────────────────────────────────────────────
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        UseKeychain = "yes";
        AddKeysToAgent = "yes";
      };
    };
  };

  # ── Git ──────────────────────────────────────────────────────
  # User identity is intentionally not declared here — set it locally:
  #   GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.name  "Your Name"
  #   GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.email "you@example.com"
  # Why GIT_CONFIG_GLOBAL? home-manager owns ~/.config/git/config as a
  # read-only symlink into the nix store, so plain `git config --global`
  # fails with EACCES. Writing to ~/.gitconfig works — git merges both.
  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

}

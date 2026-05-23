{ pkgs, username, ... }:

{
  # Nix management handled by Determinate Systems installer
  nix.enable = false;
  nixpkgs.config.allowUnfree = true;

  # System-level packages (available to all users)
  environment.systemPackages = [ ];

  # Expose nix profile paths to GUI apps
  environment.etc."paths.d/nix".text = ''
    /etc/profiles/per-user/${username}/bin
    /run/current-system/sw/bin
    /nix/var/nix/profiles/default/bin
  '';

  # ── Ollama — managed via Homebrew cask (MLX support) ───────────
  # The Ollama app manages its own background service.
  # Configure OLLAMA_HOST=0.0.0.0 in the app settings to accept remote connections.

  # ── Firewall — allow Ollama from Tailscale network ──────────
  # Tailscale uses CGNAT range 100.64.0.0/10; utun number varies per boot
  environment.etc."pf.anchors/ollama-tailscale".text = ''
    pass in quick proto tcp from 100.64.0.0/10 to any port 11434
  '';

  system.activationScripts.postActivation.text = ''
    # Load the Ollama/Tailscale pf anchor
    if ! /sbin/pfctl -sr 2>/dev/null | grep -q 'ollama-tailscale'; then
      echo 'anchor "ollama-tailscale"' | /sbin/pfctl -a ollama-tailscale -f /etc/pf.anchors/ollama-tailscale 2>/dev/null
      /sbin/pfctl -a ollama-tailscale -f /etc/pf.anchors/ollama-tailscale 2>/dev/null || true
    fi
  '';

  # ── oMLX inference server ──────────────────────────────────────
  # Installed via Homebrew (jundot/omlx/omlx) and run by brew's stock
  # launchd plist. Bind address and API key live in ~/.omlx/settings.json
  # (.server.host and .auth.api_key) and are seeded by bootstrap.sh.
  # Manage day-to-day via: brew services {start,stop,restart} jundot/omlx/omlx

  # ── Homebrew — disabled, tools managed by Nix ────────────────
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade    = true;
      cleanup    = "zap";
    };
    taps = [
      {
        name = "jundot/omlx";
        clone_target = "https://github.com/jundot/omlx";
      }
    ];
    casks = [
      "iina"
      "visual-studio-code"
      "lm-studio"
      "ollama-app"
      "appcleaner"
      "google-gemini"
    ];
    brews = [
      "jundot/omlx/omlx"
    ];
  };

  # Required: declare the primary user for Home Manager integration
  users.users.${username} = {
    name = username;
    home = "/Users/${username}";
  };

  system.primaryUser = username;

  # Used for backwards compatibility
  system.stateVersion = 5;
}

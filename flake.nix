{
  description = "Declarative macOS dev environment for the Hermes agent (Nix + nix-darwin + Home Manager)";

  inputs = {
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixpkgs-unstable&shallow=1";

    nix-darwin = {
      url = "git+https://github.com/LnL7/nix-darwin?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "git+https://github.com/nix-community/home-manager?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }: let
    system = "aarch64-darwin";

    # ── Per-machine identity ─────────────────────────────────────
    # Personalization lives in ./local.nix (gitignored), so this file
    # stays clean for upstream pulls. `bootstrap.sh` generates local.nix
    # on first run from `id -un` and `scutil --get LocalHostName`. To
    # override manually, create ./local.nix with:
    #   { username = "jane"; hostname = "jane-mbp"; }
    # then `git add --intent-to-add local.nix && sudo darwin-rebuild switch --flake .`.
    #
    # NOTE: `git add --intent-to-add` (done by bootstrap.sh) is required.
    # `--flake .` evaluates from the git tree, which excludes gitignored
    # files; without staging it, darwinConfigurations.<hostname> is absent
    # and darwin-rebuild fails to find the current machine's config.
    defaults = { username = "your-username"; hostname = "your-hostname"; };
    local    = if builtins.pathExists ./local.nix then import ./local.nix else {};
    cfg      = defaults // local;
    inherit (cfg) username hostname;
  in {
    darwinConfigurations.${hostname} = nix-darwin.lib.darwinSystem {
      inherit system;
      specialArgs = { inherit username; };
      modules = [
        ./darwin.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "hm-backup";
          home-manager.extraSpecialArgs = { inherit username; };
          home-manager.users.${username} = import ./home.nix;
        }
      ];
    };
  };
}

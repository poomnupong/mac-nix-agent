{
  description = "Declarative macOS dev environment for the Hermes agent (Nix + nix-darwin + Home Manager)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
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
    # then `sudo darwin-rebuild switch --flake .`.
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

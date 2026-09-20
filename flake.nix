{
  description = "dotfiles";

  inputs = {
    # Use `github:NixOS/nixpkgs/nixpkgs-26.05-darwin` to use Nixpkgs 26.05.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # Use `github:nix-darwin/nix-darwin/nix-darwin-26.05` to use Nixpkgs 26.05.
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    # herdr isn't in the pinned darwin nixpkgs yet, so the Linux build pulls
    # just that one package from unstable (macOS installs it via Homebrew).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = inputs@{ self, nix-darwin, nix-homebrew, home-manager, nixpkgs, nixpkgs-unstable }:
    let
      # The one username line to change if this isn't your machine.
      # bootstrap.sh offers to rewrite this for you if your macOS username differs.
      user = "dev";

      # Standalone home-manager for Linux. nix-darwin is macOS-only, so on Linux
      # we apply just the user-level config (home.nix) instead. allowUnfree is
      # set here because it lives in configuration.nix, which Linux never loads.
      # The overlay backports herdr from unstable, since the pinned nixpkgs
      # doesn't carry it yet.
      mkLinuxHome = system:
        let
          unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
        in
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ (_final: _prev: { inherit (unstable) herdr; }) ];
          };
          extraSpecialArgs = { inherit user; };
          modules = [ ./home.nix ];
        };
    in
    {
      darwinConfigurations."mac" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit user; };
        modules = [
          ./configuration.nix
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit user; };
            home-manager.users.${user} = import ./home.nix;
          }
        ];
      };

      # Keyed by "<user>@<system>" so bootstrap.sh / rebuild.sh can select the
      # right one from `uname -m`, e.g. home-manager switch --flake .#dev@x86_64-linux
      homeConfigurations = {
        "${user}@x86_64-linux" = mkLinuxHome "x86_64-linux";
        "${user}@aarch64-linux" = mkLinuxHome "aarch64-linux";
      };
    };
}

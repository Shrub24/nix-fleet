{
  inputs = {
    nix-fleet.url = "github:Shrub24/nix-fleet";
    nixpkgs.follows = "nix-fleet/nixpkgs";
    flake-parts.follows = "nix-fleet/flake-parts";
    treefmt-nix.follows = "nix-fleet/treefmt-nix"; # flakeModules.tooling reads it
    # The operator's instance descriptor: a flake with no inputs exporting `lib.instance`.
    ci-instance.url = "github:<operator>/<repository>?dir=ci";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [
        inputs.nix-fleet.flakeModules.ci
        inputs.nix-fleet.flakeModules.tooling
      ];

      ci.instance = inputs.ci-instance.lib.instance;

      perSystem =
        { pkgs, ... }:
        {
          # What the cache retains, and what pull requests build.
          packages.default = pkgs.hello;
          # Updates beyond flake.lock, proposed in the same pull request:
          # packageUpdates.lockfiles.cargo.ecosystem = "cargo";
          # packageUpdates.packages = [ "default" ];
        };
    };
}

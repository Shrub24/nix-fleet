{
  # Public inputs only: anything consuming this flake locks just these.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [ inputs.flake-parts.flakeModules.partitions ];

      # CI reads these from the `ci` partition, whose inputs are locked in ci/flake.lock.
      partitionedAttrs = {
        checks = "ci";
        herculesCI = "ci";
      };
      partitions.ci = {
        extraInputsFlake = ./ci;
        module =
          { inputs, ... }:
          {
            imports = [ inputs.nix-fleet.flakeModules.ci ];
            ci.instance = inputs.ci-instance.lib.instance;
            # Updates beyond the two locks, proposed in the same pull request:
            # perSystem.packageUpdates.lockfiles.cargo.ecosystem = "cargo";
          };
      };

      perSystem =
        { pkgs, ... }:
        {
          # What the cache retains, and what pull requests build.
          packages.default = pkgs.hello;
        };
    };
}

# The artefact set a pin protects and verification promises: a linkFarm over the
# published packages, whose closure is exactly that set. Verdicts are not here —
# they answer questions about a revision, and a selection containing them changes on
# every commit.
#
# Published, so a consuming repository can pin and verify its own closure without
# importing the fleet schema (`imports = [ inputs.nix-fleet.flakeModules.cacheRoot ];`).
{ lib, ... }:
let
  cacheRootModule = _: {
    perSystem =
      { config, pkgs, ... }:
      {
        packages.cache-root = pkgs.linkFarm "cache-root" (
          lib.mapAttrsToList (name: path: { inherit name path; }) (
            lib.filterAttrs (name: _: name != "cache-root") config.packages
          )
        );
      };
  };
in
{
  flake.flakeModules.cacheRoot = cacheRootModule;

  imports = [ cacheRootModule ];
}

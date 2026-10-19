# One linkFarm over the checks, whose closure is every published output; a pin on it
# covers the selection (checks.packages already includes the packages).
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    {
      checks.cache-root = pkgs.linkFarm "cache-root" (
        lib.mapAttrsToList (name: path: { inherit name path; }) (
          lib.filterAttrs (name: _: name != "cache-root") config.checks
        )
      );
    };
}

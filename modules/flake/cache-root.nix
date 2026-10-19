# One aggregate root whose closure is every build this repository publishes. The
# candidate pipeline builds exactly this selection and the cache warms it; the
# post-merge verifier pins this one path per system, and because a pin protects
# the pinned path's whole dependency tree, one pin covers the selection.
#
# It aggregates the checks rather than the packages because `checks.packages`
# already covers the published packages, so including the checks covers both.
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

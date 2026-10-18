# One check that realises every package this repository publishes. The entries
# are config.packages verbatim, so the check adds no derivation of its own: it
# is the closure the candidate pipeline builds and the cache must serve.
{
  perSystem =
    { config, pkgs, ... }:
    {
      checks.packages = pkgs.linkFarm "packages" (
        pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) config.packages
      );
    };
}

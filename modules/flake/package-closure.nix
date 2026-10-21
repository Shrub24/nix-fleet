# One check that realises every package this repository publishes. The entries
# are config.packages verbatim, so the check adds no derivation of its own: it
# is the closure the candidate pipeline builds and the cache must serve.
{
  perSystem =
    { config, pkgs, ... }:
    {
      # cache-root is the subject pin-cache and verify-cache resolve, so it has to be
      # inside the closure this check realises or a promotion has nothing to pin.
      checks.packages =
        assert config.packages ? cache-root;
        pkgs.linkFarm "packages" (
          pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) config.packages
        );
    };
}

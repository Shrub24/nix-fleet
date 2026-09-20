# Published secrets helper: the canonical SOPS option/assertion/registration
# helpers, exposed as `flake.lib.secrets` so consumers import the same file this
# repository's aspects use instead of carrying their own copy.
#
# Consumers:
#   secretHelpers = inputs.nix-fleet.flake.lib.secrets;
# Repository-internal aspects:
#   secretHelpers = import ../lib/secrets.nix { inherit lib; };
# Both resolve to the identical function, so an option declared with one is
# merge-compatible with a consumer binding declared with the other.
{
  lib,
  ...
}:
{
  flake.lib.secrets = import ../lib/secrets.nix { inherit lib; };
}

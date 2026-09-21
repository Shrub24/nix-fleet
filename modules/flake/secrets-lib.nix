# Published secrets helper: `lib.secrets` (consumed as
# `inputs.nix-fleet.lib.secrets`); aspects import lib/secrets.nix directly.
# Both resolve to the identical function, so declarations stay merge-compatible.
{
  lib,
  ...
}:
{
  flake.lib.secrets = import ../../lib/secrets.nix { inherit lib; };
}

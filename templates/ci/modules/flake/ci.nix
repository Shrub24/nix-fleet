# This repository's CI: retention, the scheduled update and its policy.
# Option reference: nix-fleet docs/reference/ci-options.md.
{ inputs, ... }:
{
  imports = [ inputs.nix-fleet.flakeModules.ci ];

  # Ecosystem lockfiles refreshed in the same pull request as the flake inputs:
  # ci.updates.lockfiles.cargo.ecosystem = "cargo";
}

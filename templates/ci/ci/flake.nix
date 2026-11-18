# Inputs of the `ci` partition only; the public flake never locks them.
{
  inputs.nix-fleet.url = "github:Shrub24/nix-fleet";
  outputs = _: { };
}

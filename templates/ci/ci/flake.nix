# Inputs of the `ci` partition only; the public flake never locks them.
{
  inputs = {
    nix-fleet.url = "github:Shrub24/nix-fleet";
    # The operator's instance descriptor: a flake with no inputs exporting `lib.instance`.
    ci-instance.url = "github:<operator>/<repository>?dir=ci";
  };
  outputs = _: { };
}

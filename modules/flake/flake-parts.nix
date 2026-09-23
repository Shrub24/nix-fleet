# Required extra: without this, multiple aspect files defining `flake.modules`
# produce "The option 'flake.modules' is defined multiple times".
{ lib, inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
  config.flake.modules = lib.mkDefault { };
  # Multiple contributors publish under flake.lib (secrets, registry); without
  # a merging declaration the option system rejects the second definition.
  options.flake.lib = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = { };
  };
  # Published flake modules (tooling, fleet): same merging
  # declaration requirement as flake.lib.
  options.flake.flakeModules = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = { };
  };
}

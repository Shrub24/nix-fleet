# Required extra: without this, multiple aspect files defining `flake.modules`
# produce "The option 'flake.modules' is defined multiple times".
{ lib, inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
  config.flake.modules = lib.mkDefault { };
}

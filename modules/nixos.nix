# NixOS wiring module: maps declared configurations.nixos entries to flake
# outputs and exposes one fixture class so `nix flake check` evaluates aspects
# without hosting real configurations.
{ lib, config, inputs, ... }:
{
  options.configurations.nixos = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options.module = lib.mkOption { type = lib.types.deferredModule; };
    });
    default = { };
  };

  config.flake.nixosConfigurations = lib.mapAttrs
    (name: { module, ... }: inputs.nixpkgs.lib.nixosSystem { modules = [ module ]; })
    config.configurations.nixos;
}

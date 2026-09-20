# NixOS wiring module: maps declared configurations.nixos entries to flake
# outputs, and projects each configuration's toplevel into perSystem checks so
# `nix flake check` builds it — runtime wiring (unit ordering, rendered files)
# is verified, not just evaluated.
{
  lib,
  config,
  inputs,
  ...
}:
{
  options.configurations.nixos = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options.module = lib.mkOption { type = lib.types.deferredModule; };
      }
    );
    default = { };
  };

  config = {
    flake.nixosConfigurations = lib.mapAttrs (
      _name: { module, ... }: inputs.nixpkgs.lib.nixosSystem { modules = [ module ]; }
    ) config.configurations.nixos;

    perSystem =
      { system, ... }:
      let
        # NixOS configurations are evaluated by `nix flake check` but their
        # toplevels are not built by it; this check makes building them part of
        # the contract so runtime wiring (unit ordering, rendered files) is
        # verified.
        hostConfigurations = lib.filterAttrs (
          _name: nixos:
          nixos.config.nixpkgs.hostPlatform.parsed == (inputs.nixpkgs.lib.systems.elaborate system).parsed
        ) config.flake.nixosConfigurations;
      in
      {
        checks = lib.mapAttrs (_name: nixos: nixos.config.system.build.toplevel) hostConfigurations;
      };
  };
}

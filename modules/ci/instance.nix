# flakeModules.ci: the fleet's federated CI interface. A repository imports it and
# the fleet's nixbot instance builds its `checks`, retains its roots in the cache and
# proposes its updates. The interface is one `ci` namespace assembled from the
# sibling files in this directory; this one binds the instance.
#
# Contract: docs/contracts/federated-ci.md.
{
  config,
  inputs,
  lib,
  ...
}:
let
  claims = import ../../lib/ci.nix lib;
  # nix-fleet's own inventory, so a repository binds the instance without restating it.
  canonicalInstance = claims.resolveInstance config.fleet;

  module =
    { config, lib, ... }:
    {
      key = "nix-fleet#ci.instance";

      options.ci = {
        instance = lib.mkOption {
          type = lib.types.submodule {
            options = {
              system = lib.mkOption {
                type = lib.types.str;
                description = "System the controller evaluates and runs effects on.";
              };
              cacheUrl = lib.mkOption {
                type = lib.types.str;
                description = "Public read URL of the cache; also the token audience.";
              };
              writeEndpoint = lib.mkOption {
                type = lib.types.str;
                description = "niks3 server URL effects push and pin through.";
              };
              nixbotUrl = lib.mkOption {
                type = lib.types.str;
                description = "The controller's public URL.";
              };
              appId = lib.mkOption {
                type = lib.types.ints.positive;
                description = "The nixbot GitHub App's id.";
              };
            };
          };
          default = canonicalInstance;
          defaultText = lib.literalExpression "nix-fleet's lib.ci.instance";
          description = "The fleet's nixbot instance, resolved from nix-fleet's canonical inventory.";
        };
        nixPackage = lib.mkOption {
          type = lib.types.package;
          default = inputs.nixpkgs.legacyPackages.${config.ci.instance.system}.nix;
          defaultText = lib.literalMD "nix-fleet's nixpkgs `nix` for the instance system";
          description = "Nix CLI the effects call.";
        };
        niks3Package = lib.mkOption {
          type = lib.types.package;
          default = inputs.niks3.packages.${config.ci.instance.system}.default;
          defaultText = lib.literalMD "nix-fleet's niks3 input";
          description = "niks3 client used to push and pin.";
        };
      };
    };
in
{
  # This repository is a consumer too (modules/flake/ci.nix).
  imports = [ module ];
  flake.modules.flake.ci = module;
  flake.flakeModules.ci = config.flake.modules.flake.ci;
  flake.lib.ci = builtins.removeAttrs claims [ "resolveInstance" ] // {
    instance = canonicalInstance;
  };
}

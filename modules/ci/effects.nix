# flakeModules.ci: every effect is an entry of `ci.effects`, the fleet's included,
# so a repository extends or disables them with ordinary module semantics. This file
# renders the entries into nixbot's `herculesCI`.
{ inputs, lib, ... }:
let
  claims = import ../../lib/ci.nix lib;

  module =
    {
      config,
      lib,
      withSystem,
      ...
    }:
    let
      cfg = config.ci;
      effectType = lib.types.attrsOf (lib.types.functionTo (lib.types.nullOr lib.types.raw));
    in
    {
      key = "nix-fleet#ci.effects";

      options.ci.effects = {
        onPush = lib.mkOption {
          type = effectType;
          default = { };
          description = ''
            Effects under the `${claims.pushJob}` onPush job, each a function of
            `{ primaryRepo, pkgs, effects, perSystem, ... }` returning an effect or
            null (not this push).
          '';
        };
        onSchedule = lib.mkOption {
          type = effectType;
          default = { };
          description = "Schedule jobs, each a function of the same arguments returning `{ when; outputs.effects; }` or null.";
        };
      };

      config.flake.herculesCI =
        args:
        withSystem cfg.instance.system (
          { pkgs, config, ... }:
          let
            context = args // {
              inherit pkgs;
              effects = inputs.nixbot.lib.effects { inherit pkgs; };
              perSystem = config;
            };
            render = lib.flip lib.pipe [
              (lib.mapAttrs (_: entry: entry context))
              (lib.filterAttrs (_: value: value != null))
            ];
          in
          {
            onPush.${claims.pushJob}.outputs.effects = render cfg.effects.onPush;
            onSchedule = render cfg.effects.onSchedule;
          }
        );
    };
in
{
  imports = [ module ];
  flake.modules.flake.ci = module;
}

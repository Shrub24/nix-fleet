# Transitional migration shim. The fleet feature lives in
# flakeModules.fleet; the realization is evaluation-local
# (config.fleet.realization) and must never be imported from nix-fleet's own
# output — a module constructed there would bind nix-fleet's inventory, not
# the consumer's. Remove once both consumers have migrated.
_: {
  flake.modules.nixos = {
    fleet-builders = throw ''
      fleet-builders: this pre-realized module no longer exists.
      Import the fleet feature at flake level instead:
        imports = [ inputs.nix-fleet.flakeModules.fleet ];
      then, in a host composition:
        imports = [ config.fleet.realization ];
      (config.fleet.realization is built in YOUR evaluation with YOUR fleet
      config; importing it from inputs.nix-fleet.* would silently bind
      nix-fleet's own inventory.)'';

    builder-access = throw ''
      builder-access: replaced by the fleet feature.
      Import inputs.nix-fleet.flakeModules.fleet at flake level and use
      config.fleet.realization in host compositions.'';
  };
}

# Fleet-builder NixOS realization, constructed from the consumer's flake-level
# registry — a NixOS module cannot read flake config, so flakeModules.fleet-builders
# builds the NixOS module in the consumer's own evaluation with the registry
# closed over. Two seams: trust (known hosts + client tuning, additive, always
# on) and scheduling (builder-set selection driving nix.buildMachines; nixpkgs
# renders /etc/nix/machines and the builders setting from it).
let
  fleetBuildersModule =
    {
      lib,
      config,
      ...
    }:
    let
      render = import ../../lib/registry-render.nix lib;
      registry =
        config.fleet
          or (throw "fleet-builders: import flakeModules.registry (declares fleet.hosts / fleet.builders / fleet.builderSets) alongside flakeModules.fleet-builders");

      buildersModule =
        { config, ... }:
        let
          cfg = config.services.fleet-builders;

          activeBuilders =
            if cfg.activeSet == null then
              { }
            else
              let
                names =
                  registry.builderSets.${cfg.activeSet}
                    or (throw "fleet-builders: activeSet '${cfg.activeSet}' names no fleet.builderSets entry.");
              in
              lib.genAttrs names (
                name:
                registry.builders.${name}
                  or (throw "fleet-builders: builderSet '${cfg.activeSet}' names unknown builder '${name}'")
              );

          legacyHosts = config.services.builder-access.hosts or { };
        in
        {
          options.services.fleet-builders = {
            activeSet = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Name of the fleet.builderSets entry whose builders this host schedules against. null = trust only, no scheduling.";
            };

            sshUser = lib.mkOption {
              type = lib.types.str;
              default = "root";
              description = "User builders are dialed as.";
            };

            extraKnownHosts = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    hostNames = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                    };
                    publicKey = lib.mkOption {
                      type = lib.types.str;
                    };
                  };
                }
              );
              default = { };
              description = "Trust beyond the registry; additive so consumers can trust non-fleet hosts.";
            };
          };

          config = {
            assertions = [
              {
                assertion = legacyHosts == { };
                message = "builder-access: services.builder-access.hosts was replaced by the fleet registry (fleet.hosts / fleet.builders / fleet.builderSets, bound at flake level in your consumer) plus services.fleet-builders.activeSet.";
              }
            ];

            programs.ssh.knownHosts = render.knownHosts registry.hosts registry.builders // cfg.extraKnownHosts;

            programs.ssh.extraConfig = render.sshConfig registry.hosts activeBuilders;

            nix.distributedBuilds = cfg.activeSet != null;

            nix.buildMachines = lib.mapAttrsToList (
              _name: builder:
              let
                hostKey =
                  if (builder.publicHostKey or null) != null then
                    builder.publicHostKey
                  else if (builder.host or null) != null then
                    registry.hosts.${builder.host}.publicKey
                  else
                    null;
                # nixpkgs wants the base64 body of the key line, not the full record.
                keyBody = if hostKey == null then null else lib.elemAt (lib.splitString " " hostKey) 1;
              in
              {
                hostName = render.builderHostName registry.hosts builder;
                # Comma-joined: nix's machines-file parser accepts a system list.
                system = lib.concatStringsSep "," builder.systems;
                inherit (cfg) sshUser;
                sshKey = builder.sshKeyPath;
                protocol = "ssh-ng";
                inherit (builder)
                  maxJobs
                  speedFactor
                  supportedFeatures
                  mandatoryFeatures
                  ;
                publicHostKey = keyBody;
              }
            ) activeBuilders;
          };
        };

      # Legacy NixOS-class import path: carries only the migration diagnostic,
      # never registry data (a module constructed in nix-fleet's evaluation
      # would leak nix-fleet's own inventory into the consumer).
      legacyShim =
        { config, ... }:
        {
          options.services.builder-access.hosts = lib.mkOption {
            type = lib.types.attrsOf lib.types.raw;
            default = { };
            description = "Removed: bind fleet.hosts / fleet.builders / fleet.builderSets in the consumer flake instead.";
          };

          config.assertions = [
            {
              assertion = config.services.builder-access.hosts == { };
              message = "builder-access: services.builder-access.hosts was replaced by the fleet registry (fleet.hosts / fleet.builders / fleet.builderSets, bound at flake level in your consumer) plus services.fleet-builders.activeSet.";
            }
          ];
        };
    in
    {
      flake.modules.nixos = {
        fleet-builders = buildersModule;
        builder-access = legacyShim;
      };
    };
in
{
  flake.flakeModules.fleet-builders = fleetBuildersModule;

  imports = [ fleetBuildersModule ];
}

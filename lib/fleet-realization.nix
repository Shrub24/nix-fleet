# The NixOS-class realization of the fleet builder mechanism, constructed in
# the consuming evaluation with the merged fleet config closed over — a NixOS
# module cannot read flake config, so this module is produced, not published.
# Exposed as config.fleet.realization; flakeModules.fleet wires it into the
# consumer's host compositions. Two seams: trust (known hosts + client tuning,
# additive, always on) and scheduling (builder-set selection driving
# nix.buildMachines; nixpkgs renders /etc/nix/machines and the builders
# setting from it).
fleet:
{
  lib,
  config,
  ...
}:
let
  render = import ./registry-render.nix lib;
  registry = fleet;
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
      default = "nixbuild";
      description = "User builders are dialed as when the builder record sets no sshUser. The fleet convention is a dedicated nixbuild account (created by this aspect on hosts that receive builds), isolated from general-purpose users.";
    };

    createBuildUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the dedicated nixbuild service account on this host (a builder-side setting: the account remote coordinators dial as). Its authorized keys are consumer policy.";
    };

    buildUserName = lib.mkOption {
      type = lib.types.str;
      default = "nixbuild";
      description = "Name of the builder-side dispatch account. Rename only when a consumer needs a differently-scoped identity; the default is the fleet convention.";
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
      description = "Trust beyond the fleet inventory; additive so consumers can trust non-fleet hosts.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.services.builder-access.hosts or { } == { };
          message = "builder-access: services.builder-access.hosts was replaced by the fleet inventory (fleet.hosts / fleet.builders / fleet.builderSets in nix-fleet) plus services.fleet-builders.activeSet.";
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
            else if ((registry.hosts.${builder.host} or { }).publicKey or null) != null then
              registry.hosts.${builder.host}.publicKey
            else
              throw "fleet: builder '${_name}' has no host key — its fleet host '${builder.host}' has publicKey = null (not yet harvested) and the builder declares no publicHostKey";
          # nixpkgs wants the base64 body of the key line, not the full record.
          keyBody = if hostKey == null then null else lib.elemAt (lib.splitString " " hostKey) 1;
        in
        {
          hostName = render.builderHostName registry.hosts builder;
          # Comma-joined: nix's machines-file parser accepts a system list.
          system = lib.concatStringsSep "," builder.systems;
          sshUser = if (builder.sshUser or null) != null then builder.sshUser else cfg.sshUser;
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
    }

    # The builder-side service account: isolated dial-in identity for remote
    # build dispatch, no login shell, owned by this aspect so the fleet
    # convention (dial as nixbuild) has an owner everywhere.
    (lib.mkIf cfg.createBuildUser {
      users.users.${cfg.buildUserName} = {
        isSystemUser = true;
        group = cfg.buildUserName;
        description = "Fleet remote-build dispatch account";
        useDefaultShell = false;
        home = "/var/lib/${cfg.buildUserName}";
        createHome = true;
        openssh.authorizedKeys.keys = [ ];
      };
      users.groups.${cfg.buildUserName} = { };
    })
  ];
}

# The fleet feature: one published flakeModule composing the typed schema, the
# canonical inventory, validation, CI artifact derivation, and the
# evaluation-local realization (config.fleet.realization). Internal source
# files stay split by semantic ownership; the public surface is this single
# import. The NixOS realization is never published as a pre-realized module —
# it must bind the consuming evaluation's merged fleet config, so it lives at
# config.fleet.realization for host compositions to import.
{
  lib,
  config,
  ...
}:
let
  render = import ../../lib/registry-render.nix lib;

  # Named, fail-closed registry validation. Run by the render check and by the
  # realization, so an invalid inventory fails with the specific problem.
  validationErrors =
    fleet:
    let
      setMembers = lib.flatten (lib.attrValues fleet.builderSets);
      unknownSetMember = lib.filter (name: !fleet.builders ? ${name}) setMembers;
      unknownHostRef = lib.filter (
        b: (b.host or null) != null && !(fleet.hosts ? ${b.host} || config.fleet.hosts ? ${b.host})
      ) (lib.attrValues fleet.builders);
      variantViolations = lib.filter (b: ((b.host or null) != null) == ((b.uri or null) != null)) (
        lib.attrValues fleet.builders
      );
    in
    lib.concatMap (name: [
      "fleet: builderSet names builder '${name}' missing from fleet.builders"
    ]) unknownSetMember
    ++ lib.concatMap (b: [
      "fleet: builder references fleet host '${b.host}' missing from fleet.hosts"
    ]) unknownHostRef
    ++ lib.concatMap (_: [
      "fleet: every builder must set exactly one of host or uri"
    ]) variantViolations;

  assertRegistry =
    fleet:
    let
      errors = validationErrors fleet;
    in
    if errors == [ ] then true else throw (lib.head errors);

  # Renderer grammar check on sample data covering both builder variants and
  # every placeholder form; the real consumer-bound inventory is validated by
  # the same check, so an invalid record fails `nix flake check` by name.
  sample = {
    hosts.sample-host = {
      tailscale.hostname = "fleet-host";
      hostNames = [ "fleet-host" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAI-sample";
    };
    builders = {
      sample-fleet = {
        host = "sample-host";
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        maxJobs = 2;
        speedFactor = 2;
        supportedFeatures = [ "big-parallel" ];
        mandatoryFeatures = [ "nixos-test" ];
      };
      sample-external = {
        uri = "ssh-ng://eu.nixbuild.net";
        systems = [ "aarch64-linux" ];
        maxJobs = 4;
        sshKeyPath = "/run/nixbuild-key";
        publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI-sample-external";
        sshOptions = { };
      };
    };
    builderSets.default = [
      "sample-fleet"
      "sample-external"
    ];
  };

  realizationModule = import ../../lib/fleet-realization.nix config.fleet;

  fleetModule = {
    imports = [ ./schema.nix ];

    config = {
      _module.args = { };

      # The evaluation-local realization, available to host compositions as
      # config.fleet.realization.
      fleet.realization = realizationModule;

      perSystem =
        { pkgs, ... }:
        let
          ciArtifacts =
            setName:
            let
              names =
                config.fleet.builderSets.${setName}
                  or (throw "fleet: builderSet '${setName}' does not exist; declared sets: ${lib.concatStringsSep ", " (builtins.attrNames config.fleet.builderSets)}");
              selected = lib.genAttrs names (
                name:
                config.fleet.builders.${name}
                  or (throw "fleet: builderSet '${setName}' names unknown builder '${name}'")
              );
              hosts = lib.filterAttrs (
                id: _: lib.any (b: (b.host or null) == id) (lib.attrValues selected)
              ) config.fleet.hosts;
            in
            assert assertRegistry config.fleet;
            pkgs.runCommand "ci-builders-${setName}"
              {
                machines = render.machinesFile hosts selected;
                sshConfig = render.sshConfig hosts selected;
                knownHosts = builtins.toJSON (render.knownHosts hosts selected);
                passAsFile = [
                  "machines"
                  "sshConfig"
                  "knownHosts"
                ];
              }
              ''
                mkdir -p $out
                cp "$machinesPath" $out/machines
                cp "$sshConfigPath" $out/ssh_config
                # JSON entries -> /etc/ssh/ssh_known_hosts line format.
                ${pkgs.jq}/bin/jq -r 'to_entries[] | .value.hostNames[] as $n | "\($n) \(.value.publicKey)"' \
                  "$knownHostsPath" > $out/known_hosts
              '';
        in
        {
          checks.fleet-render =
            assert assertRegistry sample;
            assert assertRegistry config.fleet;
            pkgs.runCommand "fleet-render-check"
              {
                machines = render.machinesFile sample.hosts sample.builders;
                sshConfig = render.sshConfig sample.hosts sample.builders;
                knownHosts = builtins.toJSON (render.knownHosts sample.hosts sample.builders);
                passAsFile = [
                  "machines"
                  "sshConfig"
                  "knownHosts"
                ];
              }
              ''
                awk 'NF > 0 { if (NF != 7) { print "fleet: machines line has " NF " fields, expected 7"; exit 1 } }' "$machinesPath"
                grep -qx 'ssh-ng://fleet-host x86_64-linux,aarch64-linux - 2 2 big-parallel nixos-test' "$machinesPath" \
                  || { echo "fleet: fleet-host line wrong"; cat "$machinesPath"; exit 1; }
                grep -qx 'ssh-ng://eu.nixbuild.net aarch64-linux /run/nixbuild-key 4 1 - -' "$machinesPath" \
                  || { echo "fleet: external line wrong"; cat "$machinesPath"; exit 1; }
                grep -qx 'Host eu.nixbuild.net' "$sshConfigPath" \
                  || { echo "fleet: ssh Host block missing"; cat "$sshConfigPath"; exit 1; }
                grep -q '"host-sample-host"' "$knownHostsPath" \
                  || { echo "fleet: host known-hosts entry missing"; cat "$knownHostsPath"; exit 1; }
                grep -q '"builder-sample-external"' "$knownHostsPath" \
                  || { echo "fleet: external builder known-hosts entry missing"; cat "$knownHostsPath"; exit 1; }
                cat "$machinesPath" > "$out"
              '';

          # CI builder bundles, one per declared builder set: machines file,
          # known-hosts, ssh client config. The build-push-cache workflow
          # template installs these; the builder-set name is the only selection
          # the workflow makes.
          packages = builtins.mapAttrs (setName: _: ciArtifacts setName) config.fleet.builderSets;
        };
    };
  };

in
{
  flake.flakeModules.fleet = fleetModule;

  imports = [ fleetModule ];
}

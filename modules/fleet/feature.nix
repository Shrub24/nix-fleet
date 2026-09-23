# The fleet feature: one published flakeModule composing the typed schema,
# the canonical inventory, validation, and CI artifact derivation. nix-fleet
# exposes facts + pure projections; there is no NixOS module published here
# and no cross-class realization — a consumer's own flake-level module closes
# over its config.fleet and calls resolveBuildProfile (docs/contracts/
# builders.md carries the ~15-line wiring pattern).
{
  lib,
  config,
  ...
}:
let
  resolve = import ../../lib/build-profile.nix lib;

  # Named, fail-closed inventory validation, run by the render check so an
  # invalid canonical record fails `nix flake check` by name.
  validationErrors =
    fleet:
    lib.concatMap (
      hostId:
      lib.optionals
        (fleet.hosts.${hostId}.capabilities.nixBuilder.enable && fleet.hosts.${hostId}.system == null)
        [
          "fleet: host '${hostId}' has capabilities.nixBuilder.enable but no system — a builder must declare what it builds natively"
        ]
    ) (builtins.attrNames fleet.hosts)
    ++ lib.concatMap (
      extId:
      lib.optionals (fleet.externalBuilders.${extId}.publicHostKey == null) [
        "fleet: external builder '${extId}' has no publicHostKey — there is no host record to inherit trust from"
      ]
    ) (builtins.attrNames fleet.externalBuilders);

  assertRegistry =
    fleet:
    let
      errors = validationErrors fleet;
    in
    if errors == [ ] then true else throw (lib.head errors);

  # Renderer grammar check on sample data covering both member variants and
  # per-profile overrides; the real consumer-bound inventory is validated by
  # the same check.
  sample = {
    hosts.sample-host = {
      system = "x86_64-linux";
      tailscale.hostname = "fleet-host";
      hostNames = [ "fleet-host" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAI-sample";
      capabilities.nixBuilder = {
        enable = true;
        maxJobs = 1;
        supportedFeatures = [ "kvm" ];
      };
    };
    externalBuilders.sample-external = {
      uri = "ssh-ng://eu.nixbuild.net";
      systems = [ "aarch64-linux" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI-sample-external";
    };
    buildProfiles.sample = {
      hosts.sample-host.maxJobs = 2;
      hosts.sample-host.supportedFeatures = [
        "big-parallel"
        "nixos-test"
      ];
      external.sample-external = {
        maxJobs = 4;
        sshUser = "root";
      };
    };
  };

  sampleSpecs = resolve.resolveBuildProfile sample "sample";

  ciArtifacts =
    { pkgs }:
    profileName:
    let
      specs = resolve.resolveBuildProfile config.fleet profileName;
    in
    assert resolve.assertNonEmpty profileName specs;
    pkgs.runCommand "ci-builders-${profileName}"
      rec {
        machines = resolve.machinesFile specs;
        sshConfig = resolve.sshConfig specs;
        knownHosts = builtins.toJSON (resolve.knownHosts specs);
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

  fleetModule = {
    imports = [
      ./schema.nix
      ./inventory.nix
    ];

    config = {
      perSystem =
        { pkgs, ... }:
        {
          checks.fleet-render =
            assert assertRegistry sample;
            assert assertRegistry config.fleet;
            let
              specs = sampleSpecs;
            in
            pkgs.runCommand "fleet-render-check"
              rec {
                machines = resolve.machinesFile specs;
                sshConfig = resolve.sshConfig specs;
                knownHosts = builtins.toJSON (resolve.knownHosts specs);
                passAsFile = [
                  "machines"
                  "sshConfig"
                  "knownHosts"
                ];
              }
              ''
                awk 'NF > 0 { if (NF != 7) { print "fleet: machines line has " NF " fields, expected 7"; exit 1 } }' "$machinesPath"
                grep -qx 'ssh-ng://fleet-host x86_64-linux - 2 1 big-parallel,nixos-test -' "$machinesPath" \
                  || { echo "fleet: fleet-host line wrong (override not applied?)"; cat "$machinesPath"; exit 1; }
                grep -qx 'ssh-ng://eu.nixbuild.net aarch64-linux - 4 1 - -' "$machinesPath" \
                  || { echo "fleet: external line wrong"; cat "$machinesPath"; exit 1; }
                grep -qx '  User root' "$sshConfigPath" \
                  || { echo "fleet: external sshUser override missing"; cat "$sshConfigPath"; exit 1; }
                cat "$machinesPath" > "$out"
              '';

          # CI builder bundles, one per declared build profile: machines file,
          # known-hosts (projection of the profile selection only), ssh client
          # config. The build-push-cache workflow installs these; the profile
          # name is the only selection the workflow makes.
          packages = builtins.mapAttrs (
            name: _: ciArtifacts { inherit pkgs; } name
          ) config.fleet.buildProfiles;
        };
    };
  };
in
{
  flake.flakeModules.fleet = fleetModule;

  flake.lib.buildProfile = resolve;

  # Self-application (dogfood): the published module's perSystem pieces (render
  # check, CI bundles) only land when the module is imported into this
  # evaluation too.
  imports = [ fleetModule ];
}

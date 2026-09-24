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
      let
        host = fleet.hosts.${hostId};
      in
      lib.optionals
        (((host.capabilities or { }).nixBuilder or { }).enable or false && (host.system or null) == null)
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
    hosts.sample-nonbuilder = {
      system = null;
      tailscale.hostname = "fleet-peer";
      hostNames = [ "fleet-peer" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAI-sample-peer";
      managementUser = null; # reach identity unset: sshConfig must omit User
    };
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

  # The separation is load-bearing: the non-builder that resolveHosts accepts
  # must stay unreachable through the scheduling door. Forced by the render
  # check below (deepSeq in its attrset), so relaxing the capability check
  # fails `nix flake check` here instead of silently widening scheduling.
  schedulingRejection =
    let
      leak = {
        inherit (sample) hosts;
        externalBuilders = { };
        buildProfiles.trust-leak.hosts.sample-nonbuilder = { };
      };
    in
    !(builtins.tryEval (builtins.deepSeq (resolve.resolveBuildProfile leak "trust-leak") true)).success;

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
            assert schedulingRejection;
            # Scheduling path (sampleSpecs) and trust path (trustSpecs) both
            # render here; the trust selection includes a NON-builder. The
            # separation itself is pinned by the schedulingRejection binding
            # below — if the capability check ever relaxes, eval fails there.
            let
              specs = sampleSpecs;
              trustSpecs = resolve.resolveHosts sample {
                sample-nonbuilder = { };
                sample-host = { }; # a BuilderSpec's host renders trust too
              };
            in
            pkgs.runCommand "fleet-render-check"
              rec {
                machines = resolve.machinesFile specs;
                sshConfig = resolve.sshConfig specs;
                knownHosts = builtins.toJSON (resolve.knownHosts specs);
                optionForm = builtins.toJSON (resolve.buildMachines specs);
                trustKnownHosts = builtins.toJSON (resolve.knownHosts trustSpecs);
                trustSshConfig = resolve.sshConfig trustSpecs;
                knownHostsText = resolve.knownHostsText trustSpecs;
                passAsFile = [
                  "machines"
                  "sshConfig"
                  "knownHosts"
                  "optionForm"
                  "trustKnownHosts"
                  "trustSshConfig"
                  "knownHostsText"
                ];
              }
              ''
                awk 'NF > 0 { if (NF != 7) { print "fleet: machines line has " NF " fields, expected 7"; exit 1 } }' "$machinesPath"
                grep -qx 'ssh-ng://nixbuild@fleet-host x86_64-linux - 2 1 big-parallel,nixos-test -' "$machinesPath" \
                  || { echo "fleet: fleet-host line wrong (override not applied?)"; cat "$machinesPath"; exit 1; }
                grep -qx 'ssh-ng://root@eu.nixbuild.net aarch64-linux - 4 1 - -' "$machinesPath" \
                  || { echo "fleet: external line wrong"; cat "$machinesPath"; exit 1; }
                grep -qx '  User root' "$sshConfigPath" \
                  || { echo "fleet: external sshUser override missing"; cat "$sshConfigPath"; exit 1; }

                # Nix-module form ≡ machines-file form. nixpkgs composes its
                # machines-file first field as protocol://sshUser@hostName from
                # the option form's separate fields; that has to equal the first
                # field the text renderer emits, or the two disagree about who
                # gets dialed.
                ${pkgs.jq}/bin/jq -r '.[] | "\(.protocol)://\(.sshUser)@\(.hostName)"' "$optionFormPath" > option-form
                awk 'NF > 0 { print $1 }' "$machinesPath" > machines-form
                paste option-form machines-form | awk '$1 != $2 { print "fleet: option form says " $1 " but machines-file form says " $2; exit 1 }'

                # Trust path: both selected hosts land, the non-builder included.
                grep -q '"host-sample-nonbuilder"' "$trustKnownHostsPath" \
                  || { echo "fleet: resolveHosts omitted the non-builder"; cat "$trustKnownHostsPath"; exit 1; }
                grep -q '"host-sample-host"' "$trustKnownHostsPath" \
                  || { echo "fleet: resolveHosts omitted the builder host"; cat "$trustKnownHostsPath"; exit 1; }
                # managementUser = null: no User line, never the dispatch default.
                grep -q 'User' "$trustSshConfigPath" \
                  && { echo "fleet: sshConfig emitted a User line for managementUser = null"; cat "$trustSshConfigPath"; exit 1; }
                grep -qx 'Host fleet-peer' "$trustSshConfigPath" \
                  || { echo "fleet: trust sshConfig missing the peer Host block"; cat "$trustSshConfigPath"; exit 1; }

                # Text-form ≡ option-form knownHosts: every attrset entry's
                # key must appear in the line form (same selection, same set).
                ${pkgs.jq}/bin/jq -r 'to_entries[] | .value.hostNames[0] + " " + .value.publicKey' "$trustKnownHostsPath" \
                  | while read -r line; do
                      grep -qx "$line" "$knownHostsTextPath" \
                        || { echo "fleet: knownHostsText missing line: $line"; exit 1; }
                    done

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

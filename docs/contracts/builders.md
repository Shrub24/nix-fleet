# Builders contract — capabilities, profiles, scheduling

Canonical build capability and scheduling policy live in nix-fleet; consumers
derive and add local policy. Built on the host identity from
[hosts.md](hosts.md); consumed by CI via [ci.md](ci.md).

## Model

"Builder" is not a second identity registry. A machine's ability to build is
a **capability** on its host record; a **profile** is the scheduling policy
binding a workload class to specific builders; **external resources** (no
host record) are their own small namespace.

- `fleet.hosts.<id>.capabilities.nixBuilder` — the machine can build. The
  host's `system` is what it builds natively; `extraSystems` is the explicit
  exception (emulation).
- `fleet.externalBuilders.<name>` — externally provided build resources
  (nixbuild.net). Narrow on purpose: uri, systems, publicHostKey, metered.
- `fleet.buildProfiles.<name>` — explicit membership (`hosts` + `external`)
  with per-member overrides. Scheduling parameters belong to the
  relationship between workload and builder, hence overrides live on the
  member, not the resource: `maxJobs` for nixbuild is the metered-cost knob.

Deliberately absent: weights, predicates, inheritance, tags-as-selectors,
availability schedulers, an all-hosts profile. "Every machine capable of
building" is a discoverable fact, not a safe scheduling policy — a consumer
wanting breadth writes the explicit profile.

## The two-stage public API

```
fleet.hosts (+ fleet.externalBuilders + fleet.buildProfiles.<name>)
        ↓  resolveBuildProfile      (stage 1: normalize; builders only)
              BuilderSpec[]          = HostSpec + scheduling fields
        ↓  renderers                (stage 2: project)
   nix.buildMachines | machinesFile | knownHosts | sshConfig

fleet.hosts (any selection, no capability required)
        ↓  resolveHosts             (stage 1: trust; HostSpec[])
        ↓  knownHosts | sshConfig   (same stage-2 renderers)
```

`flake.lib.buildProfile` (nix-fleet) exposes `resolveHosts`,
`resolveBuildProfile`, `buildMachines`, `machinesFile`, `knownHosts`,
`sshConfig`. Consumers never rebuild records by hand. The spec split is the
contract: `HostSpec` is the trust subset (name, hostName, hostNames,
publicKey, sshUser, sshOptions); `BuilderSpec` extends it with the
scheduling fields — trust renderers accept either kind, the scheduling
renderers only BuilderSpec.

Fail-closed, by name: unknown profile, profile member without
`nixBuilder.enable`, host member that doesn't exist, external member that
doesn't exist, empty profile resolution.

## Canonical inventory (nix-fleet side)

```nix
# modules/fleet/inventory.nix
fleet.hosts.home-forge.capabilities.nixBuilder = {
  enable = true;
  maxJobs = 4;
  speedFactor = 2;
  supportedFeatures = [ "big-parallel" "kvm" "nixos-test" ];
  # endpoint.user defaults "nixbuild" (the dispatch account), protocol ssh-ng
};
fleet.externalBuilders.nixbuild = {
  uri = "ssh-ng://eu.nixbuild.net";
  sshUser = "root";
  systems = [ "x86_64-linux" "aarch64-linux" ];
  publicHostKey = "ssh-ed25519 AAAA...";   # from nixbuild's docs
  metered = true;
};
fleet.buildProfiles.ci = {
  hosts.home-forge = { };
  hosts.la-admin-1 = { };
  hosts.oci-melb-1 = { };
};                        # canonical ci = the free fleet
fleet.buildProfiles.arm-expensive = {
  hosts.oci-melb-1 = { };
  external.nixbuild.maxJobs = 4;  # metered-cost knob, per-relationship
};                        # nixbuild only via explicit profile
```

## Consumer adoption (tier 3)

Select the capability aspect on builder hosts (creates the dispatch account):

```nix
# host composition
services.build-account.enable = true;   # modules.nixos.build-account
```

Wire scheduling in your own flake-level module — this replaces
`config.fleet.realization` entirely:

```nix
# consumer flake-parts module (perSystem or configurations wiring)
let
  resolve = inputs.nix-fleet.lib.buildProfile;
  specs = resolve.resolveBuildProfile config.fleet "ci";
in {
  fleet.hosts.mybox.capabilities.nixBuilder.enable = true;  # additive host
  fleet.buildProfiles.mybox = { hosts.mybox = { }; };        # local profile

  configurations.nixos.mybox.module = {
    programs.ssh.knownHosts = resolve.knownHosts specs;   # trust projection
    programs.ssh.extraConfig = resolve.sshConfig specs;
    nix.distributedBuilds = true;
    nix.buildMachines = resolve.buildMachines specs;      # nixpkgs renders
                                                          # /etc/nix/machines
    _module.args.fleetSpecs = specs;   # if a NixOS module needs the specs
  };
}
```

There is no cross-class realization: nix-fleet publishes facts + pure
functions; the consumer's module closes over its own `config.fleet`.

## Trust by projection

`renderKnownHosts` (the `knownHosts` renderer) renders **exactly the
selection** — a profile contributes the host keys it requires, nothing more.
Inventory membership never implies fleet-wide trust. Strict pinned keys are
unchanged.

## Prerequisites when scheduling is enabled

- **Dial account**: `endpoint.user` defaults to `nixbuild` — the dedicated
  dispatch account from the build-account aspect (no shell, revocable,
  isolated from general-purpose users). Not `dev`: dispatch does not need a
  human account.
- **The coordinator's key must be authorized on every selected builder**
  (`users.users.nixbuild.openssh.authorizedKeys` — consumer policy).
  Selecting a profile never _reaches_ the builders.
- **Self-scheduling**: nothing excludes the evaluating host from its own
  profile. A host scheduling a profile containing itself dials itself —
  keep such hosts out or accept the self-entry deliberately.
- **Dispatch vs reach identity**: `endpoint.user` (what nix dials as) and
  `managementUser` (the fleet management account an operator/client logs
  in as) are separate facts; never collapse them, or the trust/scheduling
  conflation returns one level down.

## What stays consumer-side

- Substituter policy (`nix.settings` substituters/trusted keys, including
  `ssh-ng://` substituter entries) — endpoint catalog, not participation.
- Private key material and its path (`sshKeyPath` is a credential
  _reference_; the resolver leaves it null for fleet hosts — the consumer
  adapter fills it from its own secrets).
- SSH server config, GC, remote-builder authorization.
- Non-fleet personal hosts — the canonical inventory is partial by design.

## Migration from the v1 fleet feature

| v1 surface                                 | v2 replacement                                                |
| ------------------------------------------ | ------------------------------------------------------------- |
| `fleet.builders.<name>` (host-backed)      | `fleet.hosts.<id>.capabilities.nixBuilder`                    |
| `fleet.builders.nixbuild` (external)       | `fleet.externalBuilders.nixbuild`                             |
| `fleet.builderSets.<name>` (list of names) | `fleet.buildProfiles.<name>` (members + per-member overrides) |
| `config.fleet.realization` import          | consumer wiring via `flake.lib.buildProfile` (above)          |
| `services.fleet-builders.activeSet`        | the consumer's own resolve → `nix.buildMachines` wiring       |
| `packages.<set>` CI bundles                | `packages.<profile>` (same artifact shape, profile-driven)    |
| `services.fleet-builders.createBuildUser`  | `modules.nixos.build-account` aspect                          |

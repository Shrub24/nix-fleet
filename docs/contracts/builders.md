# Builders contract — participation, sets, scheduling

Canonical builder facts live in nix-fleet; consumers derive and add local
policy. Built on the host identity from [hosts.md](hosts.md); consumed by CI
via [ci.md](ci.md).

## Design decisions

- **One scheduling mechanism: named builder sets.** `fleet.builderSets.<name>`
  is an explicit, auditable list. Metered/external resources (nixbuild.net is
  metered) are spent only by explicit set membership — "which workloads may
  spend nixbuild money" is a readable list.
- **Two mutually exclusive builder variants.** A builder is either backed by
  a fleet host reference (dialled over the tailnet by MagicDNS name, host key
  inherited from the host record) or externally provided by a full store URI
  (e.g. `ssh-ng://eu.nixbuild.net`, own host key).
- **No reachability property.** The variant encodes it: fleet-host = tailnet,
  uri = public. An unreachable builder is a bootstrap failure (CI) or an ops
  problem (hosts), not data.
- **nixbuild.net auth is plain SSH keys** (dashboard-managed, per-client
  private keys are consumer sops business). No tokens.
- **The realization is evaluation-local.** A NixOS module cannot read flake
  config, so nix-fleet publishes the _feature_ (`flakeModules.fleet`), which
  constructs the NixOS realization inside the consumer's evaluation with the
  consumer's merged fleet config closed over. It is exposed as
  `config.fleet.realization` — never as a pre-realized
  `modules.nixos.*` export, which would silently bind nix-fleet's own
  inventory (the transitional shim at `modules.nixos.fleet-builders` throws
  with this exact guidance).

## Canonical inventory (nix-fleet side)

```nix
# modules/fleet/inventory.nix
fleet.builders.home-forge = {
  host = "home-forge";
  systems = [ "x86_64-linux" ];
  maxJobs = 4;                       # shared default, tier 2
  speedFactor = 2;
  supportedFeatures = [ "big-parallel" "kvm" "nixos-test" ];
};
fleet.builders.nixbuild = {
  uri = "ssh-ng://eu.nixbuild.net";
  systems = [ "x86_64-linux" "aarch64-linux" ];
  publicHostKey = "ssh-ed25519 AAAA...";   # from nixbuild's docs
};
fleet.builderSets.ci = [ "home-forge" "nixbuild" ];
```

## Consumer additions (tier 3, additive)

```nix
# consumer flake level — new builders/sets are fine; never shadow canonical IDs
fleet.builderSets.deploy = [ "home-forge" ];        # consumer-local set
fleet.builders.buildbox.uri = "ssh-ng://buildbox";  # consumer-local builder
```

Fail-closed validation (named errors): a set naming an unknown builder, a
builder referencing an unknown host, a builder with both/neither variant set,
a host-backed builder whose host key is unharvested — all fail `nix flake
check` with the specific problem.

## The two seams

1. **Trust** — known-hosts + ssh client Host blocks for inventory hosts.
   Always on, additive, no scheduling implied. See hosts.md.
2. **Scheduling** — on a host composition:

   ```nix
   imports = [ config.fleet.realization ];
   services.fleet-builders.activeSet = "ci";   # null = trust only
   ```

   `activeSet` selects a builder set -> `nix.buildMachines` (comma-joined
   systems, base64 host-key bodies, per-builder features) -> nixpkgs renders
   `/etc/nix/machines` and `nix.settings.builders = "@/etc/nix/machines"`,
   with `nix.distributedBuilds` enabled only when a set is selected.

## Prerequisites when scheduling is enabled

- **`sshUser`** defaults to `dev` — the fleet convention (homelab
  administrates via `dev`, which is in `trusted-users` on fleet hosts, so
  ssh-ng store writes work). Overridable per composition.
- **The coordinator's key must be authorized on every selected builder**
  (builder-side `authorized_keys`/sops — consumer policy). Selecting an
  activeSet never _reaches_ the builders.
- **Self-scheduling:** nothing excludes the evaluating host from its own set.
  A host selecting a set containing itself dials itself. Either keep such
  hosts out of the sets they select, or accept the (wasteful, trust-
  requiring) self-entry deliberately.

## What stays consumer-side

- Substituter policy (`nix.settings` substituters/trusted keys, including
  `ssh-ng://` substituter entries) — endpoint catalog, not participation.
- SSH server config, host key material (private), GC, remote-builder
  _authorization_.
- Non-fleet personal hosts (dotfiles' non-fleet machines) — the canonical
  inventory is partial by design; consumers add only what they configure.

## Migration (transitional)

The pre-consolidation surfaces fail eval with named migration messages:

| Old surface                                                     | Replacement                                                                      |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `inputs.nix-fleet.modules.nixos.fleet-builders`                 | `flakeModules.fleet` at flake level + `config.fleet.realization` in compositions |
| `inputs.nix-fleet.modules.nixos.builder-access`                 | same                                                                             |
| `services.builder-access.hosts`                                 | canonical `fleet.builders.*` (inventory)                                         |
| `flakeModules.registry` / `flakeModules.fleet-builders` imports | single `flakeModules.fleet` import                                               |

Consumers migrating from consumer-declared inventories: move machine
identity to the canonical inventory is already done (nix-fleet extracted
it); consumers only delete their duplicate records and derive. The shims
are removed once both consumers have migrated — do not treat them as a
supported path.

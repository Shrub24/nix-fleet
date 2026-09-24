# Hosts contract — canonical machine identity and trust

nix-fleet is the **authority** for the facts that must agree everywhere:
canonical ID, target system, Tailscale hostname, SSH host public key.
Consumers derive from these records and add only local policy — they never
restate them.

## Fact tiers

| Tier               | Who owns                                  | Examples                                              |
| ------------------ | ----------------------------------------- | ----------------------------------------------------- |
| 1 — canonical fact | nix-fleet (`modules/fleet/inventory.nix`) | `system`, `tailscale.hostname`, `publicKey`           |
| 2 — shared default | nix-fleet schema                          | known-hosts format, ssh client tuning                 |
| 3 — consumer-local | the consumer                              | compositions, service placement, secrets, extra trust |

## What the consumer declares: nothing (for identity)

The canonical inventory lives in nix-fleet:

```nix
# modules/fleet/inventory.nix (nix-fleet side — the authority)
fleet.hosts.oci-melb-1 = {
  system = "aarch64-linux";
  tailscale.hostname = "oci-melb-1";
  hostNames = [ "oci-melb-1" ];
  # publicKey = null until harvested after first deploy
};
```

## What the consumer derives

Homelab keys its richer host records by the same canonical ID and fills in
only what is downstream (compositions, disks, bootstrap, placement):

```nix
# consumer side (nix-homelab modules/hosts/<id>/default.nix)
nixos.hosts.oci-melb-1 = {
  # derived from the canonical facts — do not restate:
  system = config.fleet.hosts.oci-melb-1.system;
  tailscale.hostname = config.fleet.hosts.oci-melb-1.tailscale.hostname;

  # consumer-local (tier 3):
  composition = { ... };
};
```

**Join-key rule:** the canonical ID is the registry key everywhere —
`fleet.hosts.<id>` = homelab `nixos.hosts.<id>` = dotfiles
`topology.hosts.<id>`. IDs are lowercase alphanumeric + dashes.

## What the consumer gets: trust

Trust is a **projection of a selection**, never the whole inventory, and it
has its own door: `resolveHosts` takes any fleet hosts — no build capability
required — so a host you merely talk to can be pinned without becoming
schedulable.

```nix
# trust: name the hosts you interact with (attrset keyed by fleet host id,
# per-host overrides like sshUser mirror the buildProfiles member shape)
specs = resolve.resolveHosts config.fleet {
  home-forge = { };
  spectre = { sshUser = "saurabhj"; };
};
programs.ssh.knownHosts = resolve.knownHosts specs;   # exactly the selection
programs.ssh.extraConfig = resolve.sshConfig specs;   # User from managementUser
```

`scheduling` uses the other door (`resolveBuildProfile`); the two never
constrain each other — naming a host for trust never makes it schedulable,
and the scheduling door still rejects non-builders (pinned by a render
check). Host records carry `managementUser` — the fleet management account an
operator or client logs in as, distinct from a builder's `endpoint.user`
(what nix dials as).

A host with a bound key in the canonical inventory is trusted only where a
selection includes it — inventory membership never implies fleet-wide trust,
and **trust never implies use**: being in the inventory does not make a host
a builder that gets scheduled, a substituter, or a deploy target. Extra
non-fleet trust stays consumer-side (plain `programs.ssh.knownHosts`
entries).

## Host key bootstrap

`publicKey` is nullable by design: a host is declared before its key is
bound (deploy -> harvest -> bind -> trust propagates fleet-wide on the next
flake bump). A builder backed by a keyless host fails closed with a named
error rather than silently rendering keyless trust.

## Deriving inside the same contributor

Reading `config.fleet.hosts.<id>` inside a consumer module that also
declares under `fleet.*` is cycle-free (option merging precedes realization)
— homelab's host records may derive directly.

## Canonical inventory reference (what ships today)

| ID           | System        | Tailscale hostname | publicKey               |
| ------------ | ------------- | ------------------ | ----------------------- |
| `home-forge` | x86_64-linux  | home-forge         | bound (2026-09-22)      |
| `la-admin-1` | x86_64-linux  | la-admin-1         | bound (2026-09-22)      |
| `oci-melb-1` | aarch64-linux | oci-melb-1         | bound (2026-09-22)      |
| `legion`     | x86_64-linux  | legion             | bound (2026-09-24)      |
| `spectre`    | x86_64-linux  | spectre            | unbound (not installed) |

All three server keys are harvested and bound. `legion` and `spectre` are the
workstation pair: identity and trust only, neither carrying
`capabilities.nixBuilder`. `spectre`'s key is unbound until the laptop is
installed — its `tailscale.hostname` is the name it will register under.

This table is documentation of the inventory, not a second copy of it —
`modules/fleet/inventory.nix` is the authority.

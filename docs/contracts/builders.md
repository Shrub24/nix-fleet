# Builders contract — participation, sets, scheduling

How machines (and external services like nixbuild.net) participate as Nix
builders, and how scheduling policy is expressed. Built on the host identity
from [hosts.md](hosts.md); consumed by CI via [ci.md](ci.md).

## Design decisions (why it looks like this)

- **One scheduling mechanism: named builder sets.** Roles/tags-as-filters
  were rejected; `fleet.builderSets.<name>` is an explicit, auditable list.
  Metered or external resources (nixbuild.net is metered) are spent only by
  explicit set membership — "which workloads may spend nixbuild money" is a
  list you can read.
- **Two mutually exclusive builder variants.** A builder is either backed by
  a fleet host reference (dialled over the tailnet by MagicDNS name, host
  key inherited from the host record) or externally provided by a full
  store URI (e.g. `ssh-ng://eu.nixbuild.net`, own host key). Never loosely
  related nullable fields.
- **No reachability property.** The variant already encodes it: fleet-host
  = tailnet, uri = public. An unreachable builder is a workflow bootstrap
  failure (CI) or an ops problem (hosts), not data.
- **nixbuild.net auth is plain SSH keys** — added via the dashboard, private
  keys are per-client consumer secrets. No tokens, no env plumbing; the
  old `NIXBUILDNET_ACCESS_TOKENS` secret in dotfiles was never needed for
  builder use and is discardable.
- **The NixOS aspect is constructed, not imported blindly.** A NixOS module
  cannot read flake-level config, so `flakeModules.fleet-builders` builds
  the aspect inside the consumer's evaluation with _that consumer's_
  registry closed over. Importing a pre-built module from nix-fleet's own
  evaluation would leak nix-fleet's inventory into the consumer — the
  legacy `flake.modules.nixos.builder-access` path exists only to fail eval
  with a named migration error.

## What the consumer declares

```nix
imports = [
  inputs.nix-fleet.flakeModules.registry        # fleet.* options
  inputs.nix-fleet.flakeModules.fleet-builders  # constructs the NixOS aspect
];

fleet.builders.home-forge = {
  host = "home-forge";                  # fleet.hosts key (variant 1)
  systems = [ "x86_64-linux" ];
  maxJobs = 2;
  speedFactor = 2;
  supportedFeatures = [ "big-parallel" "kvm" "nixos-test" ];
  # sshKeyPath = "/root/.ssh/nix-remote";  credential REFERENCE (path),
  #                                         not a credential; null = agent/
  #                                         default IdentityFile config
};

fleet.builders.nixbuild = {
  uri = "ssh-ng://eu.nixbuild.net";     # variant 2: full store URI
  systems = [ "aarch64-linux" ];
  maxJobs = 4;
  publicHostKey = "ssh-ed25519 AAAA..."; # from nixbuild's docs
};

fleet.builderSets.ci = [ "home-forge" "nixbuild" ];  # the scheduling policy
```

Fail-closed validation (named errors): a set naming an unknown builder, a
builder referencing an unknown host, a builder with both/neither variant
set — all fail `nix flake check` with the specific problem.

## The two seams

One aspect, two independently-consumable halves:

1. **Trust** — known-hosts + ssh client Host blocks for registry hosts.
   Always on, additive, no scheduling implied. See hosts.md.
2. **Scheduling** — on a host composition:

   ```nix
   imports = [ inputs.nix-fleet.modules.nixos.fleet-builders ];
   services.fleet-builders.activeSet = "ci";   # null = trust only
   services.fleet-builders.sshUser = "root";   # dial-as user
   ```

   `activeSet` selects the builder set → `nix.buildMachines` (comma-joined
   systems, base64 host-key bodies, per-builder features) → nixpkgs renders
   `/etc/nix/machines` and `nix.settings.builders = "@/etc/nix/machines"`,
   with `nix.distributedBuilds` enabled only when a set is selected.

Selecting an activeSet never _reaches_ the builders: the connecting host
still needs its own SSH credentials (per-host sops business) and the builders
must authorize its key. nix-fleet carries no credential material.

## What stays consumer-side

- Substituter policy (`nix.settings` substituters/trusted keys, including
  `ssh-ng://` substituter entries) — endpoint catalog, not builder
  participation. The registry must not conflate the two uses of a host.
- SSH server config, peer-alias policy beyond what trust renders, GC,
  remote-builder _authorization_ (whose keys may log in).
- Non-fleet personal hosts (dotfiles' arch etc.) — the registry is partial
  by design.

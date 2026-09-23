# CI contract — builder artifacts and the build-push-cache workflow

How GitHub Actions builds against fleet builders using the same registry the
hosts use. No builder coordinates live in workflow files or repo variables.

## Model

```
fleet inventory (nix-fleet, canonical)   GHA runner
├─ fleet.builderSets.ci ──────────────►  .#packages.ci
│    rendered at consumer eval            ├─ machines       ─► builders = @/tmp/nix-builders
│                                         ├─ known_hosts    ─► /etc/ssh/ssh_known_hosts
│                                         └─ ssh_config     ─► ~/.ssh/config
└─ join tailnet (fleet-host builders) ─►  MagicDNS resolves hostnames

nix-fast-build: evaluates locally, fans out across inventory builders AND the
runner's own store (default max-jobs — the runner is just another builder;
its aarch64 runners cover arm builds fleet hosts can't). Cache publication:
builders push via their own niks3 post-build-hook; the coordinator pushes
fetched-back paths via niks3 push; server-side dedup makes overlap a no-op.
```

Degradation is native nix: an unreachable builder drops out of scheduling and
work lands on remaining builders plus the runner's local store. The inventory
and the workflow carry no failover logic.

## The artifacts output

Any flake importing `flakeModules.fleet` gets, per declared set (canonical
_and_ consumer-local — a set is not free: declaring it publishes a bundle):

```nix
# imports = [ inputs.nix-fleet.flakeModules.fleet ];
packages.ci                    # the canonical "ci" set (declared in nix-fleet)
packages.<set>                 # every other declared set (consumer-local too)
```

Each bundle is a directory:

| File          | Content                                                                    | Installed to                            |
| ------------- | -------------------------------------------------------------------------- | --------------------------------------- |
| `machines`    | nix machines-file lines (7 fields, comma-joined systems, `-` placeholders) | `/tmp/nix-builders` → `builders = @...` |
| `known_hosts` | ssh_known_hosts lines for the set's builders                               | `/etc/ssh/ssh_known_hosts`              |
| `ssh_config`  | Host blocks with long-build tuning                                         | appended to `~/.ssh/config`             |

Rendered from the merged fleet inventory (canonical + consumer additions) at
consumer eval time — the workflow never stores addresses, keys, or sets.

## The workflow

`build-push-cache` is a **reusable workflow** — no copying. A consumer adds
a stub:

```yaml
jobs:
  build-push-cache:
    uses: Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@v1
    with:
      cache_url: https://cache.example.com
      targets: .#nixosConfigurations.myhost.config.system.build.toplevel
      # optional:
      # builder_attr: ci           (any fleet.builderSets entry; ci default)
      # gha_systems: x86_64-linux  (space-separated; add aarch64-linux for arm)
    secrets:
      BUILDER_SSH_KEY: ${{ secrets.FLEET_BUILDER_SSH_KEY }}
```

| Input             | Meaning                                                                            |
| ----------------- | ---------------------------------------------------------------------------------- |
| `cache_url`       | niks3 server base URL; substituter/keys/audience come from its `/api/cache-config` |
| `targets`         | flake attrspecs for nix-fast-build                                                 |
| `builder_attr`    | which `packages.<attr>` bundle to schedule against (canonical `ci` by default)     |
| `gha_systems`     | systems the GHA-local build job matrixes over (arm via `aarch64-linux`)            |
| `BUILDER_SSH_KEY` | secret: the coordinator's builder SSH key                                          |

**Versioning:** pin to a tag (`@v1`), never `@main`. nix-fleet cuts tagged
releases; renovate proposes tag bumps with changelogs and a PR acceptance
gate, so consumers opt into changes deliberately.

Two jobs:

- **fleet-build** — coordinator: joins tailnet (optional), installs the
  registry bundle, fetches cache config, starts the OIDC token refresher
  (GitHub OIDC → `$XDG_CONFIG_HOME/niks3/auth-token`, re-read by niks3;
  nix-fast-build itself never sees OIDC), then `nix-fast-build
--skip-cached` with `builders = @/tmp/nix-builders`.
- **gha-build** — runner-local builds streaming through niks3-action's
  post-build-hook with GitHub OIDC. Same dedup server.

### Tailscale join (fleet-host builders)

MagicDNS names in the machines file resolve only inside the tailnet. Joining
is cheap enough to be normal CI bootstrap:

1. Repo **variable**: `FLEET_CI_ON_TAILNET=true`
2. Repo **secrets**: `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`
   (Tailscale OAuth client with tag `tag:ci` authorized in your tailnet ACL)

The join step skips itself when the variable is unset — external-only
builder sets (nixbuild-only CI) need no Tailscale at all.

## First-live-run caveats (honest state)

- The `nix build .#packages.x86_64-linux.ci` step assumes x86_64
  coordinator runners; arm coordinators need the system swapped.
- Runner user must be a trusted user for the builders-use-substitutes path
  to substitute optimally; correctness doesn't depend on it.
- `SSH_KEY_SECRET` naming and builder-side authorization of the coordinator
  key are consumer policy; the template shapes the mechanism, not the trust.

## What the consumer must provide (checklist)

1. `flakeModules.fleet` import (hosts.md, builders.md) — canonical inventory
   - shared sets arrive with it; add only consumer-local sets/builders
2. A `fleet.builderSets.ci` naming the builders CI may use (canonical `ci`
   exists; extend or add a local set)
3. `{{CACHE_URL}}`-shaped niks3 endpoint with OIDC provider bound
   (`services.niks3-cache.oidc.providers`, see README)
4. Coordinator SSH key authorized on fleet builders (builder-side policy)
5. Optionally: the two Tailscale secrets + variable

## Intent (why CI reads the inventory)

The workflow holds no builder coordinates so that a builder change (new set,
retired host, key rotation) is a one-repo change in nix-fleet's inventory,
picked up by every consuming workflow on the next flake bump. Repo variables
like the old `NIX_BUILDERS` were a hand-copied second registry — the exact
duplication class this contract exists to eliminate. Consumers never
reconcile builder facts by hand again.

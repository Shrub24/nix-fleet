# CI contract — builder artifacts and the build-push-cache workflow

How GitHub Actions builds against fleet builders using the same registry the
hosts use. No builder coordinates live in workflow files or repo variables.

## Model

```
fleet registry (consumer flake)          GHA runner
├─ fleet.builderSets.ci ──────────────►  .#packages.ci-builders
│    rendered by lib.registry             ├─ machines       ─► builders = @/tmp/nix-builders
│                                         ├─ known_hosts    ─► /etc/ssh/ssh_known_hosts
│                                         └─ ssh_config     ─► ~/.ssh/config
└─ join tailnet (fleet-host builders) ─►  MagicDNS resolves hostnames

nix-fast-build: evaluates locally, fans out across registry builders AND the
runner's own store (default max-jobs — the runner is just another builder;
its aarch64 runners cover arm builds fleet hosts can't). Cache publication:
builders push via their own niks3 post-build-hook; the coordinator pushes
fetched-back paths via niks3 push; server-side dedup makes overlap a no-op.
```

Degradation is native nix: an unreachable builder drops out of scheduling and
work lands on remaining builders plus the runner's local store. The registry
and the workflow carry no failover logic.

## The artifacts output

Any consumer flake that declares `fleet.builderSets` gets, per set:

```nix
# imports = [ inputs.nix-fleet.flakeModules.registry ];  (+ inventory)
packages.ci-builders            # the "ci" set, when declared
packages.ci-builders-<set>      # every declared set
```

Each bundle is a directory:

| File          | Content                                                                    | Installed to                            |
| ------------- | -------------------------------------------------------------------------- | --------------------------------------- |
| `machines`    | nix machines-file lines (7 fields, comma-joined systems, `-` placeholders) | `/tmp/nix-builders` → `builders = @...` |
| `known_hosts` | ssh_known_hosts lines for the set's builders                               | `/etc/ssh/ssh_known_hosts`              |
| `ssh_config`  | Host blocks with long-build tuning                                         | appended to `~/.ssh/config`             |

Rendered from the consumer's own registry at consumer eval time — the
workflow never stores addresses, keys, or sets.

## The workflow

`.github/templates/build-push-cache.yml` is the consumer contract. Copy it
into your repo's `.github/workflows/` and fill the placeholders:

| Placeholder              | Meaning                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------- |
| `{{BUILDER_SET_SUFFIX}}` | `-ci` for the `ci` set (produces `.#ci-builders-ci`); empty for `packages.ci-builders` |
| `{{CACHE_URL}}`          | niks3 server base URL; substituter/keys/audience come from its `/api/cache-config`     |
| `{{TARGETS}}`            | default flake attrspecs for nix-fast-build                                             |
| `{{SSH_KEY_SECRET}}`     | repo secret holding the coordinator's builder SSH key                                  |

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

- The `nix build .#packages.x86_64-linux.ci-builders` step assumes x86_64
  coordinator runners; arm coordinators need the system swapped.
- Runner user must be a trusted user for the builders-use-substitutes path
  to substitute optimally; correctness doesn't depend on it.
- `SSH_KEY_SECRET` naming and builder-side authorization of the coordinator
  key are consumer policy; the template shapes the mechanism, not the trust.

## What the consumer must provide (checklist)

1. `flakeModules.registry` import + `fleet.*` inventory (hosts.md, builders.md)
2. A `fleet.builderSets.ci` naming the builders CI may use
3. `{{CACHE_URL}}`-shaped niks3 endpoint with OIDC provider bound
   (`services.niks3-cache.oidc.providers`, see README)
4. Coordinator SSH key authorized on fleet builders (builder-side policy)
5. Optionally: the two Tailscale secrets + variable

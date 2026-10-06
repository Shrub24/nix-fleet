# CI contract — builder artifacts and the build-push-cache workflow

How GitHub Actions builds against fleet builders using the same registry the
hosts use. No builder coordinates live in workflow files or repo variables.

## Validation gates

On every push and pull request, `ci.yml` checks formatting, evaluates all declared
systems, then builds **all native x86_64 checks** with `nix flake check`. This
includes the fixture toplevel, Bifrost startup/plugin/module runtime checks and
telemetry delivery/ingress checks. Adding a native check adds a CI gate without
editing the workflow. ARM evaluation is covered; ARM builds require an ARM builder.
The separately dispatch-gated fleet build workflow is not needed for these gates.

## Model

```
fleet inventory (nix-fleet, canonical)   GHA runner
├─ fleet.buildProfiles.ci ────────────►  .#packages.ci
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

Any flake importing `flakeModules.fleet` gets, per declared profile (canonical
_and_ consumer-local — a profile is not free: declaring it publishes a bundle):

```nix
# imports = [ inputs.nix-fleet.flakeModules.fleet ];
packages.ci                    # the canonical "ci" profile (declared in nix-fleet)
packages.<profile>            # every other declared profile (consumer-local too)
```

Each bundle is a directory:

| File          | Content                                                                    | Installed to                            |
| ------------- | -------------------------------------------------------------------------- | --------------------------------------- |
| `machines`    | nix machines-file lines (7 fields, comma-joined systems, `-` placeholders) | `/tmp/nix-builders` → `builders = @...` |
| `known_hosts` | ssh_known_hosts lines for the profile's builders                           | `/etc/ssh/ssh_known_hosts`              |
| `ssh_config`  | Host blocks with long-build tuning                                         | appended to `~/.ssh/config`             |

Rendered from the merged fleet inventory (canonical + consumer additions) at
consumer eval time — the workflow never stores addresses, keys, or profiles.

## The workflow

`build-push-cache` is a **reusable workflow** — no copying. A consumer adds
a stub:

```yaml
jobs:
  build-push-cache:
    uses: Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@v1
    with:
      cache_api_url: https://niks3.tailnet.example.com
      targets: .#nixosConfigurations.myhost.config.system.build.toplevel
      # optional:
      # builder_attr: ci           (any fleet.buildProfiles entry; ci default)
      # gha_systems: x86_64-linux  (space-separated; add aarch64-linux for arm)
      # tailnet: true              (join the tailnet; needs the OAuth secrets)
    secrets:
      BUILDER_SSH_KEY: ${{ secrets.FLEET_BUILDER_SSH_KEY }}
      # only when tailnet: true
      # TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      # TS_OAUTH_CLIENT_SECRET: ${{ secrets.TS_OAUTH_CLIENT_SECRET }}
```

The calling job must grant `permissions: { contents: read, id-token: write }`
— GitHub cannot elevate the token for a called workflow, and the call is
rejected at parse time (a startup_failure with zero jobs) if the caller
grants less than the workflow needs.

| Input                    | Meaning                                                                                                                                                                                                  |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cache_api_url`          | niks3 **API** base URL — serves `/api/cache-config`, requires auth/tailnet. Distinct from the public read domain (which the API returns as `substituter_url`); never point this input at the read domain |
| `targets`                | flake attrspecs for nix-fast-build                                                                                                                                                                       |
| `builder_attr`           | which `packages.<attr>` bundle to schedule against (canonical `ci` by default)                                                                                                                           |
| `gha_systems`            | systems the GHA-local build job matrixes over (arm via `aarch64-linux`)                                                                                                                                  |
| `tailnet`                | join the tailnet before building (boolean, default false). Explicit because a reusable workflow cannot read the caller's variables                                                                       |
| `BUILDER_SSH_KEY`        | secret: the coordinator's builder SSH key                                                                                                                                                                |
| `TS_OAUTH_CLIENT_ID`     | secret: Tailscale OAuth client id, required only when `tailnet` is true                                                                                                                                  |
| `TS_OAUTH_CLIENT_SECRET` | secret: Tailscale OAuth client secret, required only when `tailnet` is true                                                                                                                              |

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

### Tailscale join (both jobs)

MagicDNS names in the machines file resolve only inside the tailnet, and
the niks3 **API** host is tailnet-only — so both jobs join, not just
fleet-build: gha-build must reach `/api/cache-config` and stream uploads
to the API host. The step is `tailscale/github-action` with a Tailscale
OAuth client (the action exchanges the OAuth client for an ephemeral node
key; GitHub OIDC is not part of it).

A called workflow inherits neither the caller's secrets nor its variables,
so both are passed explicitly:

1. Caller **variable** `FLEET_CI_ON_TAILNET=true`, bound to the `tailnet`
   input.
2. Caller **secrets** `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`,
   forwarded in the call's `secrets:` block (Tailscale OAuth client with
   tag `tag:ci` authorized in your tailnet ACL).

Both join steps are gated on the `tailnet` input, which defaults to false —
external-only profiles with a public-reachable API (nixbuild-only CI) need
no Tailscale at all.

## First-live-run caveats (honest state)

- The `nix build .#packages.x86_64-linux.ci` step assumes x86_64
  coordinator runners; arm coordinators need the system swapped.
- Runner user must be a trusted user for the builders-use-substitutes path
  to substitute optimally; correctness doesn't depend on it.
- `SSH_KEY_SECRET` naming and builder-side authorization of the coordinator
  key are consumer policy; the template shapes the mechanism, not the trust.

## What the consumer must provide (checklist)

1. `flakeModules.fleet` import (hosts.md, builders.md) — canonical inventory
   - shared profiles arrive with it; add only consumer-local profiles/builders
2. A `fleet.buildProfiles.ci` naming the builders CI may use (canonical `ci`
   exists; extend or add a local profile)
3. `{{CACHE_URL}}`-shaped niks3 endpoint with OIDC provider bound
   (`services.niks3-cache.oidc.providers`, see README)
4. Coordinator SSH key authorized on fleet builders (builder-side policy)
5. Optionally: the two Tailscale secrets + variable

## Intent (why CI reads the inventory)

The workflow holds no builder coordinates so that a builder change (new profile,
retired host, key rotation) is a one-repo change in nix-fleet's inventory,
picked up by every consuming workflow on the next flake bump. Repo variables
like the old `NIX_BUILDERS` were a hand-copied second registry — the exact
duplication class this contract exists to eliminate. Consumers never
reconcile builder facts by hand again.

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
      # tailnet: true              (join the tailnet; needs the federated identity)
    secrets:
      BUILDER_SSH_KEY: ${{ secrets.FLEET_BUILDER_SSH_KEY }}
      # only when tailnet: true
      # TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      # TS_AUDIENCE: ${{ secrets.TS_AUDIENCE }}
```

The calling job must grant `permissions: { contents: read, id-token: write }`
— GitHub cannot elevate the token for a called workflow, and the call is
rejected at parse time (a startup_failure with zero jobs) if the caller
grants less than the workflow needs.

| Input                | Meaning                                                                                                                                                                                                  |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cache_api_url`      | niks3 **API** base URL — serves `/api/cache-config`, requires auth/tailnet. Distinct from the public read domain (which the API returns as `substituter_url`); never point this input at the read domain |
| `targets`            | flake attrspecs for nix-fast-build                                                                                                                                                                       |
| `builder_attr`       | which `packages.<attr>` bundle to schedule against (canonical `ci` by default)                                                                                                                           |
| `gha_systems`        | systems the GHA-local build job matrixes over (arm via `aarch64-linux`)                                                                                                                                  |
| `tailnet`            | join the tailnet before building (boolean, default false). Explicit because a reusable workflow cannot read the caller's variables                                                                       |
| `BUILDER_SSH_KEY`    | secret: the coordinator's builder SSH key                                                                                                                                                                |
| `TS_OAUTH_CLIENT_ID` | secret: Tailscale federated identity client id, required only when `tailnet` is true                                                                                                                     |
| `TS_AUDIENCE`        | secret: that federated identity's audience (`api.tailscale.com/<client id>`), required only when `tailnet` is true                                                                                       |

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
to the API host. The step is `tailscale/github-action` using **workload
identity federation**: the action exchanges GitHub's OIDC token for a
short-lived node key, so no long-lived credential exists in any repository,
and it consumes the same `id-token: write` grant niks3 already needs.

A called workflow inherits neither the caller's secrets nor its variables,
so both are passed explicitly:

1. Caller **variable** `FLEET_CI_ON_TAILNET=true`, bound to the `tailnet`
   input.
2. Caller **secrets** `TS_OAUTH_CLIENT_ID` (the federated identity's client
   id) and `TS_AUDIENCE` (its audience, which Tailscale generates as
   `api.tailscale.com/<client id>`), forwarded in the call's `secrets:`
   block.

The tailnet side is a **trust credential** on the admin console's Trust
credentials page: Credential → OpenID Connect, issuer _GitHub Actions_,
narrowed by a custom `sub` claim to the repository, with the writable
`auth_keys` scope and the `tag:ci` tag — which must also exist in the
policy's `tagOwners`. Tailscale documents the client id and audience as
**not secrets**; they are secrets here only because both are action inputs.
A federated identity belongs to no user, so it must tag its nodes:
`tags: tag:ci` is not optional.

Both join steps are gated on the `tailnet` input, which defaults to false —
external-only profiles with a public-reachable API (nixbuild-only CI) need
no Tailscale at all.

### Cache authorization (niks3 side)

Publishing is authorized by the cache, not by this workflow: the cache's
`oidc.providers` must trust the claims these jobs mint. niks3 ANDs every
bound claim — a bound claim missing from the token is itself a rejection,
reported as `required claim "…" not found` — and ORs the patterns inside one
claim. The claims worth binding:

- `repository` — the calling repository, name form (`OWNER/REPO`).
- `repository_owner_id` — the numeric owner id. Prefer this over
  `repository_owner`: GitHub's immutable-subject rollout rewrites `sub` to
  `repo:OWNER@OWNER_ID/REPO@REPO_ID:…` for repositories created on or after
  2026-07-15, and claim globs are anchored, so a `sub` pattern beginning with
  the owner _name_ diverges before its first wildcard and can never match such
  a token. nix-fleet is on the immutable form while its sibling repos are not,
  so a name-shaped `sub` rule silently excludes exactly one repository.
- `ref` — the branch or tag the run came from (`refs/heads/main`,
  `refs/pull/N/merge`, `refs/tags/v1`). Narrowing this is how a cache keeps
  unmerged branches out.
- `job_workflow_ref` — this entry point and its ref, e.g.
  `Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@refs/heads/main`,
  or `@refs/tags/v1` for a consumer pinned to a tag. Binding it is what makes
  the cache trust this workflow rather than any workflow in the repository —
  and since a missing bound claim is rejected, inlining these steps instead of
  calling the workflow is denied by design.

## First-live-run caveats (honest state)

- The `nix build .#packages.x86_64-linux.ci` step assumes x86_64
  coordinator runners; arm coordinators need the system swapped.
- Runner user must be a trusted user for the builders-use-substitutes path
  to substitute optimally; correctness doesn't depend on it.
- `SSH_KEY_SECRET` naming and builder-side authorization of the coordinator
  key are consumer policy; the workflow shapes the mechanism, not the trust.

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

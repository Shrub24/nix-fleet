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
runner's own store (default max-jobs). One configurable coordinator requests
both target architectures; Nix sends foreign-architecture builds to compatible
remote builders, without cross-compilation.
```

Degradation is native nix: an unreachable builder drops out of scheduling and
work lands on remaining builders plus the runner's local store. The inventory
and the workflow carry no failover logic.

## Cache publication

Each builder publishes through its native niks3 `post-build-hook`. GHA-local
builds use `Mic92/niks3-action`, which configures the runner's hook and GitHub
OIDC authentication. In hook mode, substituted or remotely returned paths are
not local builds and do not trigger an upload. There is no coordinator
path-collection or `nix-fast-build --niks3-server` publication step.
Any coordinator allowed to build locally must also have the runner hook installed.

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
    permissions:
      contents: read
      id-token: write
    uses: Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@v1
    with:
      # cache_api_url: https://niks3.tailnet.example.com   (optional; the fleet
      #                                                     contract supplies it)
      targets: .#nixosConfigurations.myhost.config.system.build.toplevel
      # optional:
      # builder_attr: ci           (any fleet.buildProfiles entry; empty = local-only)
      # runner_system: x86_64-linux (ARM coordinator default)
      # systems: x86_64-linux       (both target architectures default)
      # tailnet: false             (disable the default tailnet join)
      # ts_client_id: ${{ vars.TS_OAUTH_CLIENT_ID }}  (public override)
      # ts_audience: ${{ vars.TS_AUDIENCE }}          (public override)
    secrets:
      BUILDER_SSH_KEY: ${{ secrets.FLEET_BUILDER_SSH_KEY }}
```

The calling job must grant `permissions: { contents: read, id-token: write }`
— GitHub cannot elevate the token for a called workflow, and the call is
rejected at parse time (a startup_failure with zero jobs) if the caller
grants less than the workflow needs.

| Input             | Meaning                                                                                                                                                                                                                                                                                                                                                                            |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cache_api_url`   | niks3 **API** base URL — serves `/api/cache-config`, requires auth/tailnet. Optional: empty resolves `packages.<system>.cache-api-url`, i.e. the canonical `fleet.services."niks3-write"` tailnet origin, so the coordinate is not restated per repository. Distinct from the public read domain (which the API returns as `substituter_url`); never point this at the read domain |
| `targets`         | single flake selection for nix-fast-build; default `.#checks`, scoped to `systems`                                                                                                                                                                                                                                                                                                 |
| `builder_attr`    | which `packages.<attr>` bundle to schedule against (`ci` by default); explicitly empty means local-only, with no builder bundle or SSH key setup                                                                                                                                                                                                                                   |
| `tailnet`         | Join the tailnet before building (boolean, default true); set false for public-only deployments                                                                                                                                                                                                                                                                                    |
| `BUILDER_SSH_KEY` | secret: the coordinator's builder SSH key                                                                                                                                                                                                                                                                                                                                          |
| `ts_client_id`    | Public client ID override; empty resolves the fleet CI identity                                                                                                                                                                                                                                                                                                                    |
| `ts_audience`     | Public audience override; empty resolves the fleet default, or derives the audience from an overridden client ID                                                                                                                                                                                                                                                                   |

**Versioning:** pin to a tag (`@v1`), never `@main`. nix-fleet cuts tagged
releases; renovate proposes tag bumps with changelogs and a PR acceptance
gate, so consumers opt into changes deliberately.

Two jobs:

- **prepare** — resolves the public Tailscale identity once.
- **build** — one coordinator, selected by `runner_system` (default
  `aarch64-linux` on `ubuntu-24.04-arm`; `x86_64-linux` uses `ubuntu-latest`).
  It installs the selected builder profile when nonempty, configures
  `Mic92/niks3-action`, and runs `nix-fast-build` once with `--systems`.
  Empty `builder_attr` clears remote builders; otherwise Nix distributes work
  according to that profile. Local builds publish through the action; remote
  builds through builder hooks. No separate local-build job or custom refresher.

The workflow declares `contents: read` and `id-token: write` for direct dispatch.
Reusable callers must grant the same permissions. Direct dispatch reads the
repository's `FLEET_BUILDER_SSH_KEY`; reusable callers pass `BUILDER_SSH_KEY`.

### Architecture selection

These inputs answer separate questions:

| Input           | Default                      | Selects                                         |
| --------------- | ---------------------------- | ----------------------------------------------- |
| `runner_system` | `aarch64-linux`              | The GHA coordinator architecture                |
| `systems`       | `x86_64-linux aarch64-linux` | Target architectures evaluated under `.#checks` |
| `builder_attr`  | `ci`                         | Remote builder capacity; empty means local-only |

The coordinator architecture does not constrain remote execution. One ARM
coordinator can build ARM locally and delegate x86 work to compatible fleet
builders. The `ci` profile provides both architectures. Foreign-architecture
work cannot fall back to the coordinator if all compatible remote builders are
unavailable. Local-only consumers should select the same single system for
`runner_system` and `systems`.

For an x86-only consumer such as dotfiles:

```yaml
with:
  runner_system: x86_64-linux
  systems: x86_64-linux
  builder_attr: ci # use "" for local-only
```

`targets` is one flake selection, defaulting to `.#checks`, not a list of
positional targets. `systems` selects system branches under that workload; it
does not change a host-specific derivation's architecture.

A future wrapper can call this reusable workflow twice with disjoint workloads,
runner architectures and profiles. That orchestration is deferred. One
coordinator avoids repeated setup/evaluation and shares its build/store state;
most ARM and x86 derivations are nevertheless different and do not deduplicate.

### Tailscale join

The build job joins because both fleet builder names and the canonical niks3 API
require tailnet access, including in local-only mode. Set `tailnet: false` only
when the selected builders and cache API are publicly reachable.
The step is `tailscale/github-action` using **workload
identity federation**: the action exchanges GitHub's OIDC token for a
short-lived node key, so no long-lived credential exists in any repository,
and it consumes the same `id-token: write` grant niks3 already needs.

The `tailnet` input defaults to true. Before the build job joins, the
prepare job resolves public identity metadata from the checked-out consumer's
`packages.x86_64-linux.ci-tailscale`. It installs Nix before resolving that
artifact; bootstrap flake inputs must therefore be reachable without the
tailnet. The build job uses that resolved identity.

The identity comes from `fleet.ci.tailscale.clientId` and `audience`, not GitHub
secrets. An ordinary consumer assignment overrides the shared Client ID; its
audience follows automatically. A consumer may override the audience too.
Workflow inputs `ts_client_id` and `ts_audience` override those artifact values;
a client-only input derives `api.tailscale.com/<client id>`. A caller may bind
these inputs to repository Variables, but none are required for the shared
identity. `tailnet: false` skips metadata resolution and the join step.

The tailnet side is a **trust credential** on the admin console's Trust
credentials page: Credential → OpenID Connect, issuer _GitHub Actions_,
with claim rules selecting the allowed repositories and reusable workflow,
the writable `auth_keys` scope and the `tag:ci` tag. One credential serves all
three repositories. Tailscale documents the client id and audience as **not
secrets**; they are public fleet metadata.
A federated identity belongs to no user, so it must tag its nodes:
`tags: tag:ci` is not optional.

The join step is gated on the `tailnet` input, which defaults to true —
external-only profiles with a public-reachable API can explicitly select
`tailnet: false`.

### Cache authorization (niks3 side)

Publishing is authorized by the cache, not by this workflow: the cache's
`oidc.providers` must trust the claims these jobs mint. niks3 ANDs every
bound claim — a bound claim missing from the token is itself a rejection,
reported as `required claim "…" not found` — and ORs the patterns inside one
claim. The claims worth binding:

- `repository` — the calling repository. Documented as name form
  (`OWNER/REPO`), and the immutable-subject rollout is documented as
  `sub`-scoped; `repository` and `repository_id` are independent claims, so if
  a token ever carries the id form the fix is to bind `repository_id`. A
  mismatching claim is rejected by name along with the value niks3 saw, so the
  first real run settles which form applies instead of it having to be
  inferred from documentation.
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

- Prepare resolves `ci-tailscale` on x86_64; the build job resolves the builder
  bundle and cache URL through `packages.<runner_system>` on its native runner.
- Runner user must be a trusted user for the builders-use-substitutes path
  to substitute optimally; correctness doesn't depend on it.
- Builder-side authorization of the coordinator key is consumer policy;
  publishing `fleet.ci.sshPublicKey` grants no access on its own.

## CI repository provisioning

Normal validation needs no repository secrets, variables or environment. The
following provisions the dispatch-gated build/cache path.

### GitHub repository settings

Under **Settings → Secrets and variables → Actions**, configure each caller
repository (`nix-fleet`, `nix-homelab`, `nix-dotfiles`) that uses the workflow:

| Name                    | Location          | Value                                                             |
| ----------------------- | ----------------- | ----------------------------------------------------------------- |
| `FLEET_BUILDER_SSH_KEY` | Repository secret | Complete private coordinator SSH key, including its header/footer |

No repository variables are required. Tailnet joins default on and the shared
public Client ID/Audience come from fleet. There is no `TS_OAUTH_CLIENT_SECRET`,
cache upload token or required `FLEET_NIKS3_API_URL` variable. Remove the old
`TS_OAUTH_CLIENT_ID`/`TS_AUDIENCE` repository secrets and `FLEET_CI_ON_TAILNET`
variable after updating the caller and reusable workflow; they are no longer
read. For a different identity, pass `ts_client_id`/`ts_audience` as inputs,
optionally sourced from Variables rather than Secrets.

The caller must grant `contents: read` and `id-token: write` and forward only
`BUILDER_SSH_KEY`. Select the build targets and profile in the caller;
importing an updated `flakeModules.fleet` supplies the canonical `ci` bundle,
`cache-api-url` and `ci-tailscale` packages. Update both the flake pin and the
workflow reference together: an older flake lacks the new metadata artifact.
Override `cache_api_url` only for a different cache. An entirely substituted
build may need no SSH key, but remote cache misses require it.

### Coordinator key and builder trust

Generate a dedicated, non-interactive key locally, not on a GitHub runner:

```sh
ssh-keygen -t ed25519 -C 'fleet-ci coordinator' -f ~/.ssh/fleet-ci -N ''
gh secret set FLEET_BUILDER_SSH_KEY --repo Shrub24/nix-fleet < ~/.ssh/fleet-ci
```

Repeat the secret upload for each caller repository. One key can serve all
three; per-repository keys reduce the scope of a compromise but require
separate public-key authorization and rotation.

Authorize the public half on **every selected builder**, in its consumer
configuration. Select the `build-account` aspect and add the key to
`users.users.nixbuild.openssh.authorizedKeys.keys`; `endpoint.user` defaults to
`nixbuild`, independently of the host's human `managementUser`. The shared key
is declared as `fleet.ci.sshPublicKey`; close over the consumer's flake-level
fleet configuration when binding the NixOS account:

```nix
users.users.nixbuild.openssh.authorizedKeys.keys = [ config.fleet.ci.sshPublicKey ];
```

Here `config` is the flake-parts configuration, not the NixOS configuration.
Publication does not authorize any account by itself. A public key needs no
SOPS encryption. Verify SSH access and Nix remote-store permissions for that
account before dispatch.
The account must be able to build, not merely accept an SSH login.

For profiles containing the metered `nixbuild.net` builder, register the same
public key with the nixbuild.net account too. The canonical `ci` profile does
not include it; `arm-expensive` does. No nixbuild API token is required.

Keep a recoverable copy of the private key in your own secret storage. SOPS in
a consumer repo is an optional backup/distribution choice, not a prerequisite
for GitHub Actions: the runner reads the repository secret directly and needs
no SOPS decryption key. Never commit private material to nix-fleet. To revoke
access, remove the public key from the builders and nixbuild.net, then replace
the affected GitHub secrets.

### Tailscale authorization

Create one GitHub Actions OIDC trust credential in Tailscale with writable
`auth_keys` scope and permission to issue `tag:ci` nodes. Restrict its claims
to the intended repositories and the reusable workflow, for example
`job_workflow_ref = Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@*`;
use tighter workflow refs where practical. Avoid assuming all repositories
have the same name-shaped `sub` (see cache authorization above).

The shared Client ID and derived Audience are already recorded in fleet; no
GitHub-side copy is required. In tailnet policy, define `tag:ci` ownership and grant these nodes access to:

- TCP 22 on the selected fleet builders;
- the resolved `niks3-write` API endpoint (currently TCP 5751).

Check broader existing grants: adding a narrow grant does not remove an
existing broad permission. Tailscale admits the runner device; the SSH key
separately authenticates it to the builder account.

### Cache authorization

On the cache host, bind a GitHub Actions OIDC provider through
`services.niks3-cache.oidc.providers`, with write scope, the cache's configured
audience and the repository/owner/ref/workflow restrictions described above.
The workflow discovers the audience through `/api/cache-config` and obtains
short-lived tokens itself. No GitHub cache credential is provisioned.

The current homelab policy permits the three fleet repos on `main` through
this reusable workflow. A tag-pinned workflow ref is distinct from the run's
`ref`: publishing a run on a release tag needs an explicit cache-policy change
if only `refs/heads/main` is authorized.

### Repository settings or a `ci` environment?

Use **repository-level secrets/variables** for ordinary builds and cache
publication. An environment named `ci` adds no isolation merely by existing.
Use an environment when you want required reviewers, deployment branch/tag
restrictions or a distinct credential boundary before privileged jobs run.

The current reusable workflow declares no environment. GitHub does not support
`environment` on the caller's reusable-workflow job, and environment secrets
cannot be forwarded from that caller. To adopt an environment, the actual
jobs inside `build-push-cache.yml` must select it (normally through a new
optional input); an environment secret then takes precedence over a passed
secret with the same name. Do not place the current key only in an environment
and expect the existing workflow to find it.

Selecting an environment also changes the default OIDC subject context to
`environment:<name>`. Recheck subject-based Tailscale/cache rules before doing
so; explicit `ref` and `job_workflow_ref` claims remain separate controls.
See GitHub's [reusable-workflow environment warning](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)
and [OIDC subject reference](https://docs.github.com/en/actions/reference/security/oidc).

### Which public values belong in fleet?

Cache URL, builder coordinates and the shared CI identity are derived from
fleet rather than copied into repository settings. The identity is public CI
metadata (`fleet.ci`), not a `fleet.services` endpoint:

- `fleet.ci.tailscale.clientId`: shared Client ID, consumer-overridable;
- `fleet.ci.tailscale.audience`: defaults to the selected client's audience;
- `fleet.ci.sshPublicKey`: public coordinator key for explicit consumer authorization.

`packages.<system>.ci-tailscale` renders the first two fields as JSON. The
workflow defaults to joining the tailnet; a caller can still select
`tailnet: false`. The private SSH key never belongs in public fleet metadata.

### First dispatch

Run the workflow from an authorized branch after provisioning. Confirm both
build jobs join the tailnet, fetch `/api/cache-config`, authenticate to a
builder for an uncached build and publish to niks3. A fully cached run does
not prove builder SSH access. niks3 names a rejected or missing claim; use that
evidence rather than guessing the token's subject form. Normal validation CI
being green does not certify this dispatch-only path.

## Intent (why CI reads the inventory)

The workflow holds no builder coordinates so that a builder change (new profile,
retired host, key rotation) is a one-repo change in nix-fleet's inventory,
picked up by every consuming workflow on the next flake bump. Repo variables
like the old `NIX_BUILDERS` were a hand-copied second registry — the exact
duplication class this contract exists to eliminate. Consumers never
reconcile builder facts by hand again.

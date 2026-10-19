# Cache pins — operator runbook

Pins are named references that protect a closure from the cache's garbage
collection. This runbook turns them on for nix-fleet, and states what is verified
and what is not.

Contract: [ci.md](../contracts/ci.md) (verification and pinning),
[update-candidates.md](../contracts/update-candidates.md) (why availability never
gates a promotion). Values: `fleet.services."niks3-write"`.

## What a pin does, and what it does not

- `niks3 pins create <name> <store-path>` points a name at one store path. The
  name is writable later: pointing it at a new path is a **repoint**, which is how
  supersession works.
- A pin protects the **entire dependency tree** of the pinned path. One pin per
  system is therefore enough — nix-fleet pins `packages.<system>.cache-root`, whose
  closure covers every published package.
- Pinning does not delete anything. Repointing releases the old closure to the
  cache's own `niks3 gc`; when space is actually reclaimed is the cache owner's
  policy.
- `pins create` for a path the cache does not hold fails by name — a second
  assertion that the revision really was published.

The shape that follows: **one rolling name per system, moved only after a green
verification.** A revision that fails verification never moves it, so the pin is a
last-known-good pointer by construction.

## 1. Prerequisites

| Requirement                       | Check                                                                 |
| --------------------------------- | --------------------------------------------------------------------- |
| Server ≥ 1.7.0                    | `niks3 pins list --server-url "$API"` succeeds (pins landed in 1.7.0) |
| `write` scope for the CI identity | `pins create` succeeds; a missing scope is a `403`                    |
| `admin` for deletion              | only needed to prune; no CI path deletes a pin                        |

`$API` is `packages.<system>.cache-api-url` (`fleet.services."niks3-write".endpoints.api`,
tailnet only). Reads of substitution go to the public substituter instead — see §6.

## 2. Reserve the pin names

By default **any** token with `write` scope can create or repoint **any** pin. Bind
the names to the CI identity with the cache's OIDC rule (`oidc.providers.<name>.pins`),
so a name that means "the fleet's current main" cannot be moved by anything else.
Names: `nix-fleet-main-x86_64-linux`, `nix-fleet-main-aarch64-linux`
(`<CACHE_PIN_NAME>-<system>`).

The cache's claims (`nix-homelab`, `modules/cache/niks3-cache.nix`) trust the owner,
the repository and `refs/heads/main`, with one rule and one pin namespace per listed
repository — not a particular workflow file. So a listed repository's workflow on
`main` may publish, and adding a publisher there needs no edit to the cache config;
adding a _repository_ does. A deployment that still binds `job_workflow_ref` refuses
`pin-cache` with `401`, which is a claim mismatch, not a credential problem.

Verify: a `write` token that is _not_ the CI identity gets `403` for that name.

## 3. Trust the pin workflow on the tailnet

`pin-cache.yml` writes to the private API, so it joins the tailnet. The Tailscale
credential matches `job_workflow_ref` against a single pattern — the claim rules are a
map of claim to one pattern, not a list — so the pattern covers the workflows that may
join rather than naming one file:

```
job_workflow_ref = Shrub24/nix-fleet/.github/workflows/*@refs/heads/main
```

Keep `subject` at the repository-and-branch form
(`repo:Shrub24/nix-fleet:ref:refs/heads/main`) so the wildcard cannot match another
repository, another ref, or a pull request; the containment is then the `tag:ci` ACL,
which is what decides what a joined node reaches. If a narrower pattern is required
later, the alternative is one federated identity per workflow, which costs a second
client id and a varied `ci-tailscale` artifact.

No repository variable carries the Tailscale client id or audience: the job resolves
`packages.<system>.ci-tailscale` from the fleet contract.

Verify: `pin-cache`'s join succeeds. A missing listing shows as
`token exchange failed with status 403` pointing at the credential; `verify-cache` is
unaffected, because it holds no credential. The credential's containment is the
`tag:ci` ACL, so widening the pattern is a decision about what a joined node reaches,
not only about which workflow runs.

## 4. Enable it

```
CACHE_PIN_NAME=auto                # repository variable: prefix derived from the repository
CACHE_PIN_NAME=nix-fleet-main      # or name the prefix outright
```

Empty (or unset) leaves pinning off; verification is unaffected. `auto` derives the
prefix as `<repository>-main`, dropping the owner, so a consumer sets nothing beyond
the variable's presence and gets `nix-homelab-main-<system>`. Names share one
server-side registry, so keep the prefix per-repository and reserve it narrowly in the
cache's `pins` rule (§2) rather than with a wildcard.

## 5. First run

`promote-candidate` dispatches `pin-cache` after a successful fast-forward. By hand it
is `gh workflow run pin-cache.yml -f pin_name=auto` (or an explicit prefix), which is
also how a revision whose publication completed late is re-pinned. One pin per system
is created.

Verify:

```sh
niks3 pins list --server-url "$API"                 # both names, one path each
niks3 pins list --json --server-url "$API"          # narinfo key + updated-at
```

A second run repoints rather than duplicating: the list length stays two, and the
`updated at` moves.

## 6. What a pin is for, and what it is not

A pin exists so that **substitution keeps working**: it protects the closure from
the cache's GC, and a machine that wants that closure asks the cache for it by store
path, exactly as it always does. Nothing has to read the pin.

So the upstream pattern of resolving a pin to a path over HTTP and realising it
without evaluation is _not_ part of this procedure. It also does not work on this
cache today — the public fronting serves `narinfo`/`nar` (measured: `200` for a
cached path) but not the `pins/` prefix (`404`, `text/html`, so not a bucket miss) —
and that is not a gap to close for us: it would only matter for a consumer that wants
deploy-without-evaluation, and such a consumer would read
`niks3 pins list --json` through the API instead.

Listing pins, which is what operating them needs, is an API call:

```sh
niks3 pins list --server-url "$API"            # names, paths, updated-at
niks3 pins list --names-only --server-url "$API"
```

## 7. Retention

- Rolling names keep the pin registry fixed: repointing frees the previous closure,
  and nothing accumulates.
- Versioned names (`nix-fleet-v1-<system>`, …) accumulate **deliberately** as
  rollback points. Pruning them is an operator action — `pins delete` needs `admin`,
  and no CI path performs it.
- Do not create per-revision names (`main-<sha>`); those are the only ones that would
  grow without bound.

## 8. Troubleshooting

| Symptom                                 | Cause                                                                                                   |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `403` on `pins create`                  | missing `write` scope, or the name is reserved to another identity (§2)                                 |
| `403` on the tailnet join               | `pin-cache.yml` missing from the tailnet credential's workflow list (§3)                                |
| no pin run after a promotion            | `CACHE_PIN_NAME` unset (§4)                                                                             |
| `pins create` fails naming a store path | the path is not in the cache: the build's publication did not complete (this is the check pins provide) |
| `pins list` empty after a promotion     | that dispatch failed (the promoter only warns), or it wrote to a different server than `$API`           |

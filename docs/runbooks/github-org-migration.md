# Moving the fleet's repositories to a GitHub organisation

Scope for transferring the repositories from the `Shrub24` user account to an
organisation. Written to be decided on before anything moves: the transfer is
mechanical, but two credentials are keyed to the owner and the merge queue collides
with the promotion model.

## What an organisation buys

| Gain                                                    | Worth it?                                                |
| ------------------------------------------------------- | -------------------------------------------------------- |
| Organisation variables granted to selected repositories | Yes — this removes most of the per-repository repetition |
| One App installation for all repositories               | Yes, and it is also unavoidable (below)                  |
| Organisation Actions policy, audit log, teams           | Yes — one place to state what workflows may run          |
| Merge queue                                             | Only after a separate change (see below)                 |
| One copy of the App key                                 | Only by weakening the branch gate                        |

It does **not** remove: per-repository rulesets, per-repository labels,
per-repository environments.

The App is not optional: a GitHub App owned by a user account can only be installed
on repositories that account owns, so an organisation needs its **own** App — new
App ID, new private key, new slug, new integration id. That is the largest single
cost of the move.

All of these repositories are public, so merge queue is available without a paid
plan; a private repository would need a paid organisation plan.

## What the move breaks

Two credentials bind the owner and stop matching the moment a repository moves:

1. **niks3 write and pin claims**, in `nix-homelab`'s cache provider:
   `repository_owner_id = [ "20262061" ]`, plus the `repository` and
   `job_workflow_ref` patterns per repository.
2. **The Tailscale federated identity**, whose `repository`, `repository_owner` and
   `job_workflow_ref` claims name the repositories and the workflow files.

Everything else is text: flake input urls, `flake.lock`, `uses:` pins, the App
integration id in each ruleset, and the documentation.

Two properties soften this:

- **Pin names survive.** Pins are namespaced by _repository_ name
  (`<repository>-main-<system>`), and the names do not change, so the registry and
  every existing pin stay valid.
- **The solution does not hardcode the owner.** The coordinator, validation and
  cache workflows resolve this repository through `job.workflow_repository`, so the
  runtime path follows the transfer with no change.

## The merge-queue collision

Promotion and a merge queue both want to move the default branch, and they do not
compose:

- Promotion fast-forwards the default branch to a prepared merge commit and posts
  `update-candidate`. With a ruleset requiring the merge queue, that push is refused
  unless the App bypasses the ruleset — which is what the queue exists to prevent.
- A queue builds `refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>`, whose `ref` claim
  the cache claims (`refs/heads/main`) reject, so queued CI could not publish.

Adopting the queue therefore means re-architecting promotion: the candidate becomes a
**queue entry**, the App labels or enqueues instead of pushing, the pin job follows
the queue's merge commit, and the cache claims widen to `gh-readonly-queue/*`. That is
a change to `promote-candidate.yml`, the role of the acceptance marker, and the claims
— a project of its own, not a side effect of the org move.

**Recommendation:** do the org move with promotion unchanged, then evaluate the queue
as its own change once a consumer has completed a promotion end to end.

## Decisions to take first

1. **Org name and plan.** Free suffices for public repositories.
2. **Key custody.** Environments stay repository-scoped, so there is no free lunch:
   - _Environment secret per repository_ (current): four copies, but the environment's
     branch policy is what keeps the key away from pull-request runs. **Recommended.**
   - _Organisation secret_: one copy, readable by any workflow in a granted
     repository, so the branch gate is lost. Take this only if organisation-level
     deployment restrictions can restore it.
3. **Wave order.** `nix-fleet` plus one consumer is enough to prove both claim paths
   before the rest follow.
4. **Merge queue now or later.** Later.

## Phases

| Phase | Work                                                                                                           | Owner    |
| ----- | -------------------------------------------------------------------------------------------------------------- | -------- |
| 0     | Create the org. Record the org's numeric id (`repository_owner_id`) and name.                                  | operator |
| 1     | Transfer repositories. GitHub redirects clones and API fetches, **but the claims do not redirect**.            | operator |
| 2     | Update the claims (niks3 in `nix-homelab`, Tailscale in its console) **before** anything runs on the new owner | operator |
| 3     | Register the org-owned App, install it for all repositories, record id/slug/key, re-pin each ruleset           | operator |
| 4     | Rewrite references: flake inputs and locks, `uses:` pins, documentation, templates                             | code     |
| 5     | Collapse configuration: org variables, labels, per-repository environment                                      | operator |
| 6     | Verify, then remove the legacy claims and the old App                                                          | both     |

### Phase 2 needs a dual-claim window

niks3 claims accept lists, so both owner ids can be valid at once:

```nix
repository_owner_id = [ "20262061" "<org-id>" ];
```

Tailscale's custom claim rules are a single pattern per claim per provider, so the
equivalent is a second federated identity, or a temporary wildcard on
`repository_owner`. Accept a short window in which both owners are allowed, then
remove the old one. Do not reverse the order: a repository that moves before its
claim exists joins the tailnet and is then refused by the cache, which reads as a
cache fault rather than a credential one.

## Code changes

- **nix-fleet:** the docs and the nvfetcher template carry `Shrub24/` (nine files);
  the workflows themselves are owner-agnostic. Nothing in `modules/` changes.
- **nix-homelab:** three lines of claims, two input urls, five workflow pins, one data
  file.
- **nix-dotfiles:** input urls and workflow pins, plus `flake.lock`.
- **agent-radar, memex, Pi-Bolt.nix:** workflow pins and, where present, input urls.
- Each consumer needs one `nix flake update` per fleet input after the rewrite.

Do not rely on the redirects to cover a missed reference: a stale input keeps
resolving, so the migration can look complete while a repository still follows the
old owner. Rewrite and then assert the absence of the old owner rather than waiting
for a failure.

## Verification, per repository

1. A build publishes to the cache (the write claim matches the new owner).
2. A pin run joins the tailnet and creates its pin (the identity matches).
3. The App posts `update-candidate` on a validated revision, and the ruleset — pinned
   to the new integration id — accepts it.
4. One promotion moves the default branch and dispatches the pin job.

## Judgement

Worth doing once three or more repositories take the update lifecycle, and for the
organisation variables and single App installation rather than for the secret. Do it
with promotion unchanged, keep the key in a repository environment, and treat the
merge queue as a separate project.

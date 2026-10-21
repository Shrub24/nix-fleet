# Update candidates

How a dependency-update proposal becomes a validated commit on `main`. One
lifecycle serves every source of proposals: the native producer
(`automation/package-updates`) and Renovate (`renovate/*`). A source pull request
only proposes changes; the pipeline prepares, validates and promotes the exact
commit it built.

Implementation: `.github/workflows/pipeline.yml` (the default-branch entry
point), `validate.yml` (the repository's validation, in one definition),
`candidate.yml` (reusable pipeline body), `build-push-cache.yml` (builds),
`verify-cache.yml` (post-merge cache verification and pinning),
`promote-candidate.yml` (promotion),
`accept.yml` (acceptance marker), `candidate-sweep.yml` (retention),
`package-updates-refresh.yml` (the producer), and
`.github/scripts/prepare-candidate.sh` and `promote-candidate.sh`.

## Lifecycle

1. **Source.** A same-repository pull request from `automation/*` or
   `renovate/*`. Its head is the proposal.
2. **Prepare** (`candidate.yml`, job `prepare`). The source is checked out. If
   `origin/main` is not an ancestor of it, `main` is merged in; a conflict fails
   preparation, which reports as an un-preparable candidate.
   `prepare-candidate.sh` then runs `write-flake` and `nix flake lock` (no
   update). A second run must change nothing (the fixed-point check). Any
   regeneration is one child commit, and it stages exactly the two files those
   writers own (`flake.nix` and `flake.lock`): anything else that moved during
   regeneration is refused rather than committed. The result is published with the workflow
   token as `refs/candidates/<pr>/<source>-<candidate>`; publishing a ref
   authorises nothing, because the token cannot post the required status.
3. **Evaluate** (job `evaluate`). `nix flake check --no-build --no-write-lock-file --all-systems` on the candidate.
4. **Build** (job `build`). `build-push-cache.yml` builds `.#checks` at the
   candidate revision on the fleet builders. Skipped when the source changes only
   `.github/workflows/**`.
5. **Status** (job `status`, always runs). Posts the `update-candidate` commit
   status on the candidate commit and creates or updates one pull request
   comment. Without a candidate the failure is reported on the source revision,
   where promotion ignores it. `success` requires an explicit success path: a
   skipped build, a missing result or an absent output is a failure.
6. **Promote** (`promote-candidate.yml`, a `status` event). Refusals (each exits
   nonzero, moves nothing): the latest `update-candidate` status on the commit
   was not posted by the automation App; it is not `success`; it succeeded more
   than seven days ago, because a required status check must have succeeded
   within that window and the push would otherwise be refused as an opaque rules
   violation; no candidate ref names the commit; the ref does not resolve to that
   commit; the commit does not descend from the source revision or from the
   current `main`; the pull request is closed, not into `main`, or no longer at
   the source; under a `label` policy, the label or its revision marker is
   missing. The push is `<candidate>:main` and is not forced: a `main` that moved
   since the validation rejects it, and the push that follows re-validates it.

The source pull request is marked merged by reachability: the candidate contains
the source head.

## Trust boundaries

The boundary is _which file defines the steps_, not the order of steps. A
`pull_request` event runs the version of the workflow file from the pull request,
and a local (`./`) reusable workflow is taken from the caller's commit, while any
step of any workflow in a repository can read that repository's secrets. So:

| Tier                | Steps                                                 | Credential present                                                                                                                                                         |
| ------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A: candidate code   | regeneration, evaluation, build, cache verification   | builder SSH key, cache write and `id-token`, plus the workflow token **read-only**: a job may not hold a write credential and run repository code                          |
| A′: ref publication | pushing `refs/candidates/...`                         | the workflow token with `contents: write`; it fetches the prepared commit as a bundle and runs no repository code, and it cannot post the status that authorises promotion |
| B: reporting        | posting the `update-candidate` status and the comment | App key; the job checks out nothing and runs no repository code                                                                                                            |
| C: promotion        | the fast-forward push to `main`                       | App key; consumes the candidate SHA as data from a `status` event                                                                                                          |

Three rules make that hold:

- Every privileged step lives in a workflow whose _definition_ is on the default
  branch. `pipeline.yml` runs from `workflow_run` (which runs the default
  branch's version), so a pull request cannot change it, and it decides the
  revision from the API — `workflow_run.head_sha`, `head_branch`,
  `head_repository.full_name`, then the open pull request at exactly that head —
  rather than from a notifier's claim. No artifact is consumed as an instruction.
- The App key is an **environment** secret of `automation`, restricted to the
  `main` deployment branch. Environment secrets cannot be selected from a
  pull-request job, so even a PR-authored workflow that names the environment
  cannot read it. This is why `promote-candidate.yml` has no
  `pull_request: labeled` trigger: that trigger would put the credential that can
  push `main` within reach of the revision it distrusts.
- The candidate ref is published with the workflow token, in its own job. It is
  not a credential with any authority over `main`, and publishing a ref
  authorises nothing.
- The commit crosses from the code-running job to the publishing job as data (a
  git bundle artifact), which is why publication needs no access to the source
  tree. A tampered bundle could point the ref at another commit, which is why the
  promoter verifies the ref against the event SHA and the candidate's ancestry
  from GitHub data rather than from the ref name alone.

## Human pull requests

The ruleset requires `update-candidate` for any change to `main`, and a required
status also gates a pull request merged by hand. A human pull request therefore
gets the same status, from the same job (`candidate.yml` in `mode: human`), which
prepares, builds and promotes nothing.

The status is not a relay of `ci.yml`'s conclusion: `ci.yml` can be rewritten by
the pull request it validates, so the pipeline runs the authoritative validation
itself, from its own definition, through `validate.yml` — the same workflow the
contributor-facing `ci.yml` calls. A pull request may weaken its own feedback; it
cannot weaken what certifies it. An automation revision keeps the cheaper path:
for it the candidate's own trusted stages are the authority, and formatting is
gated by the closure build (`treefmt` is one of the built checks).

The status does not promote: promotion accepts only commits with a candidate ref,
and a human head has none, so the promoter reports it as not a candidate and
exits successfully. A human pull request is merged by its reviewer.

## Triggers and concurrency

- `ci.yml` runs on pull requests (including the `labeled` activity) and on pushes
  to `main`. It holds no credential.
- `build-push-cache.yml` serialises only its `build` job (`queue: max`), so two
  candidates cannot compete for the same builders or re-warm the same cache, while
  preparation and cache verification stay independent. No workflow-level
  concurrency group is declared: a group shared between a workflow and one of its
  own jobs deadlocks the job, which then fails at startup with no runner.
- `pipeline.yml` runs when `ci.yml` completes, and resolves three cases:
  - an automation pull request → prepared, built and validated;
  - a human pull request → status only;
  - a push to `main` → every open automation pull request is re-validated,
    because a candidate carries `main` as it was when it was prepared and a
    candidate that does not descend from the current `main` can never be
    promoted.
- Applying `accept-update` is what a `label` policy promotes on, and it is
  recorded against a revision rather than a moment. Two default-branch-defined
  workflows read the same label event: `accept.yml` posts an `update-accepted`
  marker on the head that event concerns, and `ci.yml` re-runs the pipeline,
  which re-validates the candidate — preparation is a no-op and the build is a
  cache hit — and reposts the status the promoter consumes. The promoter requires
  the marker on the very revision it is about to promote, so a push after the
  label leaves the newer revision unaccepted even though the label is still on
  the pull request.
- `workflow_dispatch` on `pipeline.yml` re-validates a named pull request, for
  recovery when an event was missed.
- Candidate runs are grouped per pull request and cancel the superseded run.
  Promotion is serialised and never cancelled.
- `candidate-sweep` deletes candidate refs whose commit is older than 30 days.

## Invariants

- `main` moves only by a fast-forward to a commit with a successful
  `update-candidate` status posted by the automation App.
- The built commit is the promoted commit: builds take the candidate revision
  explicitly, never the pull request merge ref.
- The App credential exists only in a step that runs no repository code, and only
  through the `automation` environment.
- A lock refresh and the package pins it depends on land together, because they
  are one candidate.
- Preparation is a fixed point.

## Composable interfaces

Each piece is callable on its own. The `on:` triggers are the only part that
cannot be inherited — GitHub has no way to inherit an event block — so a consumer
owns one thin trigger file per event and nothing else. `pipeline.yml` is callable
too: its local `./` calls resolve from the caller's commit, which is this
repository at the pinned ref, so a consumer needs no copy of `candidate.yml` or
`validate.yml`. What a consumer supplies is data and grants: repository variables,
its `automation` environment, the permission union the called jobs declare, and
`secrets: inherit`.

| Workflow                      | Called with                                                                                     | Consumer supplies                                                                |
| ----------------------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `build-push-cache.yml`        | `targets`, `profile`, `runner_system`, `systems`, `revision`, `cache_api_url`, tailnet identity | `BUILDER_SSH_KEY` secret                                                         |
| `verify-cache.yml`            | `revision`, `targets`, `systems`, `runner_system`, `cache_url`                                  | nothing (no secret, no identity); a caller grants `contents: read`               |
| `pin-cache.yml`               | `revision`, `pin_name`, `targets`, `systems`, `cache_api_url`, `runner_system`                  | `CACHE_PIN_NAME`; a caller grants `contents: read` + `id-token: write` (tailnet) |
| `validate.yml`                | `revision`, `generated_files`                                                                   | nothing (no secret)                                                              |
| `candidate.yml`               | `source_sha`, `source_pr`, `mode`, `precheck`, `targets`, `systems`, `runner_system`, `profile` | environment `automation`                                                         |
| `pipeline.yml`                | `source_pr` (only when the caller's event is a dispatch)                                        | the variables and permission grant below                                         |
| `package-updates-refresh.yml` | —                                                                                               | environment `automation`, in the publishing job only                             |
| `promote-candidate.yml`       | — (call it from a thin `on: status` file)                                                       | environment `automation`                                                         |
| `candidate-sweep.yml`         | — (call it from a thin `on: schedule` file)                                                     | environment `automation`                                                         |

Build selection is typed workflow input, so a consumer sets its closure per
repository without editing a workflow — `pipeline.yml` passes `CANDIDATE_TARGETS`,
`CANDIDATE_SYSTEMS`, `CANDIDATE_RUNNER_SYSTEM` and `CANDIDATE_PROFILE` from
repository variables with fleet-compatible defaults.

Environment secrets are not caller-supplied: the environment must exist in the
consumer's repository, so `package-updates-refresh.yml` declares no secret and a
caller with `secrets: inherit` still works.

Error contract: `build-push-cache.yml` sets its `build` output only on success.
An absent output means the stage did not complete and must never be read as
success. `verify-cache.yml` has no success output for the same reason: a caller
must require the job to have succeeded. It is a diagnostic, though, so nothing
gates on it, and its absence is never read as a pass.

## Cache verification and pinning are post-merge

Cache availability does not gate a candidate. An unavailable cache would block
every dependency update while saying nothing about whether a revision is correct,
and a revision that built correctly stays correct whether or not its outputs are
being served at that moment. Promotion therefore rests on validation and the
build.

`verify-cache.yml` runs on every push to `main` and by hand, so each commit's cache
status is published rather than remembered. A promoted revision was built, so an
unserved root is a loss; a human push was not — routine CI never builds — so its
unserved roots are the derivations that commit changed, and the report names them
alongside the counts. It reads the **public**
substituter route only — substitution is public even though the write API is not —
so it needs no tailnet identity, no OIDC and no secret, and it holds no cache
client. It asks `nix path-info` about each realised closure root, naming every
missing path; uploads are atomic per closure, so a served root means its closure
was committed.

Pinning is a separate workflow with its own owner: `pin-cache.yml`, dispatched by
`promote-candidate.yml` after a successful fast-forward and dispatchable by hand to
re-pin a revision whose publication completed late. A pin name means "the fleet's
current main", so promotion — the event that lands a revision the pipeline built —
is what may move it; a push-triggered measurement's colour moves nothing. One pin
per system covers the whole tree: `packages.<system>.cache-root` is a linkFarm whose
closure is every published package. Artefacts are the subject, not `checks`: a
verdict changes whenever its inputs do, which is every commit. Pinning protects a closure from the cache's own
GC, so repointing releases the superseded closure to the cache's next `gc`, and
`pins create` failing by name is the presence assertion — a revision whose
publication was incomplete never claims the name, which stays on the previous
`last-known-good` revision. Only this workflow mints an OIDC token or joins the
tailnet, and pinning is off until `CACHE_PIN_NAME` is set.

`runner` is a GitHub runner label (for a job's `runs-on`) and `runner_system` a
Nix system (for `.#packages.<system>.*`); they are different values and are not
interchangeable.

## Policy

The policy is the repository variable `PROMOTION_POLICY`, read by
`promote-candidate.yml` (default `auto` when unset):

- `auto`: promote once the candidate is validated. nix-fleet uses this.
- `label`: also require the `accept-update` label on the source pull request,
  and the `update-accepted` marker on the source revision. The marker is what
  binds acceptance to a revision: it is posted on the head the label event
  concerns, and not on a revision pushed afterwards, so a new push lapses
  acceptance without anyone having to remove the label. Commit timestamps are
  deliberately not consulted — a commit's dates describe when it claims to have
  been written, not when it reached the pull request. Consumers that want
  operator intent use this.

It also sets reconciliation timing, because that follows from the same question —
when a proposal is allowed to become a commit:

- `auto`: a push to `main` re-validates every open automation source eagerly, so a
  proposal is ready the moment it is proposed. Few, short-lived proposals.
- `label`: reconciliation happens at acceptance instead. Labelling re-runs `ci`
  and therefore the pipeline, which re-prepares the candidate against the current
  `main`; only the operator's selection pays for it.

Which authors may open an automation source is the repository variable
`AUTOMATION_UPDATE_AUTHORS` (space-separated logins, added to the automation App's
bot and `renovate[bot]`). A branch prefix routes a proposal; it is not an
identity. A revision on `automation/*` from any other author is treated as a human
change and needs review. The allowlist is the branch's author: it does not
establish that every commit pushed to that branch afterwards came from the
producer, which is acceptable while one operator owns the repository and should be
revisited before it gains collaborators.

## Repository prerequisites

These are operator configuration, not in-tree. The runbook is
`openspec/changes/update-candidate-pipeline/runbook.md`.

- An environment named `automation`, with a deployment-branch rule allowing only
  `main` and no required reviewers, holding the secret
  `AUTOMATION_APP_PRIVATE_KEY`.
- An automation GitHub App with write access to contents, workflows, commit
  statuses and pull requests, and read access to metadata. The workflows scope is
  required because Renovate's Actions updates change `.github/workflows/`, and git
  refuses a token without it. Repository variables `AUTOMATION_APP_ID` and
  `AUTOMATION_APP_SLUG`; optionally `PROMOTION_POLICY`.
- A ruleset on `main` requiring the `update-candidate` status, pinned to the App,
  with no bypass actors and no pull-request rule. It also blocks deletion and
  non-fast-forward updates. Human pull requests need the status too (see above).
- Labels `accept-update`, `dependencies` and `automated`.
- The niks3 OIDC trust for candidate builds (nix-homelab; see `ci.md`).

## Consumer adoption

A consumer repository reuses this pipeline instead of copying it. The `on:` block
is the one thing GitHub cannot inherit, so the consumer owns a thin trigger per
event and no orchestration:

| Consumer file              | Content                                                                                       |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `.github/workflows/ci.yml` | copies nix-fleet's, or a thin file calling `validate.yml@<ref>` with `generated_files: check` |
| a thin `pipeline` trigger  | `on: workflow_run: {workflows: [ci], types: [completed]}` + `uses: .../pipeline.yml@<ref>`    |
| a thin `promote` trigger   | `on: status` + `uses: .../promote-candidate.yml@<ref>`                                        |
| a thin `sweep` trigger     | `on: schedule` + `uses: .../candidate-sweep.yml@<ref>`                                        |
| a thin `accept` trigger    | `on: pull_request_target: {types: [labeled, unlabeled]}` + `uses: .../accept.yml@<ref>`       |

`candidate.yml` calls `validate.yml` and `build-push-cache.yml`
by path, and a called workflow's local paths resolve from the caller's commit —
for these the caller is the pinned ref, so a consumer needs no copy of them. If
that ever resolves differently, the first run fails immediately with a
missing-workflow error rather than doing something surprising, and the fix is a
pin inside nix-fleet, not a second copy in the consumer.

The automation scripts come with the workflows. `candidate.yml` and
`promote-candidate.yml` check out `.github/scripts` from
`github:<job.workflow_repository>@<job.workflow_sha>` — the revision that defines
them — into `trusted/` and run the procedure from there, so a consumer needs no
copy and a candidate revision cannot supply the script that promotes it. The one
exception is `validate.yml`'s consistency guard, which takes the script from the
fleet's **default branch** on purpose: it exists to run the trusted procedure even
when the revision under test rewrote its own copy, and for a pull-request run the
workflow's own ref is that pull request's merge commit.

A called workflow cannot be granted more than its caller holds, and GitHub
validates _every_ job in the called workflow against the caller's grant when the
call starts — not only the jobs a given mode runs. So each thin trigger declares
the union of the permissions its jobs need — `pipeline.yml`'s
calls need `contents: write`, `statuses: write`, `pull-requests: write` and
`id-token: write`; `promote-candidate.yml` needs `contents: write`; `accept.yml`
needs `statuses: write` — and passes `secrets: inherit`, because `candidate.yml`
and `build-push-cache.yml` read repository secrets (builder SSH key, tailnet
identity).

The pinned ref must contain these files. `v1`, the tag consumers use for
`build-push-cache.yml`, predates them, so a later tag is required. nix-fleet is
public, so the call itself needs no access grant; a consumer that mirrors it
privately must allow access to its reusable workflows.

Configuration the consumer owns: the `automation` environment (secret
`AUTOMATION_APP_PRIVATE_KEY`, deployment branch restricted to its default branch);
variables `AUTOMATION_APP_ID`, `AUTOMATION_APP_SLUG`, `PROMOTION_POLICY` (use
`label`), `CANDIDATE_TARGETS`, `CANDIDATE_SYSTEMS`, `CANDIDATE_RUNNER_SYSTEM`,
`CANDIDATE_PROFILE` and optionally `AUTOMATION_UPDATE_AUTHORS`; the
`accept-update`, `dependencies` and `automated` labels; a ruleset requiring
`update-candidate`, pinned to its own App; and its own builder, cache and OIDC
trust (`ci.md`).

## Known limits

- Preparation merges `main` into the candidate, so the validated commit is a
  merge commit whenever the source is behind. `main` therefore carries merge
  commits from the pipeline, not a strictly linear history.
- `candidate-sweep.yml` expires a ref 30 days after the candidate commit was
  created, not after its last validation, so a long-lived consumer proposal can be
  swept while it is still wanted. Re-validating a swept candidate recreates it.
- A pull request from a fork is not validated: its revision is not this
  repository's code, so the pipeline reports nothing for it and the required
  status blocks it. Landing a fork contribution needs a branch in this
  repository (the maintainer's own push), or the change applied by hand.
- No retry. A build failure is reported once; a transient runner shutdown and a
  build error have the same job result, and repeating an uncached package build
  was judged worse than reporting it. The failed run's log is the diagnostic.
- A superseded candidate run can leave its candidate status pending.
- Renovate's tagged-input manager is not configured: nix-fleet has no tagged
  flake inputs yet.
- A candidate validated more than seven days before promotion is refused: a
  required status check must have succeeded within the preceding seven days, so
  the promoter refuses it by name instead of leaving the push to fail as an
  opaque rules violation. Re-validating the revision reposts the status.
- The author allowlist establishes the branch's author, not the provenance of
  every commit pushed to it afterwards (see Policy).
- `validate.yml`'s formatting job names the `x86_64-linux` system explicitly for
  the platform-independent checks. That follows the routine CI runner, not a
  measurement that other systems are equivalent.
- Two behaviours a consumer depends on are unverified here: what a
  `pull_request_target` label event carries for the marker (the code takes the
  head from the payload, but nothing has run it live), and whether repository
  `vars` read inside a called workflow resolve to the caller's repository. Both
  are on the live-gate list.
- The GitHub behaviour this design depends on is verified item by item in the
  change's tasks (group 1). Until those pass, the pipeline is unproven.

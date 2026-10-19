# Update candidates

## Promotion is a fast-forward push of the validated commit, with no bypass

**Id:** 459403bf-13ee-4f9b-b441-c0c545d3a3d3
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `docs/contracts/update-candidates.md`, `.github/workflows/promote-candidate.yml`, 2026-10-11

Promotion pushes the candidate commit to `main` with a plain, non-forced push.
A ruleset requires the `update-candidate` status and has no bypass actors and no
pull-request rule. Race safety comes from git: a moved `main` rejects a
fast-forward that is not based on it. The status context is not `candidate`
because a required name that a workflow or job also produces would require both
the check and the status to pass.

**Reason:** the candidate may be a child of the source head, so merging the
source pull request cannot land it, and a push onto a bot branch rewrites what
Renovate owns. GitHub enforces the evidence, so the promoter is not a trust
boundary for the status.

**Rejected alternatives:** a merge queue (not available to this personal
repository as far as verified); an integration pull request (a second lifecycle,
kept as the fallback if direct promotion fails); a bypass actor for the App
(removes the enforcement that makes a promoter bug harmless).

**Revisit when:** the App's status pinning cannot be verified, or GitHub adds a
merge mode that lands an arbitrary commit with its status.

## Merge `main` into the source, do not rebase it

**Id:** 361fb9f1-f058-40a1-92f7-8a58502098d6
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/candidate.yml` (job `prepare`), 2026-10-11

When `main` has moved, the candidate merges `origin/main` into the source head.
GitHub marks a pull request merged when its head becomes reachable from the base,
so the source head must stay an ancestor of the candidate.

**Rejected alternative:** rebasing the source onto `main`. That rewrites the
source commits, so the pull request would never be marked merged and would need
closing by hand. A conflict in a merge fails preparation, and the status reports it.

**Rejected alternative (revisited):** refuse a stale source instead, and leave the
refresh to whoever owns the branch — Renovate with `rebaseWhen:
behind-base-branch`, the producer by re-running. It reads as simpler and keeps
`main` linear, and it was briefly adopted. It was declined because the refresh has
no reliable trigger for the case that actually occurs: a producer re-run whose
diff is unchanged writes no commit, so its branch stays behind `main` and the
proposal deadlocks — promotable by neither path — until someone rewrites a branch
a bot owns. Merging in preparation makes the pipeline its own refresher, and the
merge commit it creates is what gets validated, so nothing validated is rewritten
afterwards.

**Revisit when:** the merged-by-reachability behaviour is verified to differ from
the documented rule on this repository.

## The promoter runs from `status` events, not from a pull-request branch

**Id:** a2ecda30-bb52-40af-9663-050aeabc322e
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/promote-candidate.yml`, 2026-10-11

The promoter reads the default branch's copy of its own workflow and receives the
candidate commit as data. A pull request cannot change what promotes.

The candidate status must be posted with the App token, because a status posted
by `GITHUB_TOKEN` would not trigger the promoter.

**Rejected alternatives:** a `workflow_run` trigger (also runs the default branch,
but needs a second workflow to carry the candidate); promotion from a job in the
candidate workflow (runs pull-request code next to the push credential).

## Cache verification is a separate job using a chroot store dry run

**Id:** f6602c25-d3c6-4eff-8364-3b7c230bff2d
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/verify-cache.yml`, 2026-10-11 (extracted from
`build-push-cache.yml`, where it was a job, so a caller can tell a build failure
from a cache-verification failure as two job results)

`nix build --dry-run --builders '' --store "local?root=<empty>"` reports every
derivation the cache does not serve as "will be built". A verdict in the build
job would race the niks3 upload daemon, which drains only in its post step, so
the check runs in its own job.

**Rejected alternative:** a dry run against the build job's own store. Everything
the build just produced is already local, so the check would pass for anything.

**Revisit when:** niks3-action exposes its uploads as complete before the post
step.

## The automation App token is minted after repository code has run

**Id:** 506e5b71-dfa3-4d56-9281-a5cd65e497b0
**Type:** constraint
**Status:** superseded
**Evidence:** confirmed
**Source:** `.github/workflows/candidate.yml`, 2026-10-11
**Superseded by:** 8f4c2a91-6d3e-4a7b-9c05-2f1b6e0d5a44

Ordering inside one job is not a boundary: a step can read a secret the job
declares at any point, and the file that declares it may be the pull request's own
copy.

A source may be a bot branch whose flake code runs during preparation. The App
token therefore appears only in steps after that code, and is never in the
environment of an evaluation, updater or build step.

**Rejected alternative:** minting the token at job start. Any flake code could
read it from the environment.

## The privilege boundary is which file defines the step, and where the key lives

**Id:** 8f4c2a91-6d3e-4a7b-9c05-2f1b6e0d5a44
**Type:** constraint
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/pipeline.yml`, `candidate.yml` (job `status`), `promote-candidate.yml`, 2026-10-11

Every step that holds the App key is reached only from a workflow defined on the
default branch, and the key itself is an environment secret of `automation`
restricted to `main`. Tier A (regeneration, evaluation, build) runs repository
code and holds builder and cache credentials only; tier B posts the status from a
job that runs no repository code; tier C consumes the candidate SHA as data from
a `status` event.

**Reason:** the ordering rule it replaces protected nothing. A pull request can
edit the workflow file that declares the secret, so a reviewable proposal could
read the key that posts its own validation status and pushes `main`.

**Rejected alternative:** a `pull_request: labeled` trigger on the promoter. That
is exactly the shape this forbids — a pull-request-defined file holding the push
credential. Acceptance works by re-validation instead: the label re-runs `ci`,
the pipeline re-validates the candidate cheaply and reposts the status, and the
promoter consumes that event.

## Retry is one more job, not a rerun

**Id:** 2ebaed74-883c-40ae-baaf-2c9611a5b697
**Type:** decision
**Status:** superseded
**Evidence:** inferred
**Source:** `.github/workflows/candidate.yml` (job `build-retry`), 2026-10-11
**Superseded by:** none — the job was removed; see the note below.

A failed build runs once more in a second job, and the status says whether the
retry succeeded. A runner shutdown and a build error have the same job result,
so the retry covers both, and the status description names the attempt rather
than the cause.

**Rejected alternative:** `gh run rerun` from the status job, which is part of the
run it would re-run.

**Why it went:** the only failure retry ever covered
was a hosted-runner shutdown in the native build step, and that path no longer
runs — routine CI is evaluation-only, and builds go through the fleet builders.
Repeating an uncached package build on a deterministic failure would spend more
than it saves, and the stage is now named in the status, so the failed log is
the diagnostic.

## Validation has one definition, called twice

**Id:** b7d5e0c4-2f81-4a63-9e07-5c8b1d3a7f62
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/validate.yml`, `ci.yml` (job `validate`), `pipeline.yml` (job `validate`), 2026-10-11

The repository's validation (formatting, all-systems evaluation, generated-file
consistency) is one reusable workflow. `ci.yml` calls it for contributor
feedback, and the trusted pipeline calls it for the required status of a human
change. The commands are fixed in that file and the revision is data.

**Reason:** a required status that relays the conclusion of the pull request's own
`ci` run certifies nothing — the pull request defines `ci.yml`, so it can remove
the validation and have the weakened version succeed. Calling the same definition
from a default-branch workflow fixes that without a second description of what
validation means. The consistency step runs the default branch's copy of
`prepare-candidate.sh`, taken by a second sparse checkout, for the same reason.

**Rejected alternative:** a separate hardened check list for the trusted path. Two
descriptions of validation drift, and the drift is invisible exactly where it
matters. Automation revisions are the one case that does not call it: their own
trusted stages are the authority, and formatting is gated by the closure build.

The three checks are three jobs rather than three steps. As steps, a formatting
failure skipped the evaluation and hid whether it also failed, so a contributor
discovered errors one round trip at a time; for a workflow-only revision the
formatting job is the only meaningful check anyway. `if: always()` steps were the
alternative, and they leave the reader interpreting a job graph to learn what ran.

## The write credential is in a job that runs no repository code

**Id:** 1c6a4b83-9d24-45f7-8a10-3e5d7b2f8c19
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/candidate.yml` (jobs `prepare`, `publish`), 2026-10-11

Preparation regenerates the candidate, which runs the source's code, so it holds
the workflow token read-only. Publishing the candidate ref needs `contents:
write`, so it is its own job: it checks out no source tree, fetches the prepared
commit as a git bundle artifact, verifies the bundle carries the commit the
preparation job recorded, and pushes the ref.

**Reason:** the first version gave the code-running job a write-capable token, on
the reasoning that the App key was the credential that mattered. A token that can
write to the repository is itself enough to publish a ref, and the source may be a
bot branch.

**Residual:** a bundle is an artifact, so a background process in preparation
could point it at another commit. That cannot promote anything: the promoter
verifies the ref against the event SHA and the candidate's ancestry from GitHub
data, and a foreign commit does not descend from the source head.

## An automation source is identified by its producer, not by its branch name

**Id:** 4d9f2e51-8c37-4b60-a5e2-7f1c9d0b6a38
**Type:** constraint
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/pipeline.yml` (job `resolve`), 2026-10-11

A pull request on `automation/*` or `renovate/*` is treated as an update proposal
only when its author is the automation App's bot, `renovate[bot]`, or a login in
the `AUTOMATION_UPDATE_AUTHORS` repository variable. Anything else on those
prefixes is treated as a human change: validated and reported, never promoted
automatically.

**Reason:** a validated candidate can be promoted without a human, so the routing
decision is an authorisation decision. A branch prefix is a name anyone with write
access can create.

## Reconciliation timing follows the promotion policy

**Id:** 9a02d7be-5c14-4e83-b0f6-2d8e1a4c7b05
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/pipeline.yml` (job `refresh-open`), 2026-10-11

Under `auto`, a push to `main` re-validates every open automation source eagerly.
Under `label`, it does not: labelling re-runs `ci` and therefore the pipeline,
which re-prepares the candidate against the current `main` at the moment the
operator selects it.

**Reason:** re-validation makes a proposal promotable the moment it is proposed,
which is what an automatic fleet wants, and it is wasted work for a consumer whose
proposals wait for an operator.

## A candidate whose changes touch only workflow files skips the closure build

**Id:** 395d11c4-e8ba-4882-a963-1c8f120d63e6
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/candidate.yml` (job `prepare`, step `Decide whether the closure changes`), 2026-10-11

Renovate's Actions updates otherwise cost a full closure build for no change in
the closure. The status is still posted, with a description that says why the
build was skipped.

**Revisit when:** a workflow file starts to feed a derivation, for example through
a generated input.

## The producer's updaters run with no credential, and publication applies a patch

**Id:** 767afc58-c7d7-4620-9055-2221823eac87
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/package-updates-refresh.yml` (jobs `update` and `publish`), 2026-10-11

`package-updates-refresh.yml` splits into an `update` job that runs the batch and
evaluates the refreshed tree with no App key, and a `publish` job that selects the
`automation` environment, applies the recorded git patch to a clean checkout of
the revision the refresh ran on, and opens the pull request.

**Reason:** `nix-update` executes the packages' update scripts, so that job is a
code-execution job. Minting the App token inside it would hand any updater an
identity that can create the PRs and push the branches the pipeline accepts as
automation sources. Ordering steps does not help: a job's steps share its
environment. The patch round-trip was verified against a real colocated checkout
— the publisher's tree is byte-identical to the updater's, `.jj` is never captured
because its contents are git-ignored, and a conflicting base is refused.

**Rejected alternative:** one job that mints the token after the updaters finish.
It protects nothing, and it keeps the credential in the same environment as the
code it distrusts.

The live path is not exercised yet: artifact download across the two jobs and the
moved-base refusal are verified by inspection and by the patch experiment, not on a
runner (tracked as the live gate).

**Revisit when:** the update path stops executing repository code, or the updaters
move to a sandbox that cannot reach a token even by accident.

## Acceptance names the revision it accepted

**Id:** b8945c0b-efc5-4bba-8181-4c41c10c25e7
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/accept.yml`, `.github/scripts/promote-candidate.sh`, 2026-10-19

Applying `accept-update` posts an `update-accepted` commit status on the head the
label event concerns: `accept.yml` is defined on the default branch, triggered by
`pull_request_target`, and takes `pull_request.head.sha` from its own payload. The
promoter requires that marker on the source revision it is about to promote, so a
push after the label leaves the newer revision unaccepted.

Evidence is structural (actionlint, the reference check) rather than live: the
label event's payload has not been observed on a real run.

**Reason:** the first version compared the label's timestamp with the source
commit's date. A commit's dates describe when it claims to have been written, not
when it reached the pull request, so a revision created before the label and pushed
after it would be promoted on someone else's acceptance.

**Rejected alternatives:** removing the label whenever the head changes, so
presence implies the current revision — every trigger reliable enough is either the
pull request's own workflow file, which is the file this boundary distrusts, or a
timestamp; a required check name for the marker — a required name must pass for
every change, including ones nobody is accepting.

**Revisit when:** the marker path is verified live, or acceptance moves to a
mechanism GitHub supplies directly (a deployment, an environment approval).

## The producer proposes only on an internally consistent result

**Id:** aec2198f-19fd-4e27-a684-b7340647e901
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/package-updates-refresh.yml` (job `update`, step
`Refresh flake inputs and registered packages`), 2026-10-19

Evidence: `tests/ci/producer_check.py` executes the decision step for the
consistent pairs, the contradictory pairs and the missing-artifact cases, and the
check was verified non-vacuous by reverting the decision to outcome-only.

The step proposes only for `complete` with exit 0 or `partial` with exit 1, and
only when `report.json` and `pr-body.md` both exist and are non-empty. Anything
else — a missing report, a report that contradicts the status, a missing body —
proposes nothing and fails the step.

**Reason:** the report is written before the pull-request body, so a run whose
second write failed would leave a truthful report about a run that then aborted.
Deciding from the report alone proposed a tree on evidence about a run that never
finished; deciding from the status alone would call an uncaught error's exit 1 a
proposable partial run. Requiring both to agree is the only reading that fails
closed in each direction.

**Rejected alternative:** a distinct exit code for an internal error. The runner
cannot distinguish a bug from an abort without a taxonomy that would rot; the
artifacts and the status agreeing is a smaller contract.

## Preparation stages exactly the files it owns

**Id:** 2ce67dc1-76e4-42b6-be18-d0deb73821ff
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/scripts/prepare-candidate.sh`, 2026-10-19

Evidence: the `write-flake` program compares against and writes only `flake.nix`,
and `nix flake lock` owns `flake.lock`.

Regeneration stages `flake.nix` and `flake.lock` and refuses any other path that
moved, in both commit and `--check` modes.

**Reason:** `git add --all` made the preparation commit a place where an unrelated
change could ride along unnoticed, in a commit that becomes a candidate nobody
reviewed as such. The rule is the package updaters' write set applied to
preparation: narrow, declared, and refused by name when exceeded.

## A consumer calls the pipeline rather than copying it

**Id:** 111e5096-4ca4-4626-855b-68d939ed8875
**Type:** decision
**Status:** active
**Evidence:** inferred
**Source:** `.github/workflows/pipeline.yml` (now `workflow_call`),
`docs/contracts/update-candidates.md`, 2026-10-19

Evidence: actionlint and the producer check pass; no consumer has called it.

A consumer repository owns a thin trigger file per event and calls the pinned ref.
It supplies data, not orchestration: repository variables, its `automation`
environment, the union of the permissions the called jobs need, and
`secrets: inherit`. `pipeline.yml`'s own `uses: ./...` lines resolve from the
caller's commit, which is that pinned ref, so no consumer keeps a copy of
`candidate.yml` or `validate.yml` either.

**Reason:** the first version had consumers copy `pipeline.yml`, on the argument
that its content is policy. The policy is already data — the producer allowlist,
the build selection and the promotion policy are all repository variables — and
what remained was routing that had been corrected repeatedly under review, in a
file whose local `uses:` a consumer would also have to repoint. Copying it to three
repositories multiplies exactly the path where the defects keep appearing.

**Residual:** the call's permission inheritance, `secrets: inherit` and whether
repository `vars` resolve to the caller inside a called workflow are unverified
until a consumer calls it (tracked as the live gate).

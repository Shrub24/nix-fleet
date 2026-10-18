# Tasks

Status convention: `[x]` means verified in this repository. `[ ]` means the code is
in place but the check needs a live GitHub run or operator configuration; the
steps are in `runbook.md` (§ named per task). A `[ ]` with "blocked" needs a
decision first.

## 0. Trust boundary: only the default branch may define a privileged step

- [x] 0.1 Privileged steps run only from a default-branch-defined workflow. The entry point is `pipeline.yml` (`workflow_run` on `ci`, plus `workflow_dispatch`), which resolves the revision and pull request from the API; the deleted `update-candidate.yml` was the pull-request-defined file that previously decided this.
- [x] 0.2 The App key is an environment secret of `automation` (restricted to `main`, no required reviewers), selected by the three jobs that read it: `candidate.yml`'s `status`, `promote-candidate.yml`'s `promote`, `candidate-sweep.yml`'s `sweep`, and `package-updates-refresh.yml`'s `refresh`.
- [x] 0.3 Repository code runs with no write credential: preparation, evaluation, build and cache verification hold builder SSH, cache write and `id-token`, and the workflow token read-only. Publishing the candidate ref is a separate job (`contents: write`) that runs no repository code and consumes the prepared commit as a git bundle.
- [ ] 0.4 Verify with a pull request that tries to read `AUTOMATION_APP_PRIVATE_KEY` and to select the `automation` environment: both fail, and no `update-candidate` status appears from it. Runbook §1.

- [x] 0.5 An automation source is identified by its producer: the pull request author must be the automation App's bot, `renovate[bot]`, or a login in `AUTOMATION_UPDATE_AUTHORS`; any other author on an automation prefix is treated as a human change.

## 1. Prerequisites and unverified GitHub behaviour (operator)

- [ ] 1.1 Confirm the Mend Renovate app is enabled and observe one real pull request under the new `renovate.json`. Runbook §4.
- [ ] 1.2 Create the automation GitHub App, store its key as the `automation` environment secret, and verify token minting and ref access with a dispatched `candidate-sweep`. Runbook §1.
- [ ] 1.3 Verify a ruleset-pinned required status (`integration_id`) on a scratch branch: an unstatused push is rejected, a status from another identity does not satisfy it, the App's status does. Runbook §5.
- [ ] 1.4 Verify how a human pull request's status appears to the required check, and that a `workflow_run`-triggered pipeline reports it. Runbook §5.
- [ ] 1.5 Record the OIDC claims of a candidate build and hand the niks3 trust change to the nix-homelab owner. Runbook §7.
- [ ] 1.6 Verify the acceptance marker's event: that a `pull_request_target` label event carries `pull_request.head.sha` as the code assumes, that the marker lands on that commit, and that repository `vars` resolve to the caller's repository inside a called workflow. Runbook §2 and §6.

## 2. Native update producer

- [x] 2.1 `packageUpdates.deferredInputs` (reason required, refused by name), `--input` and `--refresh-inputs`. Unit tests cover selection, overrides, stale deferral and refusals; a deferred input keeps its revision under real `nix flake update`.
- [x] 2.2 Lock refresh runs before the updaters, using the candidate-lock diff for old and new revisions and comparison links. An end-to-end `update-packages --input sops-nix bifrost` on an isolated jj workspace copy exited 0 (sops-nix did not move; bifrost unchanged at 2.3.0). The moved-input path in a live refresh is not yet exercised; it is covered by unit tests and by the real-`nix` deferral fixture.
- [x] 2.3 Report shape: moved inputs, `inputFailure`, failed packages named in the pull-request body, and packages still running when the lock did not change. Tests cover lock-only, package-only, both, and a failing updater alongside successes.
- [x] 2.4 `docs/contracts/package-updates.md` and `context/package-updates.md` updated for the producer run, deferral, report shape, and the superseded lock-ownership decision.
- [x] 2.5 `package-updates-refresh.yml` is callable (`workflow_call`) so a consumer supplies its own schedule and calls the run.
- [x] 2.6 Batch process contract: exit 0 / 1 / 2 with the same `outcome` in the report (`complete`, `partial`, `aborted`); a failed updater no longer becomes the batch's exit code, and an adoption that fails part-way aborts the batch. Covered in `tests/package-updates/` (75 tests).
- [x] 2.7 Producer split: the `update` job runs the batch and evaluates the refreshed tree with no credential, records the proposal as a patch plus the report files, and the `publish` job holds the App key, refuses a moved base and applies the patch as data. The patch round-trip was verified against a real colocated checkout: the publisher's tree is byte-identical to the updater's, `.jj` is never captured, and a conflicting base is refused.
- [ ] 2.8 Live verification of the split, including artifact download across jobs and the moved-base refusal on a real runner (in the live gate).
- [x] 2.9 The producer proposes only on an internally consistent result: `complete:0` or `partial:1`, with both report artifacts present and non-empty; a contradictory status/report pair, a missing report or a missing body proposes nothing. `tests/ci/producer_check.py` executes the decision step for nine cases including the contradictory pairs, and asserts the updater job holds no credential. Verified non-vacuous by reverting the decision to outcome-only, which the check refuses.

## 3. Candidate preparation and consistency check

- [x] 3.1 `.github/scripts/prepare-candidate.sh` (write-flake then `nix flake lock`). Fixtures, run against clones: complete tree (no change, check passes); declaration added without lock (check fails, commit adds one commit, only the new input's lock entry is added); generated flake out of date (check fails, commit regenerates).
- [x] 3.2 Fixed point: the commit fixture passes a second `--check`; `flake.lock` entries that existed before keep their revisions.
- [x] 3.3 Human-pull-request mode is `--check`, which fails without writing a commit when regeneration would change the tree. Wired into `ci.yml` for non-automation branches.
- [x] 3.4 `docs/contracts/flake-inputs.md` and `context/update-candidates.md`.
- [x] 3.5 Preparation stages exactly the files it owns (`flake.nix` from `write-flake`, `flake.lock` from `nix flake lock`) and refuses any other path that moved during regeneration, in both commit and `--check` modes.

## 4. Build by revision and cache verification

- [ ] 4.1 `revision` input on `build-push-cache.yml` (checkouts at the revision, default unchanged). Implemented; verify with a dispatch building an explicit SHA and matching the checked-out commit. Runbook §6.
- [x] 4.2 Cache verification is its own reusable workflow, `verify-cache.yml`, called as a separate job so a build failure and a cache-verification failure are distinguishable. The method is verified locally: the dry run in an empty chroot store reports an uncached derivation as "will be built", and reports the treefmt check's three derivations the cache does not serve. A live run is still owed for a fully cached and an uncached closure. Runbook §6.
- [x] 4.3 `checks.packages` aggregate over `config.packages` verbatim: evaluates to the thirteen published packages on both systems. `docs/contracts/ci.md` updated.
- [x] 4.4 Output error contract: `build-push-cache.yml` sets `build` only on success and exposes the resolved coordinates; `verify-cache.yml` has no success output; `candidate.yml` treats a skipped stage, a missing result or an absent output as failure.

## 5. Pipeline

- [x] 5.1 `pipeline.yml` (default-branch entry point) → `candidate.yml` (prepare, evaluate, build, verify, status, comment). Deleted the pull-request-defined `update-candidate.yml`.
- [x] 5.2 Credential placement by file origin, not step order: the App key exists only in default-branch-defined files, and only in jobs that run no repository code.
- [x] 5.3 Status context renamed to `update-candidate`, so the required name cannot collide with a check name. Superseded-run cancellation, push-to-`main` re-validation, and ref retention (`candidate-sweep`, 30 days) are in place.
- [x] 5.4a A human revision is validated by the pipeline itself through `validate.yml` (from the default branch, running the default branch's preparation script), not by relaying the conclusion of its own `ci` run; `ci.yml` calls the same definition for contributor feedback.
- [x] 5.4b Build selection is typed workflow input (`targets`, `systems`, `runner_system`, `builder_attr`), defaulted from repository variables, and the Nix system is exported separately from the GitHub runner label.
- [x] 5.4 Closure build skipped for workflow-only changes; the status is still posted. Container-image-tag skip not implemented (no image pin convention exists; see runbook §8).
- [x] 5.5 Retry deleted. There is no `build-retry` job: the stage that failed is named in the status instead, and the failed run's log is the diagnostic.
- [x] 5.7 Validation diagnostics are three jobs in `validate.yml` (format, evaluation, generated-file consistency) instead of sequential steps, so a formatting failure no longer hides the evaluation result and each failure names itself.
- [ ] 5.6 Verify on a live run: a no-op pull request, a child-commit pull request, two pushes to one pull request, and a simulated `main` advance re-validating open sources. Runbook §6.

## 6. Promotion and ruleset

- [ ] 6.1 `promote-candidate.yml` and `.github/scripts/promote-candidate.sh`: refusals for a non-candidate, a status not from the App, a ref that does not resolve to the candidate, a candidate that does not descend from the source or from `main`, a stale or closed pull request, and a moved `main`; fast-forward push otherwise. Verify each refusal and one promotion. Runbook §6.
- [ ] 6.2 Ruleset on `main` (required `update-candidate` pinned to the App, no bypass, no pull-request rule), enabled after 6.1 and 1.3. Verify the source pull request is marked merged after a promoted native pull request. Runbook §5.
- [x] 6.5 Acceptance is bound to a revision, not a moment: `accept.yml` (a `pull_request_target` label event, callable by consumers) posts `update-accepted` on the event payload's head, and `promote-candidate.sh` requires that marker on the source revision it is about to promote. The timestamp comparison is gone, because a commit's dates describe when it claims to have been written rather than when it reached the pull request. Also added: the promoter refuses a candidate status older than the seven-day window a required status check must have succeeded within.
- [ ] 6.3 `label` policy read from the repository variable `PROMOTION_POLICY`; verify with a labelled pull request (the label posts the marker and re-runs `ci`, so the candidate is re-validated rather than the status renewed), a head change that lapses acceptance, and a labelled pull request whose marker was posted before the head moved. Runbook §2.
- [x] 6.4 `docs/contracts/update-candidates.md` and `docs/contracts/ci.md` updated for the topology, the context name, the environment and the composable interfaces; the live-verification results are added after 6.1–6.2.

## 7. Producer and Renovate convergence

- [ ] 7.1 `package-updates-refresh.yml` runs the producer (`--refresh-inputs`) and opens the pull request with the App token. Verify by a dispatch that the pull request's checks start without approval. Runbook §6.
- [ ] 7.2 `renovate.json`: nix manager, `lockFileMaintenance` and per-input nix rules removed; `github-actions` kept; automerge off. Verify by the next Renovate run opening no lock pull request. Runbook §4.
- [ ] 7.3 Blocked on a decision: no flake input is tagged. Choose the first tagged input (candidates in runbook §8), then add the annotated regex manager and verify one Renovate pull request through to promotion.
- [ ] 7.4 One native pull request end to end under `auto`: produced, prepared, built, cache-verified, promoted; `main` is at the candidate and its closure is served by the cache. Runbook §6.

## Composable interfaces

- [x] C.1 `build-push-cache.yml` (build), `verify-cache.yml` (verification), `candidate.yml` (the pipeline body) and `package-updates-refresh.yml` (the producer) are each callable on their own, and their inputs, secrets and error contracts are documented in `docs/contracts/update-candidates.md`.
- [x] C.2 Consumer interface: `pipeline.yml`, `promote-candidate.yml`, `candidate-sweep.yml` and `accept.yml` are all callable, so a consumer owns a thin trigger per event and no orchestration; `docs/contracts/update-candidates.md` documents those files, the ref to pin, the permission union and `secrets: inherit` each trigger needs, and the variables and environment it configures. A called workflow's local `./` paths resolve from the caller's commit, which is the pinned ref, so no consumer needs a copy of `candidate.yml` or `validate.yml`.
- [ ] C.3 Consumer adoption itself, in the consumer's repository: its thin files, its `automation` environment, its repository variables, the `accept-update` label and its ruleset. A separate change.
- [ ] C.4 Cut a tag containing the pipeline files. `v1`, the line consumers use for `build-push-cache.yml`, predates them, so a consumer cannot pin the candidate lifecycle until the next tag exists.

## Follow-ups

- Review the unverified GitHub behaviour in `design.md` and the runbook before relying on the pipeline.
- Candidate builds are not yet scoped by a deployment environment beyond the App key's environment; the builder and cache trust is nix-homelab's niks3 policy (task 1.5).
- Archive this change once 7.4 passes.

# Runbook: enable the update-candidate pipeline

This runbook covers the operator steps that the change's tasks mark as needing
GitHub configuration or a live run (tasks 1.1–1.5, 6.1–6.3, 7.1–7.4). The
repository code is complete; nothing here needs a code change unless a step
fails. Design: `design.md`. Contract: `docs/contracts/update-candidates.md`.

## Ordering constraint

**Do not enable the ruleset (step 5) until the boundary verification in step 1 and
the scratch-ruleset test in step 5 pass.** Promotion itself checks the App's
status, the pull request and fast-forward, so until the ruleset exists the
enforcement is the promoter's rather than GitHub's.

The credential boundary is already in the code: no workflow whose definition can
come from a pull request holds the App key, and no job that runs repository code
holds a write credential. Step 1 verifies that rather than building it.

Nothing is blocked in the meantime: with no App, no status is posted and no
candidate ref is published, and the pipeline's jobs report as failures on their
own pull requests — visible, and inert, because the ruleset is not active.

## 1. Create the automation GitHub App (task 1.2)

Settings → Developer settings → GitHub Apps → New GitHub App, owned by
`Shrub24`.

| Permission (repository) | Access         | Why                                                                                    |
| ----------------------- | -------------- | -------------------------------------------------------------------------------------- |
| Contents                | Read and write | push `refs/candidates/*`, fast-forward `main`, sweep refs, refresh branch              |
| Workflows               | Read and write | Renovate's Actions updates change `.github/workflows/`; git refuses the push otherwise |
| Commit statuses         | Read and write | post `update-candidate`, the required status for both paths                            |
| Pull requests           | Read and write | create the refresh PR, update the candidate comment, read PR state                     |
| Metadata                | Read           | mandatory                                                                              |

Subscribe to no events. **Registering the App and installing it are two steps**:
setting the ID, slug and key up as above does nothing until the App is installed on
this repository. Until then `actions/create-github-app-token` authenticates as the
App, asks whether that App is installed on the repository, and gets `404 Not Found`
(`Get a repository installation for the authenticated app`) — the key and ID are
fine, the installation is what is missing. Install it on **only**
`Shrub24/nix-fleet` and grant the permissions listed above.

Then:

1. Generate a private key (PEM). Store it as an **environment secret**
   `AUTOMATION_APP_PRIVATE_KEY` in an environment named `automation`,
   restricted to the `main` deployment branch (task 0.2). A repository
   secret is readable by any workflow of this repository, including one
   that a pull request defines; an environment secret is not selectable
   from a pull-request job.
2. Store the App ID as the repository **variable** `AUTOMATION_APP_ID`.
3. Store the App slug (the URL name, for example `nix-fleet-automation`) as the
   repository **variable** `AUTOMATION_APP_SLUG`. The promoter checks that the
   status creator is `<slug>[bot]`.

Verification (task 1.2): dispatch `candidate-sweep` (Actions → candidate-sweep →
Run workflow). It mints the token, lists `refs/candidates/*`, and deletes nothing
older than 30 days. Success proves the token works and can read refs. Then check
the App's installation shows the expected repository only.

A free observation of the `status` trigger and its guard: any other app's commit
status on any commit calls `promote-candidate`, whose job is skipped unless the
context is `update-candidate` and the state is `success`. Observed with CodeRabbit's
`success` status on a pull request head: one skipped run, nothing attempted. So the
trigger can be confirmed before a candidate exists, and a status from another app
cannot promote.

Verification (task 0.4) — the boundary itself. Open a pull request that
(a) echoes `${{ secrets.AUTOMATION_APP_PRIVATE_KEY }}` and (b) declares
`environment: automation` on the job. Both must fail to produce the key: a
repository secret would have been readable, and the environment is not
selectable from a pull-request job. Then confirm the same file's run posts no
`update-candidate` status, and that the pipeline's own status job (default-branch
definition, same environment) does. Do this before enabling the ruleset.

Record the App ID and slug in `context/update-candidates.md` as configuration
values (they are not secret).

## 2. Labels (task 6.3, and the refresh step's prerequisite)

Create `accept-update` (the `label` policy uses it). `dependencies` and `automated`
already exist (see `context/package-updates.md`). Creating a label the repository
lacks fails `create-pull-request` with a 404.

Verification of task 6.5 (acceptance is bound to a revision). With
`PROMOTION_POLICY=label` and an open automation pull request:

1. Label it `accept-update`. `accept.yml` must post `update-accepted: success` on
   the pull request's head commit (`gh api repos/$R/repos/.../commits/<head>/statuses`),
   and the label must re-run `ci`, which re-runs the pipeline and reposts
   `update-candidate` on the candidate.
2. Confirm promotion proceeds. `promote-candidate.sh` requires the marker on the
   source revision, so this is also the check that the label event's payload
   carried the head SHA the code reads.
3. Push another commit to the branch without removing the label. The new revision
   carries no marker, the pipeline's status arrives for the new candidate, and
   promotion must refuse with `carries no update-accepted marker`. Re-adding the
   label is what accepts the new revision.
4. Age check: a candidate whose `update-candidate` status succeeded more than
   seven days ago must be refused by name rather than by an opaque rules
   violation. Reproducing it needs a rewound clock or a stored status; if that is
   impractical, confirm the refusal reads the status's `created_at` and that a
   re-validation reposts it.

## 3. Repository setting (no longer required)

`can_approve_pull_request_reviews` was enabled so the `GITHUB_TOKEN` could open the
refresh pull request. The refresh now uses the App token, so the setting is not
required. Revert it if you prefer the stricter default. Reverting does not affect
the App, which is not a `GITHUB_TOKEN` pull request.

## 4. Renovate (task 1.1 and 7.2)

The `renovate.json` change removes the nix manager, `lockFileMaintenance` and
automerge. It keeps `github-actions`.

1. Confirm the Mend Renovate app is installed on `Shrub24/nix-fleet`.
2. Let the next schedule run (Monday, before 6am), or trigger it from the
   Dependency Dashboard issue.
3. Verify (task 7.2): Renovate opens no lock-file pull request, and any Actions
   update it proposes reaches the candidate pipeline. A workflow-only candidate
   reports `evaluated; workflow-only change, no closure build`.

Automerge stays off: promotion, not Renovate, lands an update.

## 5. Ruleset on `main` (tasks 1.3, 1.4, 6.2) — after step 6

Test the rule on a scratch branch first, with the same shape. A ruleset on `main`
cannot be exercised safely by pushing to `main`.

Scratch experiment (delete afterwards):

```sh
# 1. scratch branch and a scratch ruleset with the same required status pinned to the App
gh api --method POST repos/Shrub24/nix-fleet/rulesets --input scratch-ruleset.json
#    scratch-ruleset.json: same body as below, with "include": ["refs/heads/scratch-candidate"]
# 2. a commit WITHOUT the status must be rejected
git push origin HEAD:refs/heads/scratch-candidate        # expect GH013
# 3. the same commit pushed to a candidate ref, status posted by the App, then ff-pushed: accepted
git push origin HEAD:refs/candidates/scratch/$SHA
gh api --method POST repos/Shrub24/nix-fleet/statuses/$SHA -f state=success -f context=update-candidate   # as the App
git push origin $SHA:refs/heads/scratch-candidate        # expect accepted
# 4. a status posted by another identity (your own token) must NOT satisfy the pin: repeat step 2 after posting it
# 5. delete the scratch ruleset and branch
```

Verification of task 1.3 is steps 2 and 4 failing, and step 3 succeeding. Task 1.4
(a skipped job and a missing workflow): open a human pull request and check that
the `update-candidate` status reads `success` from the pipeline's status job, and that a
docs-only change still reports it.

Production ruleset (after the scratch test passes):

```json
{
  "name": "candidate-promotion",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "update-candidate", "integration_id": <APP_ID> } ]
      }
    }
  ],
  "bypass_actors": []
}
```

Replace `<APP_ID>` with the numeric App ID. No pull-request rule and no bypass.

Require `update-candidate` alone. Do not add `update-accepted` to the required
list: it records acceptance, and removing an acceptance label posts it as
`failure` on purpose, so requiring it would block every pull request whose
acceptance was revoked.

The App needs no permission for the marker: `accept.yml` posts it with the
workflow token under `statuses: write`.

`gh api --method POST repos/Shrub24/nix-fleet/rulesets --input candidate-promotion.json`

## 6. First native run (tasks 2.x end to end, 7.1, 7.4)

Kill switch: `gh workflow disable promote-candidate` stops promotion without
touching anything else. `gh workflow enable promote-candidate` restores it.

1. Dispatch `package-updates-refresh`. It runs the producer
   (`update-packages --refresh-inputs`) and opens or updates
   `automation/package-updates` if anything moved. Verify (task 7.1): the pull
   request exists, its checks start without approval, and its body lists moved
   inputs and packages.
2. Watch `update-candidate` on that pull request. Verify: `prepare` publishes
   `refs/candidates/<pr>/<source>-<candidate>`; `evaluate` passes; `build` runs on
   the fleet builders and the separate `verify-cache` workflow passes; the `update-candidate` status lands on
   the candidate commit; the PR comment updates.
3. Promotion: `promote-candidate` fast-forwards `main` to the candidate. Verify:
   `main`'s head is the candidate commit, the source pull request shows as merged
   (task 6.2's reachability check), and the candidate's closure is served from the
   cache (`nix path-info --store <read-url> --recursive`, or the verify-cache log).
4. Re-run the trigger by pushing to `main` (or dispatching `update-candidate`):
   open automation pull requests are re-prepared and re-validated (task 5.3).

Verification of task 5.5 (no retry): the build stage is the only builder, so the
description `build failed` is the marker and there is no retry to observe. Confirm
instead that the `verify` job runs the cache verification as its own job, so a
cache miss reads as a cache miss rather than as a build failure.

Verification of the producer's two jobs (task 2.8): the `update` job's log shows
`propose=true` and the batch's report, and its environment exposes no App key; the
`publish` job applies `changes.patch` and opens the pull request. To see the
moved-base refusal, dispatch the refresh and land a commit on `main` while it
runs: the publishing job fails with `moved from … to …` and opens nothing.

Verification of task 4.2 (cache verification) on a real closure: a candidate
whose derivations are all cached reports `served by the cache`. A candidate with
an uncached derivation fails the `verify` job and the `update-candidate` status reads
`build failed`. To reproduce locally without GitHub:

```sh
nix build --dry-run --no-link --builders '' --store "local?root=$(mktemp -d)" .#checks.x86_64-linux
```

`will be built` lines name the uncached derivations.

## 6b. Tailscale trust for `verify-cache.yml` — operator

The Tailscale trust credential's workflow rule names the reusable workflow that may
join the tailnet. Cache verification moved out of `build-push-cache.yml` into
`verify-cache.yml` (so a build failure and a cache failure are separate results),
and its join is rejected until the credential lists that file too: the first live
run failed with `token exchange failed with status 403` pointing at the
credential, while the build job joined in the same run. Add
`Shrub24/nix-fleet/.github/workflows/verify-cache.yml@refs/heads/main` to the
allowed workflows (and the tag form once consumers pin one).

## 7. Niks3 trust for candidate builds (task 1.5) — nix-homelab owner

Candidate builds run from `workflow_run` (this repository's `ci`) triggered by a
pull request from an automation branch or by a push to `main`, through the
reusable `build-push-cache.yml`. The current cache trust is `main` only (see
`docs/contracts/ci.md`, "Cache authorization"). A candidate build from a
`pull_request` event is refused at upload until nix-homelab's policy admits it.

Hand the owner:

- the workflow path `Shrub24/nix-fleet/.github/workflows/build-push-cache.yml`;
- the event and ref values to admit: `workflow_run` from an automation branch and
  `renovate/*` branches, and `push` to `refs/heads/main`;
- the job environment, if you choose one (see `ci.md`, "Repository settings or a
  `ci` environment?").

Verification (task 1.5): decode the OIDC token in a throwaway step of a dispatched
run (`ACTIONS_ID_TOKEN_REQUEST_URL`, audience from the cache config) and record
`sub`, `ref`, `event_name`, `job_workflow_ref`, and `environment` in
`context/update-candidates.md`.

Until this is in place, a candidate's `build` fails at upload. That is the failure
the status reports, not a silent pass.

## 8. Open decisions (not blocking the code, blocking task 7.3)

- **Renovate tagged-input manager (task 7.3).** No flake input is tagged
  (`flake.nix` tracks branches). Adding the annotated regex manager with no tagged
  input would be dead configuration. Choose one input to pin to a release tag
  (candidates: `sops-nix`, `niks3`, or `flake-file`), then add the manager and
  verify one Renovate pull request through preparation, build and promotion.
- **Container image tags.** The design skips the closure build for Actions-only
  changes. Container image tags have no path convention in this repository yet, so
  that skip is not implemented; add it when an image pin exists.
- **Retry semantics.** Removed, not deferred: the only failure it covered was a
  hosted-runner shutdown in the native build step, and routine CI no longer builds.
  Revisit only if a fleet build starts failing on infrastructure regularly.

## 9. Troubleshooting

| Symptom                                                 | Cause                                                            | Action                                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `prepare` fails: merge conflict                         | the source conflicts with `main`                                 | re-run the producer, or resolve the source branch                                                           |
| `prepare` fails: `generated flake or lock is stale`     | the regeneration changed on a second run (the fixed-point check) | inspect the child commit's `git show`; the cause is a declaration that does not regenerate to a fixed point |
| `promote-candidate`: `not an update candidate` (notice) | a human pull request's `update-candidate` status                 | expected                                                                                                    |
| `promote-candidate`: `main moved`                       | `main` advanced after the candidate was prepared                 | wait for the `push` trigger's re-preparation, or dispatch `update-candidate`                                |
| `promote-candidate`: `status was posted by …`           | the status came from another identity                            | check the ruleset pin and the App's login variable                                                          |
| no `update-candidate` status on a human PR              | the App secret, variable or environment rule refused the job     | complete step 1 and task 0.2                                                                                |
| `update-candidate` status stays pending                 | the candidate run was superseded                                 | the newer candidate's status is the one that counts                                                         |

## 10. Rollback

1. `gh workflow disable promote-candidate` (promotion stops).
2. Delete the `candidate-promotion` ruleset (`gh api --method DELETE
repos/Shrub24/nix-fleet/rulesets/<id>`).
3. Revert `renovate.json` to the nix-manager shape, if the lock should move back
   to Renovate.
4. Revert the refresh workflow to publishing with `GITHUB_TOKEN` in the `update`
   job, if the App is removed. That job then holds the token beside the updaters,
   which is what the split exists to avoid: remove the App only together with the
   refresh workflow.

# Tasks

## 1. Coordinator artifact

- [x] 1.1 Add `ciCoordinator` to the fleet feature, projecting the profile bundle
      plus the cache and Tailscale coordinates; export it as
      `packages.<system>.ci-coordinator-<profile>`
- [x] 1.2 Enforce one-writer-per-setting at artifact build time (forbidden
      settings and non-additive `substituters` fail the build)
- [x] 1.3 Render for conventional install paths only; no self-reference
- [x] 1.4 `install.sh` installs the files, appends the include, and reads
      `builders` back through the installed configuration
- [x] 1.5 Confirm the artifact lands in the checked closure
      (`.#checks.<system>.packages` contains `cache-root`, `cache-public-key` and
      the coordinator packages)

## 2. Workflow

- [x] 2.1 Resolve the coordinator from `job.workflow_repository` /
      `job.workflow_sha` and run its installer
- [x] 2.2 Install Nix with the public cache preconfigured
- [x] 2.3 Write the builder identity to `/etc/nix/builder_ed25519` (`0640`)
- [x] 2.4 Resolve the tailnet identity and cache API URL from the coordinator,
      keeping the input overrides
- [x] 2.5 Remove `builders` from the workflow's `NIX_CONFIG`; keep `max-jobs = 1`
- [x] 2.6 Make `prepare` selection-only
- [x] 2.7 Rename `builder_attr` to `profile` with no alias, at every in-repo caller
- [x] 2.8 Replace the reachability gate with a report that runs on `always()` and
      cannot fail the job

## 3. Checks

- [x] 3.1 Replace the old workflow check with `tests/ci/build_workflow_check.py`
      covering the input contract, selection-only prepare, installer bootstrap,
      coordinator wiring, non-fatal reporting and the build step's config
- [x] 3.2 Assert the bootstrap substituter and key equal the rendered artifacts
- [x] 3.3 Prove the check is non-vacuous with two mutants (stale bootstrap value;
      `builders` restored to `NIX_CONFIG`)
- [x] 3.4 Assert `cache-root` is in the checked closure so pinning has a subject

## 4. Documentation

- [x] 4.1 `docs/contracts/ci.md`: coordinator section, one-writer rule, key
      placement, no restart, bootstrap and reporting, cache-root coupling
- [x] 4.2 `README.md` and `docs/contracts/update-candidates.md` follow the rename
- [x] 4.3 Record the decisions in `context/flake-checks.md`

## 5. Validation

- [x] 5.1 Dispatch `build-push-cache` on this repository and read the report:
      builders listed, SSH results from both contexts, realisations counted
      (run 39543925779: coordinator resolved and built, tailnet joined, cache
      configured, build and report both green)
- [x] 5.2 Confirm the coordinator substituted or built with no error, and that the
      build still realised its selection (run 39543925779: coordinator built once
      from a cold cache, as intended for the first revision carrying it)
- [ ] 5.3 Adopt in `agent-radar` (no existing workflows), then `memex`
      (flake-utils, real Qt closure), pinning the workflow by commit and passing
      only the builder key
- [x] 5.4 Confirm builder use builder-side rather than from the run log
      (home-forge accepted `nixbuild (trusted)` **and** `root (trusted)` sessions in
      run 39543925779's window and wrote 7 derivation logs, so the `0640 root:runner`
      identity works from both contexts; the coordinator's log shows neither)

## 6. Deferred

- [ ] 6.1 Consumer pinning and verification: publish a `cacheRoot` module or state
      plainly that pinning remains fleet-owned
- [ ] 6.2 Cache locality for consumers (needs `nixpkgs.follows` on the fleet input
      in each consumer flake)
- [ ] 6.3 A per-builder serve-session metric, so silent local fallback is visible
      as a metric rather than a gate
- [ ] 6.4 A participant tag for the credential claims, pending a second federation

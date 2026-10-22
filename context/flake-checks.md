# Flake checks

## Contract evaluations are independent check leaves

**Id:** 085c2d59-0fac-4d27-9336-4300140b88b0
**Type:** decision
**Status:** superseded
**Evidence:** confirmed
**Source:** fixture evaluation measurements at parent revision 6a9148595b56 and after the leaf split, 2026-10-08

Throwaway NixOS evaluations for feature contracts are independent `checks.<system>.<name>` leaves rather than assertions nested in the representative fixture host. The fixture still builds as the consumer-shaped cross-aspect integration proof; its own assertions still cover properties that only its composed configuration can show.

**Reason:** the nested evaluations did not read the fixture host. The outer toplevel forced them only through its assertion list, raising x86 evaluation from 4.5 seconds / 0.72 GiB with assertions removed to 91 seconds / 2.6 GiB. Separating the independent roots reduced host evaluation to about 5 seconds / 0.75 GiB and gave failures their own check names.

**Rejected alternative:** keep every contract in one fixture's assertions. That couples unrelated feature tests to the integration root and repeats hardcoded x86 evaluations when the ARM fixture is checked.

**Rejected alternative:** replace NixOS evaluations wholesale with `lib.evalModules` or stubs. This would no longer exercise the actual NixOS module options and service integration the contracts assert.

**Superseded by:** d3c50817-8133-4dc2-90e6-2c31111a4865

## Canonical architecture for policy checks

**Id:** d3c50817-8133-4dc2-90e6-2c31111a4865
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** maintainer decision and CI workflow configuration, 2026-10-10
**Source:** maintainer decision, 2026-10-10; `.github/workflows/ci.yml` and `.github/workflows/build-push-cache.yml`

Platform-independent policy checks are registered once under `checks.x86_64-linux`. Checks whose result can depend on the evaluated system remain per-system; the two fixture toplevel configurations and their builds remain per-system on both supported architectures. The rule applies per leaf: mixed-substrate leaves remain per-system unless split into separate checks. Placement also follows build capability, not evaluation alone: a check whose build needs features a system's builders do not advertise is registered where those features exist. The disposable Podman VM check is `x86_64-linux`-only for that reason — no aarch64 builder in the fleet advertises `kvm`, so an aarch64 copy could never be built or cached, and it failed the fleet build on every dispatch until it was scoped.

**Reason:** pure policy evaluation has no architecture-dependent behavior, so evaluating it on both systems duplicates work without increasing coverage. x86_64-linux remains the canonical system by maintainer choice; this placement is independent of whether routine CI builds the check outputs. The ARM fixture still evaluates as a separate integration target, and build-capability constraints continue to place checks only where their outputs can be built.

**Rejected alternative:** canonicalize on aarch64 because the dispatch coordinator defaults to ARM. That workflow targets both architectures and uses builders independently of its coordinator, so the default coordinator does not confer additional policy coverage.

**Rejected alternative:** keep all leaves per-system. This evaluates platform-independent policy twice without testing a distinct behavior.

**Consequence:** a mixed leaf can temporarily repeat its pure cases on both systems; only split it when the duplication merits extra leaf names and maintenance. If platform dependence is uncertain, retain per-system coverage.

## Routine PR CI evaluates; fleet CI builds

**Id:** 50eb5125-a863-46f9-b9cb-e75a30538782
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** maintainer decision and `.github/workflows/ci.yml`, 2026-10-11

Routine push and pull-request CI checks formatting and evaluates declared checks on all supported systems with the `validate-flake` action, which runs `nix flake check --no-build` and does not build every check output. Actual check builds use the manually dispatched fleet-build path, which exercises the selected builders and cache.

**Reason:** building the entire check surface natively on the GitHub runner can spend over an hour compiling dependencies such as Vector while exercising neither the fleet's builder configuration nor its cache. Evaluation is the inexpensive routine gate; the fleet build path owns distribution and build acceptance.

**Rejected alternative:** build all native check outputs on every push and pull request. This is expensive and tests the runner's fallback build path rather than the fleet builder/cache path.

**Consequence:** routine CI proves formatting and evaluation, not that every derivation builds. Use the fleet-build dispatch when build and cache acceptance is required. A harness that executes a workflow step is itself only executed where checks are built, so a step that starts writing an output (`$GITHUB_OUTPUT`, `$GITHUB_STEP_SUMMARY`) and a harness that does not provide it diverge silently — nothing evaluates it, and only a build fails. When a workflow step's contract or a harness changes, build the leaf (`nix build .#checks.<system>.<leaf>`) or dispatch the fleet build before trusting the gate.

## Named fail-closed errors are public contract surface

**Id:** 54835555-ead9-4f93-b7cc-0c00d0c4e231
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** `AGENTS.md` fail-closed rule and `docs/contracts/telemetry.md` error contract, 2026-10-08

When a module rejects invalid input, the error names its owning aspect and the specific invalid condition. A contract leaf pins the documented diagnostic so the same named error remains visible to users and maintainers.

**Reason:** an attribute that merely throws is not enough to provide actionable diagnosis, and callers may rely on the named failure when validating their configuration. The fixture compares diagnostic content with the contract documentation; changing the message is therefore an observable contract change.

**Rejected alternative:** accept any evaluation failure as proof of rejection. It can pass because of an unrelated typo, missing option, or another earlier assertion, obscuring which contract is actually being tested.

## The CI coordinator is resolved from the workflow's own revision

**Id:** 7d1f0a44-6a3c-4f3b-9d2e-1c5b8a90e6f2
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/build-push-cache.yml`, `modules/fleet/feature.nix`, 2026-10-11

The build job resolves its builder and cache configuration with
`nix build github:<job.workflow_repository>@<job.workflow_sha>#packages.<runner_system>.ci-coordinator-<profile>`.
`job.workflow_sha` is the commit that defines the reusable workflow file, so a
consumer pins one reference and obtains machinery and fleet facts from one exact
revision. The artifact is a projection of the existing builder-profile and cache
projections and is published through `checks.packages` with no extra plumbing.

**Reason:** a `fleet_ref` input or re-exported builder metadata would be a second
version to keep in step with the workflow that consumes it, and the two could
disagree. Deriving the revision makes disagreement unrepresentable.

**Rejected alternatives:** a `fleet_ref` workflow input; consumers re-exporting
fleet outputs; a published metadata artifact with its own compatibility contract;
checking the fleet out beside the consumer's tree (the build needs the consumer
checkout, and a second checkout would shadow it).

**Revisit when:** a caller must build with fleet facts from a revision other than
the one defining the workflow — for example a staged fleet rollout.

## The coordinator owns builder and cache configuration, nothing else

**Id:** 3f2a6c18-9b47-4e51-8c0a-5d9e7b41c283
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `modules/fleet/feature.nix` (`ciCoordinator`), `docs/contracts/ci.md`, 2026-10-11

The coordinator writes `builders`, `builders-use-substitutes`,
`extra-substituters` and `extra-trusted-public-keys`, and its build fails if
`trusted-users`, `post-build-hook`, `sandbox` or `experimental-features` appear,
or if `substituters` is written in its non-additive form. `trusted-users` belongs
to the installer; `niks3-action` installs the post-build hook in its own
user-level configuration, which overrides `/etc/nix/nix.conf`.

**Reason:** `niks3-action` needs a trusted user for the hook and prepends its own
config, so a coordinator that also set `trusted-users` would silently stop
publication — a failure that looks like an empty cache, not an error.

**Rejected alternatives:** letting the coordinator render a complete `nix.conf`
(one authority per setting is the property that keeps publication working);
keeping `builders` in the workflow's `NIX_CONFIG` (two authorities for one
setting drift).

**Revisit when:** the publishing action stops writing user-level Nix configuration.

## An unavailable builder is reported, not vetoed

**Id:** 0c6b8e57-2f19-4a83-b7d5-6f2c1e934a08
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/build-push-cache.yml` (step `Report builders and realisations`), 2026-10-11

The job reports the effective `builders` value, per-builder `runner` and `root`
SSH results, and the number of build logs written on the runner. It does not
refuse to schedule when a builder is unreachable. A previous pre-flight dialled
every builder and failed the job when a requested system had nowhere to build.

**Reason:** a transient builder outage would become a blocked pipeline, and
per-run gates duplicate what fleet telemetry does better over time. The report
separates configured, reachable and used builders; only the first two are
established, because a run that built everything locally also reports reachable
builders.

**Rejected alternatives:** the reachability gate (turned an outage into a
failure); a build-forcing probe with `max-jobs = 0` (a correctness gate for
something the build itself reveals); custom failure watchers and notifications
(owned by the fleet's metrics and notify aspects).

**Revisit when:** builds silently fall back to local execution often enough that
the cache stops warming — then the signal needs to be a metric, not a refusal.

## Evaluation writes source paths; the check still decides

**Id:** b9097fc6-67c6-4751-9616-b7b48ca380b3
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** cold-store reproduction against `Shrub24/nix-dotfiles` at `3b8d99f8`, 2026-10-22

`validate-flake` primes with a writable `nix eval` that forces the derivations an
all-systems check evaluates, then runs stock `nix flake check --no-build` and
takes its verdict. Priming writes source paths into the store and builds nothing;
its own failure is a warning, never the verdict. Import from derivation is
disabled in both stages. Local validation, PR validation and refresh producers
use this same command; keeping the bare check in a producer would preserve the
cold-store dependency precisely where newly updated dependencies first enter.

**Reason:** `--no-build` puts `nix flake check` in read-only mode, where coercing a
path to a store path computes the name and writes nothing. A dependency that read
such a path during evaluation — nix-wrapper-modules' `${pkgs.path}` gemdir,
uv2nix's filtered lockfile — failed with `path '…' is not valid` on a cold store and
passed on a warm one, so the gate depended on runner history rather than on the
revision. Writable evaluation is what `nix eval` does by default and is documented
as instantiating the `.drv` closure of everything it references
(`NixOS/nix#6323`); `nix flake check` forces the read-only mode instead, which
dates to `a9d3524e1f` and is still open as a defect (`NixOS/nix#15448`, where a
maintainer confirms read-only mode leaves the referenced store objects unwritten). Measured on that reproduction: the bare command fails in 11 s on a fresh
store; priming (2m11s) then the same check passes (34 s) on that store; a
malformed `packages` entry and a failing configuration assertion still fail.

**Rejected alternatives:** plain `nix flake check` (builds every check, VM tests
included, which is why `--no-build` exists); `nix build --dry-run` over a
consumer's own targets (writable, but validates a selection rather than the whole
flake output set); decoupling `--no-build` from read-only mode in Nix (the right
long-term fix, and not available in a released Nix); allowing import from
derivation in the gate (it would run builds in a job with no builder credentials
and no platform for the other system).

**Revisit when:** a released Nix decouples `--no-build` from read-only mode, or an
output kind the prime does not force starts failing cold.

## The builder key is runner-owned at 0600

**Id:** 3d9a41c2-7b58-4e06-a1f3-92c8d05e6b17
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/build-push-cache.yml` (step `Install the builder SSH identity`)

The key at `/etc/nix/builder_ed25519` is owned by the runner, mode `0600`.

**Reason:** OpenSSH rejects a private key with group or other bits only when the file
is owned by the user loading it (`sshkey_perm_ok`, `st_uid == getuid()`). The earlier
`0640 root:runner` key was therefore refused for root while loading for the runner.
Root reads any file regardless of owner, so the runner-owned key serves both.

**Rejected alternatives:** two `0600` copies (a second secret on disk for no gain);
retaining `0640` on the belief that the builder-side `root` sessions proved it worked
(they do not show which local user supplied the key).

**Revisit when:** a builder session is shown to originate from a context that cannot
read a runner-owned file.

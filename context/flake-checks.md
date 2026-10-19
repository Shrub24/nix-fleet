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

Routine push and pull-request CI checks formatting and evaluates declared checks on all supported systems with `nix flake check --no-build`; it does not build every check output. Actual check builds use the manually dispatched fleet-build path, which exercises the selected builders and cache.

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

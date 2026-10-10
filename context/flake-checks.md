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

**Reason:** pure policy evaluation has no architecture-dependent behavior, so evaluating it on both systems duplicates work without increasing coverage. x86_64-linux is the standard canonical system because the required PR validation workflow (`ci.yml`) builds native x86_64 checks. The dispatch fleet workflow's default aarch64 coordinator does not make aarch64 the better canonical home: it requests both `x86_64-linux` and `aarch64-linux` by default, while the PR gate is the routine native check-build gate. The ARM fixture still evaluates and builds as a separate integration target.

**Rejected alternative:** canonicalize on aarch64 because the dispatch coordinator defaults to ARM. That workflow targets both architectures and uses builders independently of its coordinator, so the default coordinator does not confer additional policy coverage; x86 aligns with the regular PR build gate instead.

**Rejected alternative:** keep all leaves per-system. This evaluates platform-independent policy twice without testing a distinct behavior.

**Consequence:** a mixed leaf can temporarily repeat its pure cases on both systems; only split it when the duplication merits extra leaf names and maintenance. If platform dependence is uncertain, retain per-system coverage.

## Named fail-closed errors are public contract surface

**Id:** 54835555-ead9-4f93-b7cc-0c00d0c4e231
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** `AGENTS.md` fail-closed rule and `docs/contracts/telemetry.md` error contract, 2026-10-08

When a module rejects invalid input, the error names its owning aspect and the specific invalid condition. A contract leaf pins the documented diagnostic so the same named error remains visible to users and maintainers.

**Reason:** an attribute that merely throws is not enough to provide actionable diagnosis, and callers may rely on the named failure when validating their configuration. The fixture compares diagnostic content with the contract documentation; changing the message is therefore an observable contract change.

**Rejected alternative:** accept any evaluation failure as proof of rejection. It can pass because of an unrelated typo, missing option, or another earlier assertion, obscuring which contract is actually being tested.

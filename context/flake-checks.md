# Flake checks

## Contract evaluations are independent check leaves

**Id:** 085c2d59-0fac-4d27-9336-4300140b88b0
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** fixture evaluation measurements at parent revision 6a9148595b56 and after the leaf split, 2026-10-08

Throwaway NixOS evaluations for feature contracts are independent `checks.<system>.<name>` leaves rather than assertions nested in the representative fixture host. The fixture still builds as the consumer-shaped cross-aspect integration proof; its own assertions still cover properties that only its composed configuration can show.

**Reason:** the nested evaluations did not read the fixture host. The outer toplevel forced them only through its assertion list, raising x86 evaluation from 4.5 seconds / 0.72 GiB with assertions removed to 91 seconds / 2.6 GiB. Separating the independent roots reduced host evaluation to about 5 seconds / 0.75 GiB and gave failures their own check names. The leaves remain per-system to exercise the same declared system as their check.

**Rejected alternative:** keep every contract in one fixture's assertions. That couples unrelated feature tests to the integration root and repeats hardcoded x86 evaluations when the ARM fixture is checked.

**Rejected alternative:** replace NixOS evaluations wholesale with `lib.evalModules` or stubs. This would no longer exercise the actual NixOS module options and service integration the contracts assert.

## Named fail-closed errors are public contract surface

**Id:** 54835555-ead9-4f93-b7cc-0c00d0c4e231
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** `AGENTS.md` fail-closed rule and `docs/contracts/telemetry.md` error contract, 2026-10-08

When a module rejects invalid input, the error names its owning aspect and the specific invalid condition. A contract leaf pins the documented diagnostic so the same named error remains visible to users and maintainers.

**Reason:** an attribute that merely throws is not enough to provide actionable diagnosis, and callers may rely on the named failure when validating their configuration. The fixture compares diagnostic content with the contract documentation; changing the message is therefore an observable contract change.

**Rejected alternative:** accept any evaluation failure as proof of rejection. It can pass because of an unrelated typo, missing option, or another earlier assertion, obscuring which contract is actually being tested.

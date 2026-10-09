# Check surface

## A check earns its place by protecting behaviour this repo owns

**Id:** 0b0f5d64-8c76-4a2f-9d13-2d5c0ca4f1e8
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** check-surface trim, `docs/contracts/ci.md`, `AGENTS.md`, 2026-10-09

A check exists only where nix-fleet owns the behaviour: a non-trivial
transformation or projection, a fail-closed validation branch, a composition
seam across aspects, or runtime code this repo ships. Restating a literal
default, or re-proving nixpkgs, systemd or an upstream daemon, is not coverage.
Prefer the cheapest layer that still exercises the branch — a pure assertion,
then `lib.evalModules` over the contract module and option values, then a
focused NixOS system, then runtime for owned code only.

**Reason:** consumers express about six option blocks across the whole fleet,
while the fixture had grown to force roughly 110 nested NixOS evaluations
through 27 leaves and 32 host assertions, several of which asserted an aspect's
own literal back at it. The surface was testing nix-fleet's composition more
than the behaviour a host depends on, and the cost landed in the dispatch
build's evaluator budget rather than in coverage.

**Rejected alternative:** keep the surface and raise the evaluator budget.
Raising it preserves the distraction; the same measurement that motivated the
trim showed a leaf's peak is what fails, so a bigger budget only postpones it.

**Rejected alternative:** delete expensive checks wholesale as "upstream". The
lean-view profile and the Latitude bridge are artifacts this repo authors, and a
hand-doubled backslash once produced a valid but wrong regex that neither
evaluation nor the collector's config validation can see. Upstream semantics go;
owned artifact behaviour stays even when it costs a runtime check.

## The leaf registry is gone; the contract map is the single source

**Id:** 3d1c8a2e-5f47-4b90-a7c2-6be21f9a8d03
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `modules/flake/fixture.nix`, `docs/contracts/ci.md`, 2026-10-09

The fixture's `contract` map defines the leaves; the literal
`expectedContractLeaves` list and the `contract-leaf-registry` check that
compared them are removed. No shape checks, no inventory file.

**Reason:** the second list only proved that names matched, had to be hand-synced
in both directions, and did not notice the failure that actually occurred —
`node-exporter-admission` carried a message claiming a rejection its body never
performed, passing the registry while asserting something else. Accepted
consequence: removing a leaf from the map is now a visible diff in review rather
than a failing check.

**Revisit if:** a leaf is ever dropped without review noticing. Shape checks over
the map (unique, non-empty messages) are the smaller follow-up; a static
non-vacuity checker, or inspecting check bodies for evidence of coverage, would
recreate the problem the trim removed.

## Removed checks and what replaces them

**Id:** c6a41f77-9b02-4e5d-8f60-1a7bd43c92e5
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** check-surface trim, 2026-10-09

| Removed                                                                | Reason                                                                                                                                                   | Replacement or accepted gap                                                                                                        |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `nix-baseline`                                                         | restated the aspect's literal `mkDefault` defaults                                                                                                       | plain evaluation in `nix flake check`                                                                                              |
| `node-exporter-admission`                                              | its message claimed a rejection its body never performed, and the claim is not an invariant — the aspect imports the contract and stays valid standalone | inertness is owned by `telemetry-capability-matrix` and `telemetry-dormant-declarations`                                           |
| `contract-leaf-registry`                                               | second inventory of the same names                                                                                                                       | see the entry above                                                                                                                |
| `vmalert-rules`                                                        | the rule is fixture consumer data rendered by nixpkgs; the check proved that vmalert works                                                               | `alerting-admission` and the host's alerting → notify seam keep the fleet-owned validation and mapping                             |
| `telemetry-delivery`, `telemetry-ingress`, `telemetry-route-isolation` | the collector's own queue, WAL, fan-out and listener semantics, under a config nixpkgs already validates at build time                                   | accepted gap: queue persistence on a real machine, and a listener that binds but cannot serve, are consumer integration properties |

Twenty fixture-host assertions went with them: fourteen restated an aspect's own
literal, four duplicated a leaf, and two were the notify policy pair.

**Reason:** each was coverage of something other than nix-fleet's behaviour, or of
it twice. The proofs that survive are the ones that caught real failures — the
phantom `nh-clean` drop-in and the registration outliving its unit, the phantom
`tailscaled-autoconnect` and its sops ordering, build-account trust reaching
`nix.settings.trusted-users`, the notify registration/unit join, and the vmagent
credential guard.

## A deleted block can orphan a binding, and `nix fmt` enforces the rule

**Id:** 8e27b490-1c3f-4d58-9a11-7f60cb2d5e94
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** check-surface trim, `modules/flake/fixture.nix`, 2026-10-09

Removing the host assertion that read `resolvedDocsMcp` left the binding with no
user; deadnix, pinned at the highest formatter priority, removes it during
`nix fmt`.

**Reason:** recorded because it is the mechanical form of the rule that a helper
stays only while a check still calls it — and because a trim that leaves dead
bindings behind looks like drift in the next review.

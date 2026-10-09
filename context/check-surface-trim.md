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

## What the trim removed, and what covers each claim

**Id:** 5c81d0a4-6f27-4a5e-9b13-2e7f4c8a91b6
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** check-surface trim, `b524d38d` (the deletes), `c6e8a1bb` (the simplify rows), `2b393e8c` (the notify row), 2026-10-09

Surface: 49 checks to 43 — seven deleted, one added (the `bifrost-module` /
`bifrost-module-runtime` split, so a module-option regression fails under the
module's own name rather than as a runtime failure).

Every removal below was checked for what would break while ordinary evaluation
and `nix flake check` stay valid. Where nothing we own would break, the check
went; where something would, the claim stays somewhere else and that place is
named.

**Upstream behaviour we were re-proving.** `telemetry-delivery`,
`telemetry-ingress` and `telemetry-route-isolation` (1,162 lines of Python) ran
the Collector to observe queue/WAL fan-out, listener admission and per-pipeline
isolation. nixpkgs validates the collector config at build, and the fleet-owned
half of each claim is rendered configuration: the StateDirectory coupling and
the processor boundary in the host's ingress block, the pipeline set in
`telemetry-capability-matrix`, the route→receiver/exporter mapping in
`telemetry-routes`. Accepted gap, explicit: persistence on an impermanent
machine is a consumer integration property, not something a fleet check can
settle.

**Nothing repo-owned.** `vmalert-rules` tested a rule file that is consumer
data rendered by nixpkgs. `nix-baseline` pinned `nixVersions.latest` and
scheduling weights — `mkDefault`s on upstream options, evaluated by plain
`nix flake check`. `node-exporter-admission` claimed in its message that "a
scrape registration without the host aspect no longer fails by name" while its
body performed no rejection: the aspect imports the contract and stays valid
standalone, and inertness is owned by `telemetry-capability-matrix` and
`telemetry-dormant-declarations`. A check whose message outruns its body is the
decay this trim exists to remove.

**Literal restatements.** Twenty fixture-host assertion blocks, fourteen of them
restating an aspect's own literal and four duplicating a leaf that survives. The
concentration was the pattern, not the claims: the host had grown into "every
aspect shows its contribution". Same reasoning in the simplify rows —
`build-account-trust` now reads the renamed identity through the option instead
of the literal, `nix-baseline-substitution` asserts the append seam covers the
key list, the nix-gc leaf dropped twenty-four restated defaults, `C28` reads the
registration's bind off the exporter. Kept by the owner's ruling: the queue,
disk-bound and per-destination limits, because queue configuration belongs in
the check surface while persistence on a real machine does not.

**Duplicate coverage.** The two rejection cases asserted identically by the
mutation and credential leaves; `vmagent-rendered-jobs`'s `noScrape` case, which
is `vmagent-realization`'s `noOtel` composition evaluated again; the
endpoint-guard's duplicate and mis-attributed probes, with the
signals-without-carrier branch pinned by name in `telemetry-otlp-rejections`.

**A name registry.** `contract-leaf-registry` and its 27-name list. The contract
map is now the single inventory. Accepted gap: removing an entry from it fails
nothing by itself — that is caught by review and by this record.

**Substrate, not removal.** `notify-rendered-policy` moved from a build-time
python run to a feature-owned evaluation check reading the rendered
`/etc/notify` bytes, which required rendering `events.json` through `text`
rather than a `writeJSON` derivation: a derivation exposes no text, and the etc
entry's `value` is the generator's input, so asserting on it would be the option
asserting itself.

**Kept because they caught real defects, and what each still pins.**
`nix-gc-defaults` — the phantom `nh-clean` drop-in and a registration outliving
its unit, including the single-flag case (one unit off while the others stay on)
that is the only composition discriminating a registration wired to a sibling's
flag; proved by mutation. `tailscale-autoconnect` — a phantom unit with no
`ExecStart`, and the sops ordering. `build-account-trust` — the dispatch identity
that must enter `trusted-users`, from the unsigned-input rejection in CI.
`vmagent-secret-guard` — values vmagent's parser treats as structure.
`telemetry-output-view-projection` — a syntactically valid but semantically wrong
OTTL regex, invisible to evaluation and to `otelcol validate` alike. The notify
join — a registration naming a unit that does not exist.

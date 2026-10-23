# Design

## Decision 1 — a controller that pulls, not a runner that is called

Work must reach a persistent controller without GitHub holding credentials into the
fleet.

| Shape                                                             | Outcome                                                                                                           |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| The controller watches GitHub (App events) and reports check runs | **Chosen.** No inbound credentials, no per-repository build secrets.                                              |
| A self-hosted Actions runner on the controller                    | Rejected. Fork pull requests would run on it; GitHub advises against self-hosted runners for public repositories. |
| A hosted-runner job calling the controller                        | Rejected. It brings the per-run tailnet join and credentials back, one step removed.                              |

## Decision 2 — the coordinator's facts become host configuration

The inventory stays the single source. `lib.buildProfile` is consumed as NixOS
options on the controller host instead of an artifact installed per run.

## Decision 3 — admission, not publication, is the policy point

The question is which pull requests may run CI, not which completed builds may
publish. Trust to execute code on our builders and trust to publish signed outputs
intentionally coincide for an admitted pull request.

| Pull request        | Treatment                                                          |
| ------------------- | ------------------------------------------------------------------ |
| Verified automation | Admitted automatically; full build and publication; auto-merge     |
| Any other           | Held until approved for CI; then the same pipeline; merge separate |
| `main`              | Build reuse, publication reconciliation, rolling pins              |

Rejected: selective publication (conditional uploaders, label-triggered rebuilds,
cache catch-up for pull-request builds). It needs a new build/publish seam in nixbot
and a catch-up path, and reuses nothing that exists.

### Why publication is not a separate trust line

An input-addressed store path is a function of its inputs. A malicious change alters
the derivation, so its output lands under a path no honest evaluation requests; a
consumer substitutes only the paths its own evaluation produces. What publication adds
beyond execution is storage use and a signed artefact for a source nobody chose. A
bad revision that lands is source poisoning, which the merge gate owns. Poisoning a
path an honest evaluation would request needs a sandbox escape or a compromised
builder, which is the trust already granted by running the code.

## Decision 4 — GitHub owns merging

Auto-merge on required checks for automation pull requests; operator merge for the
rest. The exact-SHA invariant of the candidate pipeline is dropped. When a pull
request is already up to date, the synthetic merge the controller validates, and the
commit GitHub produces, have the same tree, so build reuse applies. Provenance in a
derivation (`self.rev`) would break that; the only consumer found is removed (see
proposal).

## Decision 5 — the producer stays in Actions until the controller operates

Moving it earns deletion only when the controller holds the App key. Native
`onSchedule` is real, but the producer's secret and network boundary needs explicit
design first (Decision 7).

## Decision 6 — builders are a separate layer

Orchestration and distribution are independent. The controller must work with the
present `ssh-ng` builders first; `nix-grpc-store` farm mode can replace the transport
later.

## Decision 7 — isolation facts that bound a native producer

- An effect with no `secretsMap` receives the **whole** configured secrets file; an
  explicitly empty map grants none.
- An effect runs on a persistent host with network access; it is not a throwaway VM.
- Git credentials, OIDC audiences and host reach must be accounted for, not only the
  secret map.

## Verified in nixbot's source and documentation

- `prApproval.untrusted()` decides: disabled, non-GitHub or non-PR → trusted;
  `head_in_base_repo` → trusted ("covers GitHub Apps/bots, which always report NONE");
  otherwise `author_association` against `trusted_associations`. Held pull requests
  get an `action_required` check run named `<prefix>/nix-eval` with an _Approve CI_
  action; approval persists and later pushes build.
- The parser keeps `pr_author` (login) and `actor` (webhook sender) but no author id
  or type. Reconcile polling carries no actor.
- Uploaders are global and unconditional; failures are warn-only with three attempts
  thirty seconds apart.
- `after_build` runs for fresh, re-run and reused builds. A reused build whose effects
  already started **replays statuses and does not run effects again**; otherwise the
  default-branch push runs them. Effects can be restarted by API or `nbo`.
- `onSchedule` persists schedules and re-discovers them only after a successful
  default-branch build; persisted schedules keep firing; due window is five minutes.
- Event effects post no statuses; every build also builds effects' dependencies
  without running them.
- GitHub rulesets accept GitHub Apps as bypass actors. `OrganizationAdmin` is the
  type documented as not applicable to personal repositories; `Integration` is not so
  marked. Not yet exercised on a personal repository.

## Not verified

- That an `Integration` bypass works on a personal repository in practice.
- The aggregate check name and whether a ruleset can pin it by integration id.
- Instance default for `build_branches` (a non-PR push builds with no approval).
- Whether an `onPush` effect can create pins and repair a failed upload idempotently.
- `merge_group` handling (deferred, so not needed).
- Deployed niks3 version against the module's requirement.

## Hidden limits of admission-first

1. **Trust is per pull request, not per revision.** Approval persists across later
   pushes. A later push by anyone with write access to an automation branch, or to an
   approved human branch, runs unreviewed code. Real enforcement of "only the App
   writes automation branches" is a GitHub ruleset, not nixbot.
2. **Per-event actor checks are insufficient.** A label or reopen by the App on a head
   a human pushed would pass; the gate must stay held until explicit approval, and a
   missing actor (reconcile) must count as untrusted.
3. **Non-PR pushes bypass admission.** Any branch matching the instance
   `build_branches` globs builds on push.
4. **Held pull requests fail closed**, which suits a required check but costs a click
   for the operator's own pull requests unless the operator is trusted by login.
5. **Renovate pull requests are held** unless its bot is trusted.
6. **Cache readiness is not implied by a green build.** Reconciliation belongs to a
   default-branch effect, and a once-only effect cannot be the only repair path.

## Cache readiness without promotion machinery

A default-branch effect pushes the retention root (idempotent) and pins it. Pinning
already refuses a path the cache does not hold, so the effect is both repair and
presence assertion. It must not be tied to once-only execution: reuse replays
statuses, so repair also needs a restart path or a scheduled run.

## Alternatives recorded

- **buildbot-nix**: predecessor of nixbot per its own documentation.
- **Hercules CI**: hosted control plane, agents on our hardware; `onEvent` is
  nixbot-only.
- **Hydra**: described by nixbot's authors as not recommended for new deployments.
- **Garnix**: fully hosted; unverified.
- **A bespoke GitHub App**: the same orchestration written again, with a service to
  operate.

## Portability

Express selection as flake outputs (`checks`, `packages.cache-root`) and, where
practical, a `herculesCI` output.

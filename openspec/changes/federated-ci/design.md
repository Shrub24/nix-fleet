# Design

## Decisions

### D1 Effects are module entries, not a closed set plus extras

`ci.effects.onPush.<name>` and `.onSchedule.<name>` are `attrsOf (functionTo
(nullOr raw))`. The fleet's effects are ordinary entries under `mkIf`, so a
repository disables or replaces one with module priority instead of a bespoke
collision rule. A function returning null skips the effect for that push, which is
how branch and tag gating are expressed.

### D2 The instance is a descriptor the operator publishes

`ci.instance = { system; cacheUrl; writeEndpoint; }` is bound from a zero-input
flake the operator publishes (`<repo>?dir=ci`, `lib.instance`). Zero inputs keep it
out of every consumer's lock graph; nix-fleet stays free of endpoints.

### D3 Retention is pins; history shifts, never deletes

The rolling pin per system stays `<name>-<branch>-<system>`, so existing pins keep
their names. `generations = n` keeps earlier roots as `<pin>-1 … <pin>-n`, shifted
only when the rolling pin moves (a rerun keeps history). Deleting a pin needs the
cache's admin scope (`DELETE /api/pins/{name}` requires `ScopeAdmin`), so the effect
rewrites slots with `pins create` and never deletes. Tags pin under
`<name>-release-<tag>-<system>` with a separate effect and rule, so a release can
move only release pins.

### D4 One update transaction over three kinds of source

Packages (nix-update), lockfiles (the ecosystem's command) and commands (anything
else) share the runner's staging: each declares a write set, an out-of-set write is
not adopted, and one pull request carries the result. Lockfile adapters assume the
build reads the lockfile; a vendored hash needs a command.

### D5 Owner-wide discovery and trust; one list enrols

The App is installed on every repository of the owner and `userAllowlist` is the
owner, so nixbot discovers everything; the cache trusts the owner's retention and
release effects with one rule pair, since niks3 pin patterns are static and cannot
name the token's repository. Enrolment is the operator's list alone: `ci-enrol`
enables listed projects and gives them auto-merge and the `nixbot` ruleset, and
disables any other enabled project and removes its ruleset, so the list stays
authoritative. nixbot's API lists only enabled projects, so disabling elsewhere is
not reconciled. The update helper fails when auto-merge is refused instead of
merging, so a repository without the ruleset never lands an unchecked proposal.
OpenTofu was rejected: it needs a state backend for a handful of idempotent calls.

### D6 No `nixbot.toml`

nixbot's defaults (`attribute = "checks"`, `effects_on_pull_requests = false`, no
extra branches without instance `branches`) are the policy, and an invalid file
silently reverts to them, so a generated file would add a drift check for nothing.

## Out of scope

The nixbot service aspect; retiring the GitHub Actions stack (per repository, after
an observed cycle); a vendored-hash recompute adapter.

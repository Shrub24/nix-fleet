# Design

## Context

Homelab's effects are correct and running; this change moves the mechanism, not
the behaviour. Upstream facts relied on (pinned nixbot):

- Workload-identity effect names are dotted attribute paths from the onPush job
  (`nixbot_effects/eval.py` `_walk_expr`: "Names are dotted attribute paths
  starting with the onPush job"), so the retention effect's claim is
  `<job>.<effect>`.
- Each effect gets its own checkout; `after` orders but shares nothing.
- Omitting `secretsMap` grants the whole secrets file; an empty map grants none.
- flake-parts cannot merge two `herculesCI` functions, so one module owns it.

## Decisions

### D1 The module owns `herculesCI`; consumers extend through `extra`

The job name (`default`) and the retention effect name are constants of the
module, which makes the claim a constant too. Consumer effects enter as
`extra.onPush.<name>` (merged under the same job) and
`extra.onSchedule.<job>`. A name that collides with a fleet effect or job is a
named failure, not a silent override.

Rejected: consumers writing `herculesCI` and calling exported constructors.
Every consumer would then restate the job and effect names that the cache rule
binds.

### D2 The claim shape is published once, in `lib.nixbotEffects`

`{ retainEffect = "default.cache-retain"; pinNamespace = repo: branch: "<repo>-<branch>"; }`.
The effects module names its pins with `pinNamespace`; the niks3 option binds
`effect` and `pins` with the same values. The server never reads a consumer's
flake: it reads nix-fleet's, which every consumer of the module also uses.
Existing pins keep their names (`nix-homelab-main-<system>`).

### D3 The cache server derives rules from a repository list

`services.niks3-cache.nixbot = { issuer; audience; repositories = attrsOf { branch ? "main"; }; }`
renders provider `nixbot` with one rule per repository bound to
`repository`, `ref = refs/heads/<branch>`, `event = push`, `effect`, scope
`write`, pins `<namespace>-*`. The repository list is consumer policy; the
consumer drives nixbot's `github.repoAllowlist` from the same list, so the two
cannot drift and need no cross-check. JWKS is pinned to
`<issuer>/.well-known/jwks.json`, so the cache does not depend on nixbot being up
at boot.

Pin namespaces are glob prefixes and can overlap (`a-main-*` matches a pin of a
repository named `a-main-x`); the option asserts no namespace's glob matches
another's, naming both repositories.

### D4 Retention runs on every default-branch push, unguarded

No `when.changed`: rerunning the effect is the repair path for a missed
streaming upload, and an unchanged root re-pushes cheaply. The gate is "default
branch, not a tag", read from `primaryRepo`, not the literal `main`. Tag tokens
carry `refs/tags/…` and fail the rule's `ref` anyway.

### D5 The update transaction keeps its credential boundary

`secretsMap.token = { type = "GitToken"; }` only. The script reads the token
and unsets `HERCULES_CI_SECRETS_JSON` before the trusted-but-third-party update
scripts run. The publish helper moves with it as owned runtime code.
`packageUpdates` imports `flakeModules.packageUpdates` and `cacheRetain`
imports `flakeModules.cacheRoot` (dependency by import); both must carry a
module `key` so a consumer that already imports them does not declare options
twice.

### D6 Coordinator inputs are options, not host names

`system` (the coordinator's), `nixPackage`, `niks3Package`, `cacheUrl`,
`writeEndpoint` are typed options with no default where a default would be a
fleet-specific coordinate. Missing values fail with `nixbotEffects: …`.

## Out of scope

- The nixbot service aspect: one instance, mostly homelab integration. Lift the
  generic slice (builders from `lib.buildProfile`, loopback socket, IFD off)
  when a second controller exists.
- A shared "cheap checks" posture: each repository chooses its `checks` set or
  `nixbot.toml` `attribute`.
- Retiring `ciRepositories` or the GHA workflow stack.
- Update adapters (bun etc.): `update-packages` registrations, not effect code.

## Risks

- **Retiring Actions rules too early revokes write.** Mitigation: rules coexist;
  removal is per repository after an observed nixbot main cycle.
- **Upstream renames the dotted effect path.** The claim stops matching and
  retention fails loudly at `niks3 push`; the source reference above is the
  place to check.

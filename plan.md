# nix-fleet plan — remaining and upcoming

Living checklist. Done items are removed, not struck through; decisions and
rationale live in README, AGENTS.md, and docs/contracts/.

## Fleet Contract v2 (decided direction — next major work unit)

Scope per owner decision: the parts of the v2 contract that the CI contract
and fleet topology depend on, functionally self-contained. `fleet.services`
/ omniroute land LATER; host-data harvest lands after the contract settles
(nix-dotfiles' agent can input its own records then).

- [ ] **1. Realization decomposition** (PRIORITY — strong smell today):
      delete `config.fleet.realization` as an architectural API entirely.
      nix-fleet exposes facts + pure renderers; consumers close over their
      own `config.fleet` in their own flake evaluation.
  - `modules/fleet/build-account.nix` — ordinary optional NixOS aspect
    (the `nixbuild` dispatch account is MECHANISM, not policy; keep it
    shared, do not let it become consumer copy-paste). Selected like any
    aspect; `buildUserName` option unchanged.
  - activeSet/machines wiring → consumer's own ~15-line flake-level
    module (resolveBuildProfile → render → nix.settings), documented once
    in docs/contracts/builders.md. That wiring is policy, consumer-owned.
  - No cross-class realization bridge remains. This also structurally
    kills the wrong-import footgun class (no pre-realized module exists
    to mis-import).
- [ ] **2. Capabilities into hosts; single builder registry**:
      `fleet.hosts.<id>.capabilities.nixBuilder = { enable; maxJobs;
supportedFeatures; endpoint.{protocol,user}; }`. Delete host-backed
      `fleet.builders.*`. `system` derives from the host record (capability
      exception only for genuine extra/emulated systems). Keep the
      dedicated `nixbuild` account as the capability endpoint default
      (least-privilege dispatch — NOT `dev`; consumer override possible).
- [ ] **3. `fleet.externalBuilders.<name>`** (narrow, no entity framework):
      uri, systems, publicHostKey, metered. nixbuild moves here.
- [ ] **4. `fleet.buildProfiles.<name>`** replaces builderSets:
      explicit `hosts` + `external` membership, small per-member override
      axis (maxJobs, features) allowed on BOTH variants uniformly
      (nixbuild's maxJobs is the metered-cost knob — profiles exist for
      exactly this). No weights/predicates/inheritance/tags/all-hosts.
- [ ] **5. Two-stage pure resolution API**: hosts/externals + profile →
      normalized `BuilderSpec[]` (`resolveBuildProfile`), then renderers
      (`renderMachinesFile`, `renderSshConfig`, `renderKnownHosts`,
      nix.buildMachines form). Single public API; `packages.<profile>`
      CI bundles keep the same artifact shape (workflow contract
      unchanged: `builder_attr` input, v1+).
- [ ] **6. Trust by projection**: `renderKnownHosts` renders exactly the
      selected hosts/resources — kills the current "inventory membership ⇒
      trusted everywhere" flaw (fixture renders all entries today).
      Pinned keys stay pinned.
- [ ] **7. Mission/README rewrite**: "shared fleet control-plane contract + mechanisms"; remove the stale "no hosts, no policy data" language.
      Keep the canonical-facts vs consumer-local-placement distinction.
- [ ] **8. Contract tests**: profile references exist; members have
      nixBuilder.enable; systems derive correctly; externals have
      URI+key; duplicate canonical/local IDs fail; Nix-module form ≡
      machines-file form.

Not in v2 scope: `fleet.services.*` (omniroute etc. — later wave, only
cross-repo facts qualify); shrub/spectre inventory records (data harvest
after the contract settles; nix-dotfiles' agent can input them itself);
Den/repo-merge/policy-engine (explicitly out).

## Quick wins (pre-v2 value, consumer-adoptable independently)

Ship some of these before v2 so consumers get value that does NOT depend
on the contract change; none conflict with it.

- [x] **`nix-baseline` aspect**: substitution catalog + tuning from
      dotfiles' `nix.nix` (duplicated in homelab's foundation.nix):
      cache.shrublab.xyz substituter + keys, connect-timeouts,
      builders-use-substitutes. Tier-2 shared default; consumers extend
      via the same options. Adoption independent of v2.
- [x] **`ssh` + `mosh` aspects**: openssh baseline (password-auth off,
      openFirewall default) + client multiplexing fragment;
      `clientTuning` toggle. Per-host server policy stays consumer-side.
- [x] **tailscale notify**: tailscaled registers failure (fromPackage);
      autoconnect deliberately unregistered (retry exits are normal).
- [x] **`nix-gc` aspect generalization**: `implementation` switch
      (nh | fast-nix-gc), upstream-first import, ONE notify failure
      registration either way, `noVacuum` option (builders). Remaining:
      live-timing decision + fast-nix-optimise optional service.
- [ ] **Reusable-workflow adoption notes**: consumers call
      `build-push-cache.yml@v1` (tag cut at 0180d5ec) — stub + inputs in
      docs/contracts/ci.md; renovate bumps via tags.
- [ ] **`nix-baseline` adoption in both consumers** so the substituter
      catalog has one owner.

## Adoption (consumers — after v2 lands)

- [ ] **Homelab TD-31**: rebase onto v2 (capabilities-in-hosts + profiles +
      consumer-side wiring; build-account aspect). Paused until v2 core is
      green — avoid adopt-then-migrate.
- [ ] **Dotfiles adoption**: same shape; drop the stale
      `oci-melb-1.system = "x86_64-linux"` from topology (canonical says
      aarch64); topology loses per-machine `system`.

## CI live-run prerequisites (user-side)

- [ ] Set repo variable `FLEET_NIKS3_API_URL` (tailnet API host) + secret
      `FLEET_BUILDER_SSH_KEY`; authorize the key for the `nixbuild`
      account on builders; `FLEET_CI_ON_TAILNET=true` +
      `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_CLIENT_SECRET` (OAuth client with
      writable auth_keys, tag `tag:ci` — or GitHub OIDC audience instead).

## Deferred / future waves

- [ ] **`fleet.services.<name>`**: cross-fleet endpoint facts — omniroute
      first candidate (dotfiles consumes it today). Only facts used across
      the repo boundary; homelab-only services stay in homelab.
- [ ] **shrub/spectre canonical records**: sparse host records + host keys;
      input by the nix-dotfiles agent once the v2 contract settles.
- [ ] **syncthing device IDs**: stays consumer-side (service credentials).
- [ ] **fast-nix-optimise**: optional second service on builders (bundled
      with nix-gc work).

# nix-fleet plan — remaining and upcoming

Living checklist of work known at the time of writing. Done items are
removed, not struck through; decisions and rationale live in README,
AGENTS.md, and docs/contracts/.

## Immediate (consumer-blocking)

- [ ] **Homelab adoption of the fleet feature** (TD-31): import
      `flakeModules.fleet` at flake level, host records derive
      system/tailscale hostname from `fleet.hosts.<id>` (join key = hostId),
      compositions import `config.fleet.realization`, `activeSet` selects a
      set; delete the hand-rolled builder machinery and nixbuild token
      secret. Homelab agent is on it.
- [ ] **Dotfiles adoption**: same shape; drop the stale
      `oci-melb-1.system = "x86_64-linux"` from topology (canonical says
      aarch64); topology loses per-machine `system`.
- [ ] **Throwing-shim removal**: once both consumers have migrated,
      delete `modules/access/builder-access.nix` (the transitional shim) and
      its README mention.

## Wave 3 — mechanism extraction (nix baseline + ssh)

- [ ] **`nix-baseline` aspect**: substitution catalog + tuning from
      dotfiles' `nix.nix` `substitutionSettings` (duplicated identically in
      homelab's foundation.nix): `cache.shrublab.xyz`, nix-community/numtide
      keys, connect-timeouts, `builders-use-substitutes`. Tier-2 shared
      default; consumers add extras via the same options. (~1h incl. parity)
- [ ] **`ssh` server aspect**: openssh baseline (password-auth off,
      openFirewall) + the `ssh_config.d` client tuning block from
      dotfiles' `ssh.nix`. Peer-alias rendering is redundant with the trust
      seam; per-host server policy stays consumer-side.
- [ ] **`mosh`**: 17 lines; extract bundled with the ssh work.

## CI / fleet tooling

- [ ] **Reusable-workflow conversion** (decided direction): promote
      `.github/templates/build-push-cache.yml` to `workflow_call` with
      inputs (`builder_set`, `cache_url`, `targets`, `ssh_key_secret`);
      consumers keep a stub. Keep templates as the readable contract.
      (~45 min; first live run will still need adjustment — see caveats in
      docs/contracts/ci.md)
- [ ] **First live run of build-push-cache**: x86_64 coordinator
      assumption, trusted-user path, SSH key naming/authorization — all
      listed in docs/contracts/ci.md "First-live-run caveats".
- [ ] **`nix-baseline` adoption in both consumers** so the substituter
      catalog has one owner.

## Deferred / future waves

- [ ] **`fleet.services.<name>`** (wave-4): cross-fleet service endpoint
      map — today dotfiles' `topology.services` (omniroute, database, niks3,
      ntfy hosts). Only when a second consumer needs one of them.
- [ ] **syncthing device IDs**: stays consumer-side (service
      credentials, not identity); revisit if a second sync consumer appears.
- [ ] **`nh-gc` retention**: dotfiles' HM user-timer (genericLinux) is
      the only remaining separate GC owner; fine as is.
- [ ] **aarch64 CI coordinator**: template assumes x86_64 for the
      `nix build .#packages.x86_64-linux.ci` step; parameterize when an arm
      coordinator is actually used.

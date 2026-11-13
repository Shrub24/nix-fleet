# Tasks

## 1. Library and module

- [x] 1.1 Add the `nixbot` flake input (follows `nixpkgs`, `treefmt-nix`)
- [x] 1.2 `lib/nixbot-effects.nix` → `flake.lib.nixbotEffects`
      (`retainEffect`, `pinNamespace`)
- [x] 1.3 `flakeModules.nixbotEffects`: options (D6), `herculesCI` rendering
      (D1), `cacheRetain` (D4), `packageUpdates` with the publish helper (D5),
      `extra` with collision failure; keyed imports of `packageUpdates` and
      `cacheRoot`
- [x] 1.4 Move homelab's `cache-retain` and `package-updates` contract tests
      (push-before-pin, hidden push failure, nothing-to-publish, credential
      unset before the batch) and the publish-helper test; parameterise over the
      module's options

## 2. Cache trust

- [x] 2.1 `services.niks3-cache.nixbot` (D3) rendering provider `nixbot` from
      `lib.nixbotEffects`; named overlap assertion

## 3. Validation

- [x] 3.1 `nix flake check`, `nix fmt` clean

## 4. Consumers (each its own change, tracked here)

- [ ] 4.1 nix-homelab adopts the module and the repository list; pins unchanged;
      one observed main cycle and one scheduled update
- [ ] 4.2 nix-fleet consumes its own module: `autoMerge = true`, decide its
      `checks` set for PR builds
- [ ] 4.3 Per repository, after its first observed nixbot main cycle: remove its
      Actions rules from `ciRepositories`

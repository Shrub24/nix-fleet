# nixbot effects

`flakeModules.nixbotEffects` gives a repository built by the fleet's nixbot
controller its effects, and `services.niks3-cache.nixbot` gives the cache the
matching trust rules. Both read `lib.nixbotEffects`, so the effect name the
token carries and the pins it may move are defined once.

## Consumer

```nix
{ inputs, ... }:
{
  imports = [ inputs.nix-fleet.flakeModules.nixbotEffects ];
  nixbotEffects = {
    system = "x86_64-linux"; # the controller's
    nixPackage = <controller's nix.package>;
    cacheRetain = {
      enable = true;
      cacheUrl = "https://cache.example";
      writeEndpoint = "https://niks3-write.example";
    };
    packageUpdates = {
      enable = true;
      when = { minute = 43; hour = [ 4 ]; dayOfWeek = [ "Mon" ]; };
      autoMerge = false;
    };
    extra.onPush = { primaryRepo, ... }: { };
    extra.onSchedule = { primaryRepo, ... }: { };
  };
}
```

The module owns `herculesCI`; a repository must not define it as well. It imports
`flakeModules.cacheRoot` and `flakeModules.packageUpdates`.

| Effect                           | Runs                                            | Credential                                                 | Does                                                                                                                             |
| -------------------------------- | ----------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `default.cache-retain`           | every push to `cacheRetain.branch`, never a tag | workload identity, audience `cacheUrl`; `secretsMap = { }` | per system: `niks3 push` the `cache-root`, move pin `<repo>-<branch>-<system>`, fail unless the root substitutes from `cacheUrl` |
| `package-updates` (`onSchedule`) | `packageUpdates.when`                           | `GitToken` only, unset before the batch runs               | `update-packages --refresh-inputs`; if the tree changed, push `packageUpdates.branch` and open or update one pull request        |

Retention has no changed-only guard: rerunning it is how a missed streaming upload
is repaired. Consumer effects or schedule jobs named like the fleet's fail
evaluation.

## Cache

```nix
services.niks3-cache.nixbot = {
  issuer = "https://nixbot.example"; # the instance that mints effect tokens
  repositories."owner/repo" = { }; # branch defaults to "main"
};
```

Each repository gets one rule: `repository`, `ref = refs/heads/<branch>`,
`event = push`, `effect = default.cache-retain`, scope `write`, pins
`<repo>-<branch>-*`. Keys are fetched from `<issuer>/.well-known/jwks.json`
without discovery. Overlapping pin namespaces, a missing issuer, or a
hand-written `oidc.providers.nixbot` fail evaluation. Drive nixbot's
`github.repoAllowlist` from the same repository list.

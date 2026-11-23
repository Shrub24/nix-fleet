# `flakeModules.ci` options

Generated from the option declarations by `nix run .#write-ci-reference`; do not edit.

## ci\.effects\.onPush

Effects under the `default` onPush job, each a function of
`{ primaryRepo, pkgs, effects, perSystem, ... }` returning an effect or
null (not this push)\.

_Type:_
attribute set of function that evaluates to a(n) (null or raw value)

_Default:_

```nix
{ }
```

_Declared by:_

- [modules/ci/effects\.nix](../../modules/ci/effects.nix)

## ci\.effects\.onSchedule

Schedule jobs, each a function of the same arguments returning `{ when; outputs.effects; }` or null\.

_Type:_
attribute set of function that evaluates to a(n) (null or raw value)

_Default:_

```nix
{ }
```

_Declared by:_

- [modules/ci/effects\.nix](../../modules/ci/effects.nix)

## ci\.instance

The fleet’s nixbot instance, resolved from nix-fleet’s canonical inventory\.

_Type:_
submodule

_Default:_

```nix
nix-fleet's lib.ci.instance
```

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.instance\.appId

The nixbot GitHub App’s id\.

_Type:_
positive integer, meaning >0

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.instance\.cacheUrl

Public read URL of the cache; also the token audience\.

_Type:_
string

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.instance\.nixbotUrl

The controller’s public URL\.

_Type:_
string

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.instance\.system

System the controller evaluates and runs effects on\.

_Type:_
string

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.instance\.writeEndpoint

niks3 server URL effects push and pin through\.

_Type:_
string

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.niks3Package

niks3 client used to push and pin\.

_Type:_
package

_Default:_
nix-fleet’s niks3 input

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.nixPackage

Nix CLI the effects call\.

_Type:_
package

_Default:_
nix-fleet’s nixpkgs `nix` for the instance system

_Declared by:_

- [modules/ci/instance\.nix](../../modules/ci/instance.nix)

## ci\.retention\.enable

Whether to enable cache retention of the default branch’s roots\.

_Type:_
boolean

_Default:_

```nix
true
```

_Example:_

```nix
true
```

_Declared by:_

- [modules/ci/retention\.nix](../../modules/ci/retention.nix)

## ci\.retention\.branch

Branch whose pushes are retained; must match the cache’s rule for this repository\.

_Type:_
string

_Default:_

```nix
"main"
```

_Declared by:_

- [modules/ci/retention\.nix](../../modules/ci/retention.nix)

## ci\.retention\.generations

Earlier roots kept as `<pin>-1` … `<pin>-<n>` behind the rolling pin\.

_Type:_
unsigned integer, meaning >=0

_Default:_

```nix
0
```

_Declared by:_

- [modules/ci/retention\.nix](../../modules/ci/retention.nix)

## ci\.retention\.releases

Whether to enable a pin per pushed tag, `<name>-release-<tag>-<system>`\.

_Type:_
boolean

_Default:_

```nix
true
```

_Example:_

```nix
true
```

_Declared by:_

- [modules/ci/retention\.nix](../../modules/ci/retention.nix)

## ci\.retention\.systems

Systems whose `cache-root` is pushed and pinned\.

_Type:_
list of string

_Default:_

```nix
config.systems
```

_Declared by:_

- [modules/ci/retention\.nix](../../modules/ci/retention.nix)

## ci\.updates\.enable

Whether to enable the scheduled update transaction\.

_Type:_
boolean

_Default:_

```nix
true
```

_Example:_

```nix
true
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.packages

`packages.<system>` outputs this repository owns and updates, each through
nix-update and its own `passthru.updateScript`\. A package family with
shared pins has exactly one registered owner\. Register a package in the
file that defines it\.

_Type:_
attribute set of (submodule)

_Default:_

```nix
{ }
```

_Example:_

```nix
{ bifrost = { }; }
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.packages\.\<name>\.paths

Repository-relative paths the updater may change, replacing the
default `pkgs/<name>`\. A shared path needs a `reason`\.

_Type:_
list of string

_Default:_

```nix
[ ]
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.packages\.\<name>\.reason

Why the paths belong to this updater; refused by name when `paths` is set without one\.

_Type:_
null or string

_Default:_

```nix
null
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.autoMerge

Request auto-merge on the update pull request\.

_Type:_
boolean

_Default:_

```nix
false
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.branch

Branch the update is pushed to\.

_Type:_
string

_Default:_

```nix
"automation/package-updates"
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.commands

Updates that are neither a package nor an input, keyed by name: a generated
file, a vendored artefact\. Each runs in the same transaction\.

_Type:_
attribute set of (submodule)

_Default:_

```nix
{ }
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.commands\.\<name>\.paths

Repository-relative paths the command may change\.

_Type:_
non-empty (list of string)

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.commands\.\<name>\.program

Given `{ pkgs, system }`, the executable run from the checkout root;
it may edit only `paths`\.

_Type:_
function that evaluates to a(n) string

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.identity\.email

Author email the effect’s commits carry\.

_Type:_
string

_Default:_

```nix
"nixbot@users.noreply.github.com"
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.identity\.name

Author name the effect’s commits carry\.

_Type:_
string

_Default:_

```nix
"nixbot"
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.lockfiles

Ecosystem lockfiles refreshed in the transaction, each as a command\.

_Type:_
attribute set of (submodule)

_Default:_

```nix
{ }
```

_Example:_

```nix
{
  cargo = {
    ecosystem = "cargo";
  };
  web = {
    directory = "web";
    ecosystem = "bun";
  };
}
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.lockfiles\.\<name>\.directory

Repository-relative directory holding the manifest\.

_Type:_
string

_Default:_

```nix
"."
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.lockfiles\.\<name>\.ecosystem

Which ecosystem’s lockfile to refresh within its declared ranges\.

_Type:_
one of “bun”, “cargo”, “npm”

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.title

Commit and pull request title\.

_Type:_
string

_Default:_

```nix
"chore(deps): Refresh flake inputs and package pins"
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## ci\.updates\.when

nixbot `onSchedule` `when` for the update run\.

_Type:_
attribute set of raw value

_Default:_

```nix
{
  dayOfWeek = [
    "Mon"
    "Thu"
  ];
  hour = [
    7
  ];
  minute = 43;
}
```

_Declared by:_

- [modules/ci/updates\.nix](../../modules/ci/updates.nix)

## flake-file\.inputs\.\<name>\.update

How the scheduled update moves this input (`flakeModules.ci`)\.

_Type:_
submodule

_Default:_

```nix
{ }
```

_Declared by:_

- [modules/ci/inputs\.nix](../../modules/ci/inputs.nix)

## flake-file\.inputs\.\<name>\.update\.reason

Why the input is `fixed`; required for `fixed`\.

_Type:_
null or string

_Default:_

```nix
null
```

_Declared by:_

- [modules/ci/inputs\.nix](../../modules/ci/inputs.nix)

## flake-file\.inputs\.\<name>\.update\.version

How the scheduled update moves this input\. `stable` follows the
repository’s latest release, else its highest release tag of the same
prefix; `unstable` admits pre-releases; `branch` moves the lock to the
ref’s current head; `fixed` never moves on schedule\. `null` derives
the policy from the locked ref: a tag is `stable`, a branch or no ref
is `branch`, a `rev` is `fixed`\.

_Type:_
null or one of “stable”, “unstable”, “branch”, “fixed”

_Default:_

```nix
null
```

_Declared by:_

- [modules/ci/inputs\.nix](../../modules/ci/inputs.nix)

## flake-file\.inputs\.\<name>\.update\.versionRegex

Only tags this matches are candidates, and its one capture group is the
version compared — nix-update’s `--version-regex`\. Holds a release
line, or picks one product of a repository that tags several\.

_Type:_
null or string

_Default:_

```nix
null
```

_Example:_

```nix
"v(5\\..*)"
```

_Declared by:_

- [modules/ci/inputs\.nix](../../modules/ci/inputs.nix)

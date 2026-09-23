# Flake input declarations

Composition policy for consumers that generate `flake.nix` with
`denful/flake-file`, and for this repository's own flake.

This is policy, not a fleet surface: nothing here is a `fleet.*` option. It
sits with the contracts because the audience is the same — repositories that
compose against nix-fleet.

Verified against the `flake-file` revision pinned at the time of writing. The
two code paths quoted below are `dev/modules/_lib/default.nix`
(`mergeNestedAutoFollows`, `collectAutoFollowIgnores`) and
`modules/write-flake.nix`; re-read them before relying on the details.

## Policy

**Do not import `flake-file.flakeModules.auto-follow`.** Declare every nested
`follows` beside the input it redirects, in the module that owns that input:

```nix
flake-file.inputs.home-manager = {
  url = "github:nix-community/home-manager/master";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

An input whose upstream builds against its own pin declares no follows, and
says so in a comment above its declaration.

## Why

With auto-follow enabled, `mergeNestedAutoFollows` **deletes** any `follows` a
module declares. `autoFollow` defaults to `true`, so the deletion applies to
every nested input:

```nix
value =
  (removeAttrs exprInput ([ "inputs" ] ++ lib.optional automaticallyManaged "follows"))
  // preservedFollow
```

What survives instead is `preservedFollow`, which is read back from **the
previously generated `flake.nix`**:

```nix
existingInputs =
  if auto-follow.enable then (import "${top.inputs.self}/flake.nix").inputs or { } else { };
```

So the generated file is a function of _(module tree, previous generated file)_
rather than of the tree. A follows that flake-edit declines to add — it declines
some, for example when a nested input's own children follow that input's
nixpkgs — can then only be stated by editing the generated file, which carries a
`DO-NOT-EDIT` header. Nothing detects that, because `check-flake-file` renders
from the same `existingInputs` and so validates the edit against itself.

The documented escape hatch is closed too: `autoFollow = false` throws when
combined with a `follows`, so it cannot be used to freeze one.

## What declaring follows buys

- The generated file is a pure function of the module tree.
- `check-flake-file` becomes a real check. With auto-follow off, flake-file
  skips the flake-edit step and simply diffs the checked-in file against the
  render — so a hand-edit to `flake.nix` now fails the gate.
- `write-flake` stops running `nix flake lock`, because that call lives inside
  the auto-follow branch. Regenerating the file can no longer move an input
  revision as a side effect.

## Applying a follows

With auto-follow off, declaring a follows no longer updates the lock for you.
The sequence is:

```sh
nix run .#write-flake   # render flake.nix
nix flake lock          # resolve the new follows into flake.lock
```

Nothing enforces the second step, though any subsequent `nix` command that
writes the lock will do it implicitly — a build that needs an unresolvable
input will fail rather than silently diverge.

Check the nested input exists before declaring a follows. `ipetkov/crane`, for
instance, declares `inputs = { }` and has no nested `nixpkgs` at all; a follows
on it renders fine but every subsequent `write-flake` prints
`input 'crane' has an override for a non-existent input 'nixpkgs'`.

## What it costs

One line per input that redirects a nested input. The check does **not** catch
a missing follows: adding an input and regenerating yields a follows-less
declaration, and the file and the render agree. The bookkeeping is manual.

## Precedent

`Shrub24/nix-dotfiles` made this switch with 12 declared follows and no change
in resolution: 63 lock nodes before and after, identical node set.

## Upstream

Worth raising with `denful/flake-file`. Two candidate fixes, either of which
restores the declarative path:

1. Do not strip a declared `follows` — let the declared value win, and have
   flake-edit manage only the nested inputs the tree does not mention.
2. Drop the `autoFollow = false` + `follows` throw. The two are not
   contradictory; they mean "I own this one", and flake-edit already skips
   ignored paths.

#!/usr/bin/env bash
# Regenerate the flake and its lock, as the update-candidate pipeline and the
# human-pull-request consistency check both need.
#
#   prepare-candidate.sh           commit any regeneration as one child commit
#   prepare-candidate.sh --check   fail, writing no commit, when the tree is not
#                                  already exactly what regeneration produces
#
# `write-flake` renders flake.nix from the declared inputs. `nix flake lock`
# without an update adds lock entries for declarations that have none and moves
# nothing that is already locked, so a candidate's pins are the ones its
# producer chose.
set -euo pipefail

mode=commit
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  *)
    echo "usage: prepare-candidate.sh [--check]" >&2
    exit 2
    ;;
esac

nix run .#write-flake
nix flake lock

# Preparation owns exactly the two files the writers above produce: flake.nix is
# rendered by write-flake and flake.lock by `nix flake lock`. Anything else that
# moved during regeneration is refused rather than committed, so a generator or a
# stray edit cannot be absorbed into the preparation commit.
changed=$(git status --porcelain | cut -c4-)
if [ -z "$changed" ]; then
  echo "prepare-candidate: generated files are current"
  exit 0
fi

unexpected=$(printf '%s\n' "$changed" | grep -v -e '^flake\.nix$' -e '^flake\.lock$' || true)
if [ -n "$unexpected" ]; then
  echo "::error::regeneration changed files preparation does not own:"
  printf '%s\n' "$unexpected"
  exit 1
fi

if [ "$mode" = check ]; then
  echo "::error::generated flake or lock is stale: run 'nix run .#write-flake' and 'nix flake lock', then commit the result"
  git --no-pager diff --stat
  exit 1
fi

git add -- flake.nix flake.lock
git commit --quiet -m "chore: prepare generated flake and lock"
echo "prepare-candidate: committed $(git rev-parse --short HEAD)"

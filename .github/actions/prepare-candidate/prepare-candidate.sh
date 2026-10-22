#!/usr/bin/env bash
# Regenerate flake.nix and flake.lock; --check refuses changes without committing.
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

# Regeneration may change only flake.nix and flake.lock.
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

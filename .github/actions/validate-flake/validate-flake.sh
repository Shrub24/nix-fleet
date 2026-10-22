#!/usr/bin/env bash
# Evaluates a flake's outputs on all systems without building its checks.
set -euo pipefail

target=${1:-.}
here=$(cd -- "$(dirname -- "$0")" && pwd)

prime() {
  local prefetch source nar_hash
  prefetch=$(nix flake prefetch --json --no-write-lock-file "$target") || return 1
  source=$(jq -er .storePath <<<"$prefetch") || return 1
  nar_hash=$(jq -er .hash <<<"$prefetch") || return 1
  nix eval --no-write-lock-file --option allow-import-from-derivation false \
    --expr "builtins.getFlake \"path:$source?narHash=$nar_hash\"" \
    --apply "$(cat "$here/prime.nix")"
}

prime || echo "::warning::validate-flake: priming evaluation failed; the check below is the verdict"

nix flake check --no-build --no-write-lock-file --all-systems \
  --option allow-import-from-derivation false "$target"

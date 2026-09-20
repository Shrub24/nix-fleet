set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Format all non-excluded files across the repo
fmt:
    nix fmt

# Check formatting without modifying files
fmt-check:
    nix build --no-link .#checks.x86_64-linux.treefmt

# Evaluate the fixture class and all published checks
check:
    nix flake check

# Update flake.lock (also runs on pre-commit via lefthook)
lock:
    nix flake lock

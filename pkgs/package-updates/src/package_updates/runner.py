"""Validate a registered package selection and drive the shared updater.

The runner owns selection, deterministic ordering and fail-fast reporting.
Package-specific update policy stays in each package expression: nix-update's
``--use-update-script`` runs a package's ``passthru.updateScript`` when it
declares one and its ordinary release discovery otherwise, so the batch never
guesses a custom source layout.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


class UpdateError(Exception):
    """A named refusal. Nothing has been run when this is raised."""


@dataclass(frozen=True)
class Registry:
    """The selected repository's own update registry, baked by its app."""

    system: str
    registered: tuple[str, ...]
    available: tuple[str, ...]


def load_registry(environ=os.environ) -> Registry:
    path = environ.get("PACKAGE_UPDATES_REGISTRY")
    if not path:
        raise UpdateError(
            "PACKAGE_UPDATES_REGISTRY is not set; "
            "run update-packages through the module's app"
        )
    try:
        data = json.loads(Path(path).read_text())
    except OSError as error:
        raise UpdateError(f"cannot read registry {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise UpdateError(f"registry {path} is not valid JSON: {error}") from error
    return Registry(
        system=data["system"],
        registered=tuple(data["registered"]),
        available=tuple(data["available"]),
    )


def select(registry: Registry, requested: list[str]) -> list[str]:
    """Return the effective selection in lexical order, or refuse by name.

    The whole selection is validated before any updater runs: an empty,
    duplicate, unregistered or output-less selection must never reach the
    update loop.
    """
    if not registry.registered:
        raise UpdateError("nothing registered; set perSystem.packageUpdates.packages")
    selection = requested or list(registry.registered)
    if not selection:
        raise UpdateError("empty selection")
    duplicates = sorted({name for name in selection if selection.count(name) > 1})
    if duplicates:
        raise UpdateError(f"duplicate selection: {', '.join(duplicates)}")
    unknown = sorted(set(selection) - set(registry.registered))
    if unknown:
        raise UpdateError(f"not registered: {', '.join(unknown)}")
    missing = sorted(set(selection) - set(registry.available))
    if missing:
        raise UpdateError(
            f"registered but no packages.{registry.system} output: {', '.join(missing)}"
        )
    return sorted(selection)


def update(names: list[str], system: str) -> int:
    """Run the shared updater over ``names``, stopping at the first failure.

    The child inherits this process's environment, so a package update
    script's recorded-target variables flow through unchanged. The runner
    never commits, resets or publishes; earlier edits stay inspectable.
    """
    executable = shutil.which("nix-update")
    if executable is None:
        raise UpdateError("nix-update not found on PATH")
    for name in names:
        print(f"package-updates: updating {name}", flush=True)
        result = subprocess.run(
            [executable, "--flake", "--use-update-script", "--system", system, name]
        )
        if result.returncode != 0:
            print(
                f"package-updates: {name}: update failed (exit {result.returncode})",
                file=sys.stderr,
                flush=True,
            )
            return result.returncode
    return 0
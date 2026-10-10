"""Validate a registered package selection and drive the shared updater.

The runner owns selection, deterministic ordering and fail-fast reporting.
Package-specific update policy stays in each package expression: nix-update's
``--use-update-script`` runs a package's ``passthru.updateScript`` when it
declares one and its ordinary release discovery otherwise, so the batch never
guesses a custom source layout.

Each package's before and after version, its changelog link and whether the
working copy moved are read from outside the updater, so the report never
parses nix-update's own output.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .report import (
    FAILED,
    UNCHANGED,
    UPDATED,
    Entry,
    Report,
    bullet,
    classify,
    failure,
)

# One eval per package per phase reads both fields, so a package without
# meta.changelog still reports its version.
_EVAL = "p: { version = p.version or null; changelog = p.meta.changelog or null; }"


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


def evaluate(name: str, system: str) -> tuple[str | None, str | None]:
    """Read a package's evaluated version and changelog, or nulls.

    nix-update's own output is not a stable interface, so the report reads the
    flake instead. A pin that does not evaluate must still be updatable: a
    missing or failing tool is unknown here, never fatal.
    """
    executable = shutil.which("nix")
    if executable is None:
        return None, None
    result = subprocess.run(
        [
            executable,
            "eval",
            "--json",
            # The report never writes the consumer's lock file.
            "--no-write-lock-file",
            "--apply",
            _EVAL,
            f".#packages.{system}.{name}",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None, None
    try:
        evaluated = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, None
    if not isinstance(evaluated, dict):
        return None, None
    return evaluated.get("version"), evaluated.get("changelog")


def changed_paths() -> frozenset[str] | None:
    """The working copy's changed paths, or None where git cannot answer.

    Absent git and a directory outside a work tree both mean unknown: the
    batch then falls back to the version signal alone rather than failing.
    """
    executable = shutil.which("git")
    if executable is None:
        return None
    result = subprocess.run(
        [executable, "status", "--porcelain", "--untracked-files=all"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    # Porcelain v1 is "XY<space>PATH"; the path is what a refresh can move.
    return frozenset(line[3:] for line in result.stdout.splitlines() if len(line) > 3)


def save(batch: Report, json_path: str | None, markdown_path: str | None) -> None:
    """Write the requested report artifacts, or refuse by name."""
    for path, text in (
        (json_path, batch.json_text()),
        (markdown_path, batch.markdown_text()),
    ):
        if path is None:
            continue
        try:
            Path(path).write_text(text, encoding="utf-8")
        except OSError as error:
            raise UpdateError(f"cannot write report {path}: {error}") from error


def update(
    names: list[str],
    system: str,
    json_path: str | None = None,
    markdown_path: str | None = None,
) -> int:
    """Run the shared updater over ``names``, stopping at the first failure.

    The child inherits this process's environment, so a package update
    script's recorded-target variables flow through unchanged. The runner
    never commits, resets or publishes; earlier edits stay inspectable, and
    the requested reports are written even when a package fails.
    """
    executable = shutil.which("nix-update")
    if executable is None:
        raise UpdateError("nix-update not found on PATH")
    entries: list[Entry] = []
    exit_code = 0
    for name in names:
        print(f"package-updates: updating {name}", flush=True)
        before, changelog_before = evaluate(name, system)
        paths_before = changed_paths()
        result = subprocess.run(
            [executable, "--flake", "--use-update-script", "--system", system, name]
        )
        after, changelog_after = evaluate(name, system)
        paths_after = changed_paths()
        # A version can stay put while the pin still moves, so either signal
        # decides that a refresh happened.
        moved = before != after or (
            paths_before is not None
            and paths_after is not None
            and paths_before != paths_after
        )
        if result.returncode != 0:
            status = FAILED
        elif moved:
            status = UPDATED
        else:
            status = UNCHANGED
        template = changelog_after if changelog_after is not None else changelog_before
        entry = Entry(
            name=name,
            status=status,
            before=before,
            after=after,
            change=classify(before, after),
            changelog=template,
        )
        entries.append(entry)
        if result.returncode != 0:
            print(failure(name, result.returncode), flush=True)
            exit_code = result.returncode
            break
        print(bullet(entry), flush=True)
    batch = Report(system=system, entries=tuple(entries))
    print(flush=True)
    print(batch.summary(), flush=True)
    save(batch, json_path, markdown_path)
    return exit_code
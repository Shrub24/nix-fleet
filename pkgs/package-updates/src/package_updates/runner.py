"""Refresh flake inputs, then run each package update as a local file transaction.

The runner owns selection, deterministic ordering and per-package reporting.
Package-specific update policy stays in each package expression: nix-update's
``--use-update-script`` runs a package's ``passthru.updateScript`` when it
declares one and its ordinary release discovery otherwise, so the batch never
guesses a custom source layout.

The flake lock refresh runs first and changes the working copy, so every
package updater is staged on top of the refreshed lock. Each package's before
version is read before the refresh, so a version that moved only because the
lock moved is reported against the pin it started from. Each package's before
and after version, its changelog link and whether the working copy moved are
read from outside the updater, so the report never parses nix-update's output.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import flake_update
from .flake_update import FlakeUpdateError
from .report import (
    ABORTED,
    COMPLETE,
    FAILED,
    PARTIAL,
    UNCHANGED,
    UPDATED,
    Entry,
    InputEntry,
    Report,
    bullet,
    classify,
    failure,
    input_bullet,
)
from .transaction import AdoptionError, TransactionError, repository_root, staged_package

# The batch's process contract, one entry per Report outcome.
EXIT_CODES = {COMPLETE: 0, PARTIAL: 1, ABORTED: 2}

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
    write_sets: dict[str, tuple[str, ...]]
    root: str
    package_paths: dict[str, str]
    deferred_inputs: dict[str, str] = field(default_factory=dict)


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

    write_sets = {}
    for name, entry in data.get("writeSets", {}).items():
        if not str(entry.get("reason", "")).strip():
            raise UpdateError(f"write set for '{name}' needs a non-empty reason")
        write_sets[name] = tuple(entry["paths"])

    deferred = dict(data.get("deferredInputs", {}))
    for name, reason in deferred.items():
        if not str(reason).strip():
            raise UpdateError(f"deferred input '{name}' needs a non-empty reason")

    return Registry(
        system=data["system"],
        registered=tuple(data["registered"]),
        available=tuple(data["available"]),
        write_sets=write_sets,
        root=data.get("root", "."),
        package_paths=data.get("packagePaths", {}),
        deferred_inputs=deferred,
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


def select_inputs(available: list[str], deferred: dict[str, str], requested: list[str]) -> list[str]:
    """Return the flake inputs to refresh, or refuse by name.

    An explicit request overrides deferral: that is how a deferred input is
    moved once its upstream is fixed. A deferral that names no input is stale
    configuration and is refused rather than ignored.
    """
    stale = sorted(set(deferred) - set(available))
    if stale:
        raise UpdateError(f"deferred input is not a flake input: {', '.join(stale)}")
    if requested:
        unknown = sorted(set(requested) - set(available))
        if unknown:
            raise UpdateError(f"not a flake input: {', '.join(unknown)}")
        return sorted(set(requested))
    return [name for name in sorted(available) if name not in deferred]


def lock_refresh(requested_inputs: list[str], refresh_all: bool) -> list[str] | None:
    """Decide which inputs a run refreshes: None means the lock is left alone.

    Explicit inputs refresh exactly those; ``refresh_all`` refreshes every input
    not deferred. Package-only runs never touch the lock.
    """
    if requested_inputs:
        return list(requested_inputs)
    if refresh_all:
        return []
    return None


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


def _refresh(
    requested: list[str], deferred: dict[str, str], root: Path
) -> tuple[list[InputEntry], str | None]:
    """Refresh the selected inputs; return what moved or the named failure.

    An empty selection is skipped rather than passed on: ``nix flake update``
    with no names would move every input, deferred ones included.
    """
    try:
        available = list(flake_update.top_level_nodes(flake_update.read_lock(root)))
        wanted = select_inputs(available, deferred, requested)
        if not wanted:
            return [], None
        moved = flake_update.apply(wanted, root)
    except (UpdateError, FlakeUpdateError) as error:
        return [], str(error)
    return [
        InputEntry(
            name=change.name,
            before=change.before,
            after=change.after,
            date=change.date,
            source=change.source,
            compare=flake_update.compare_url(change),
        )
        for change in moved
    ], None


def update(
    names: list[str],
    system: str,
    json_path: str | None = None,
    markdown_path: str | None = None,
    write_sets: dict[str, tuple[str, ...]] | None = None,
    package_paths: dict[str, str] | None = None,
    root_path: str | None = None,
    inputs: list[str] | None = None,
    deferred_inputs: dict[str, str] | None = None,
) -> int:
    """Refresh the lock when asked, then run selected updaters in jj workspaces.

    ``inputs`` None refreshes nothing; a list refreshes exactly those names
    (empty meaning every input not deferred). The child inherits this process's
    environment, so package-specific target variables flow through unchanged.
    Successful package diffs are applied in sequence; failed candidates are
    discarded and later packages still run.
    """
    executable = shutil.which("nix-update")
    if executable is None:
        raise UpdateError("nix-update not found on PATH")
    root = Path(root_path).resolve() if root_path else repository_root()
    write_sets = write_sets or {}
    package_paths = package_paths or {}
    before_versions = {name: evaluate(name, system) for name in names}

    aborted = False
    input_entries: list[InputEntry] = []
    input_failure = None
    if inputs is not None:
        input_entries, input_failure = _refresh(inputs, deferred_inputs or {}, root)
        if input_failure is not None:
            print(f"✗ Failed flake inputs: {input_failure}", flush=True)
        for entry in input_entries:
            print(input_bullet(entry), flush=True)
        print(f"flake inputs: {len(input_entries)} moved", flush=True)

    entries: list[Entry] = []
    for name in names:
        print(f"package-updates: updating {name}", flush=True)
        before, changelog_before = before_versions[name]
        write_set = tuple(write_sets.get(name, ())) or (
            package_paths.get(name, f"pkgs/{name}"),
        )
        try:
            result, paths = staged_package(
                root,
                name,
                write_set,
                lambda candidate: subprocess.run(
                    [executable, "--flake", "--use-update-script", "--system", system, name],
                    cwd=candidate,
                    capture_output=True,
                    text=True,
                    env=os.environ.copy(),
                ),
            )
            after, changelog_after = evaluate(name, system)
            moved = before != after or bool(paths)
            status = FAILED if result.returncode != 0 else UPDATED if moved else UNCHANGED
            if result.returncode != 0:
                reason = (result.stderr or result.stdout).strip()
                print(failure(name, result.returncode) + (f": {reason}" if reason else ""), flush=True)
            else:
                print(
                    bullet(
                        Entry(
                            name,
                            status,
                            before,
                            after,
                            classify(before, after),
                            changelog_after or changelog_before,
                        )
                    ),
                    flush=True,
                )
            entry = Entry(
                name=name,
                status=status,
                before=before,
                after=after,
                change=classify(before, after),
                changelog=changelog_after if changelog_after is not None else changelog_before,
            )
        except (TransactionError, OSError) as error:
            entry = Entry(
                name=name,
                status=FAILED,
                before=before,
                after=before,
                change=classify(before, before),
                changelog=changelog_before,
            )
            print(failure(name, 1) + f": {error}", flush=True)
            # A part-adopted tree is nobody's candidate: stop rather than stack
            # another package's changes on top of it.
            aborted = isinstance(error, AdoptionError)
        entries.append(entry)
        if aborted:
            break
    batch = Report(
        system=system,
        entries=tuple(entries),
        inputs=tuple(input_entries),
        input_failure=input_failure,
        aborted=aborted,
    )
    print(flush=True)
    print(batch.summary(), flush=True)
    save(batch, json_path, markdown_path)
    return EXIT_CODES[batch.outcome]

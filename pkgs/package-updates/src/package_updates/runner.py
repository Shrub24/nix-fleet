"""Validate package selection and run each update as a local file transaction.

The runner owns selection, deterministic ordering and per-package reporting.
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

from .transaction import TransactionError, repository_root, staged_package
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
    write_sets: dict[str, tuple[str, ...]]
    root: str
    package_paths: dict[str, str]


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
        write_sets={name: tuple(paths) for name, paths in data.get("writeSets", {}).items()},
        root=data.get("root", "."),
        package_paths=data.get("packagePaths", {}),
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


def _changed_paths(root: Path, write_set: tuple[str, ...]) -> bool:
    from .transaction import _diff_paths

    return any(
        path == prefix or path.startswith(prefix.rstrip("/") + "/")
        for path in _diff_paths(root)
        for prefix in write_set
    )


def update(
    names: list[str],
    system: str,
    json_path: str | None = None,
    markdown_path: str | None = None,
    write_sets: dict[str, tuple[str, ...]] | None = None,
    package_paths: dict[str, str] | None = None,
    root_path: str | None = None,
) -> int:
    """Run selected updaters in disposable jj workspaces.

    The child inherits this process's environment, so package-specific target
    variables flow through unchanged. Successful package diffs are applied in
    sequence; failed candidates are discarded and later packages still run.
    """
    executable = shutil.which("nix-update")
    if executable is None:
        raise UpdateError("nix-update not found on PATH")
    entries: list[Entry] = []
    exit_code = 0
    root = Path(root_path).resolve() if root_path else repository_root()
    write_sets = write_sets or {}
    package_paths = package_paths or {}
    for name in names:
        print(f"package-updates: updating {name}", flush=True)
        before, changelog_before = evaluate(name, system)
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
            moved = before != after or bool(paths) or _changed_paths(root, write_set)
            status = FAILED if result.returncode != 0 else UPDATED if moved else UNCHANGED
            if result.returncode != 0:
                reason = (result.stderr or result.stdout).strip()
                print(failure(name, result.returncode) + (f": {reason}" if reason else ""), flush=True)
                exit_code = exit_code or result.returncode or 1
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
            exit_code = exit_code or 1
        entries.append(entry)
    batch = Report(system=system, entries=tuple(entries))
    print(flush=True)
    print(batch.summary(), flush=True)
    save(batch, json_path, markdown_path)
    return exit_code
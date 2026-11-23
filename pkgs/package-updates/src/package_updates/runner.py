"""Refresh flake inputs, then run each update as a local file transaction.

An input moves by its version policy (``input_policy``). An update is a
registered package, run through nix-update with its own policy
(``passthru.updateScript`` and nix-update's discovery), or a registered command
that edits only its declared write set, such as a lockfile refresh. Versions and the
working-copy diff are read outside the updater, so the report never parses its
output.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import flake_update, input_policy
from .flake_update import FlakeUpdateError
from .input_policy import Override, PolicyError
from .report import (
    ABORTED,
    COMPLETE,
    FAILED,
    PARTIAL,
    UNCHANGED,
    UPDATED,
    MISSING,
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
    input_overrides: dict[str, Override] = field(default_factory=dict)
    # Command updates: name -> (program, write set).
    commands: dict[str, tuple[str, tuple[str, ...]]] = field(default_factory=dict)
    # flake-file's renderer, when flake.nix is generated.
    write_flake: str | None = None


def load_registry(environ=os.environ) -> Registry:
    path = environ.get("PACKAGE_UPDATES_REGISTRY")
    if not path:
        raise UpdateError(
            "PACKAGE_UPDATES_REGISTRY is not set; "
            "run update-all through the module's app"
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

    try:
        overrides = input_policy.load_overrides(data.get("inputs", {}))
    except PolicyError as error:
        raise UpdateError(str(error)) from error

    commands = {}
    for name, entry in data.get("commands", {}).items():
        if not entry.get("paths"):
            raise UpdateError(f"command '{name}' needs a non-empty write set")
        commands[name] = (entry["program"], tuple(entry["paths"]))
    clash = sorted(set(commands) & set(data["registered"]))
    if clash:
        raise UpdateError(f"registered as both package and command: {', '.join(clash)}")

    return Registry(
        system=data["system"],
        registered=tuple(data["registered"]),
        available=tuple(data["available"]),
        write_sets=write_sets,
        root=data.get("root", "."),
        package_paths=data.get("packagePaths", {}),
        input_overrides=overrides,
        commands=commands,
        write_flake=data.get("writeFlake"),
    )


def select(registry: Registry, requested: list[str], refresh_inputs: bool = False) -> list[str]:
    """Return the effective selection in lexical order, or refuse by name.

    The whole selection is validated before any updater runs: a duplicate,
    unregistered or output-less selection must never reach the update loop. An
    empty registry is a valid run only when the lock is being refreshed.
    """
    known = set(registry.registered) | set(registry.commands)
    if not known and not requested:
        if refresh_inputs:
            return []
        raise UpdateError(
            "nothing registered; set ci.updates.packages or ci.updates.commands"
        )
    selection = requested or sorted(known)
    duplicates = sorted({name for name in selection if selection.count(name) > 1})
    if duplicates:
        raise UpdateError(f"duplicate selection: {', '.join(duplicates)}")
    unknown = sorted(set(selection) - known)
    if unknown:
        raise UpdateError(f"not registered: {', '.join(unknown)}")
    missing = sorted(set(selection) - set(registry.commands) - set(registry.available))
    if missing:
        raise UpdateError(
            f"registered but no packages.{registry.system} output: {', '.join(missing)}"
        )
    return sorted(selection)


def lock_refresh(requested_inputs: list[str], refresh_all: bool) -> list[str] | None:
    """Decide which inputs a run refreshes: None means the lock is left alone.

    Explicit inputs move exactly those; ``refresh_all`` moves every input by
    its policy. Package-only runs never touch the lock.
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
    requested: list[str],
    overrides: dict[str, Override],
    root: Path,
    write_flake: str | None,
) -> tuple[list[InputEntry], dict[str, str], str | None]:
    """Move the selected inputs; return what moved, what failed, or the named failure.

    Branch inputs refresh first in one lock update; tag inputs then move one at a
    time. An empty branch selection is skipped rather than passed on: ``nix flake
    update`` with no names would move every input, fixed ones included.
    """
    try:
        lock = flake_update.read_lock(root)
        nodes = flake_update.top_level_nodes(lock)
        policies = input_policy.classify(lock, nodes, overrides, requested)
    except (PolicyError, FlakeUpdateError) as error:
        return [], {}, str(error)
    branches = sorted(name for name, policy in policies.items() if policy == input_policy.BRANCH)
    entries = []
    try:
        if branches:
            entries = [
                InputEntry(
                    name=change.name,
                    before=change.before,
                    after=change.after,
                    date=change.date,
                    source=change.source,
                    compare=flake_update.compare_url(change),
                )
                for change in flake_update.apply(branches, root)
            ]
    except FlakeUpdateError as error:
        return [], {}, str(error)
    moves, failed = input_policy.move_tags(root, overrides, policies, lock, nodes, write_flake)
    entries += [
        InputEntry(
            name=move.name,
            before=move.before,
            after=move.after,
            date=MISSING,
            source=f"github:{move.github[0]}/{move.github[1]}" if move.github else "git",
            compare=move.compare,
            release=move.release,
        )
        for move in moves
    ]
    return sorted(entries, key=lambda entry: entry.name), failed, None


def update(
    names: list[str],
    system: str,
    json_path: str | None = None,
    markdown_path: str | None = None,
    write_sets: dict[str, tuple[str, ...]] | None = None,
    package_paths: dict[str, str] | None = None,
    root_path: str | None = None,
    inputs: list[str] | None = None,
    input_overrides: dict[str, Override] | None = None,
    commands: dict[str, tuple[str, tuple[str, ...]]] | None = None,
    write_flake: str | None = None,
) -> int:
    # The batch's own nix calls (lock refresh, version evals) and the updaters
    # it spawns need features the ambient environment may not carry: an effect
    # sandbox has no nix.conf, and nix-update offers no flag for its internal
    # nix-instantiate. A caller's NIX_CONFIG still applies, later lines win.
    previous = os.environ.get("NIX_CONFIG")
    os.environ["NIX_CONFIG"] = "experimental-features = nix-command flakes" + (
        f"\n{previous}" if previous else ""
    )

    """Refresh the lock when asked, then run selected updaters in jj workspaces.

    ``inputs`` None moves no input; a list moves exactly those names (empty
    meaning every input by its policy). The child inherits this process's
    environment, so package-specific target variables flow through unchanged.
    Successful package diffs are applied in sequence; failed candidates are
    discarded and later packages still run.
    """
    commands = commands or {}
    packages = [name for name in names if name not in commands]
    executable = shutil.which("nix-update")
    if packages and executable is None:
        raise UpdateError("nix-update not found on PATH")
    root = Path(root_path).resolve() if root_path else repository_root()
    write_sets = write_sets or {}
    package_paths = package_paths or {}
    before_versions = {
        name: (None, None) if name in commands else evaluate(name, system) for name in names
    }

    aborted = False
    input_entries: list[InputEntry] = []
    failed_inputs: dict[str, str] = {}
    input_failure = None
    if inputs is not None:
        input_entries, failed_inputs, input_failure = _refresh(
            inputs, input_overrides or {}, root, write_flake
        )
        if input_failure is not None:
            print(f"✗ Failed flake inputs: {input_failure}", flush=True)
        for entry in input_entries:
            print(input_bullet(entry), flush=True)
        for name, reason in sorted(failed_inputs.items()):
            print(f"✗ Failed input '{name}': {reason}", flush=True)
        print(f"flake inputs: {len(input_entries)} moved", flush=True)

    entries: list[Entry] = []
    for name in names:
        print(f"package-updates: updating {name}", flush=True)
        before, changelog_before = before_versions[name]
        if name in commands:
            program, write_set = commands[name]
            argv = [program]
        else:
            write_set = tuple(write_sets.get(name, ())) or (
                package_paths.get(name, f"pkgs/{name}"),
            )
            argv = [executable, "--flake", "--use-update-script", "--system", system, name]
        try:
            result, paths = staged_package(
                root,
                name,
                write_set,
                lambda candidate: subprocess.run(
                    argv,
                    cwd=candidate,
                    capture_output=True,
                    text=True,
                    env=os.environ.copy(),
                ),
            )
            after, changelog_after = (None, None) if name in commands else evaluate(name, system)
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
        failed_inputs=tuple(sorted(failed_inputs.items())),
        aborted=aborted,
    )
    print(flush=True)
    print(batch.summary(), flush=True)
    save(batch, json_path, markdown_path)
    return EXIT_CODES[batch.outcome]

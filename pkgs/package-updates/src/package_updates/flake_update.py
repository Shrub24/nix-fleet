"""Pick which top-level flake inputs to accept from a candidate lock.

``nix flake update --output-lock-file`` resolves every input into a candidate
lock beside the real one, so the preview never touches ``flake.lock``. Only the
inputs the user accepts are then updated by name in the real lock. Inputs that
move only through ``follows`` or as transitive side effects are reported after
the apply rather than offered as choices.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

LOCK = "flake.lock"
_MISSING = "—"


class FlakeUpdateError(Exception):
    """A named refusal. Nothing has been applied when raised."""


@dataclass(frozen=True)
class InputChange:
    name: str
    before: str
    after: str
    date: str


def _locked(lock: dict, node: str | None) -> dict:
    if node is None:
        return {}
    return lock["nodes"].get(node, {}).get("locked", {})


def top_level_nodes(lock: dict) -> dict[str, str]:
    """Map each root input to its node name, skipping ``follows`` redirections."""
    root = lock["nodes"][lock.get("root", "root")]
    return {
        name: node
        for name, node in root.get("inputs", {}).items()
        if isinstance(node, str)
    }


def _revision(locked: dict) -> str:
    value = locked.get("rev") or locked.get("narHash")
    return value[:12] if value else _MISSING


def _date(locked: dict) -> str:
    stamp = locked.get("lastModified")
    return time.strftime("%Y-%m-%d", time.gmtime(stamp)) if stamp else _MISSING


def changes(old: dict, new: dict) -> list[InputChange]:
    """Return the top-level inputs whose locked source differs, in name order."""
    before_nodes = top_level_nodes(old)
    after_nodes = top_level_nodes(new)
    found = []
    for name in sorted(set(before_nodes) | set(after_nodes)):
        before = _locked(old, before_nodes.get(name))
        after = _locked(new, after_nodes.get(name))
        if before == after:
            continue
        found.append(
            InputChange(
                name=name,
                before=_revision(before),
                after=_revision(after),
                date=_date(after),
            )
        )
    return found


def parse_selection(answer: str, count: int) -> list[int]:
    """Parse a 1-based selection: numbers, ``all``, or blank for none."""
    text = answer.strip().lower()
    if text in ("", "none"):
        return []
    if text == "all":
        return list(range(1, count + 1))
    picks = set()
    for part in text.split(","):
        part = part.strip()
        if not part.isdigit() or not 1 <= int(part) <= count:
            raise FlakeUpdateError(f"not a listed number: {part!r}")
        picks.add(int(part))
    return sorted(picks)


def _choose(found: list[InputChange], requested: list[str]) -> list[str]:
    names = {change.name for change in found}
    if requested:
        unknown = sorted(set(requested) - names)
        if unknown:
            raise FlakeUpdateError(f"not a candidate change: {', '.join(unknown)}")
        return sorted(set(requested))
    if not sys.stdin.isatty():
        raise FlakeUpdateError("non-interactive run needs INPUT names, or --dry-run")
    answer = input("accept (numbers, comma-separated; 'all'; blank for none): ")
    return [found[index - 1].name for index in parse_selection(answer, len(found))]


def _nix(args: list[str], cwd: Path) -> None:
    result = subprocess.run(["nix", *args], cwd=cwd)
    if result.returncode != 0:
        raise FlakeUpdateError(f"nix {' '.join(args)} failed with exit {result.returncode}")


def _read(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise FlakeUpdateError(f"cannot read {path}: {error}") from error


def run(requested: list[str], dry_run: bool, repo: Path) -> int:
    current = repo / LOCK
    if not current.is_file():
        raise FlakeUpdateError(f"no {LOCK} in {repo}; run from the flake root")
    old = _read(current)
    with tempfile.TemporaryDirectory(prefix="update-flake-") as scratch:
        candidate = Path(scratch) / LOCK
        _nix(["flake", "update", "--output-lock-file", str(candidate)], repo)
        new = _read(candidate)

    found = changes(old, new)
    if not found:
        print("update-flake: every top-level input is current")
        return 0
    print("update-flake: candidate changes")
    for index, change in enumerate(found, 1):
        print(f"  {index:>2}) {change.name:<24} {change.before} -> {change.after}  ({change.date})")
    if dry_run:
        return 0

    chosen = _choose(found, requested)
    if not chosen:
        print("update-flake: nothing accepted; flake.lock unchanged")
        return 0
    _nix(["flake", "update", *chosen], repo)

    moved = {change.name for change in changes(old, _read(current))}
    print(f"update-flake: updated {', '.join(chosen)}")
    side_effects = sorted(moved - set(chosen))
    if side_effects:
        print(f"update-flake: also moved through follows: {', '.join(side_effects)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="update-flake",
        description="Preview flake input updates and accept a chosen subset.",
    )
    parser.add_argument(
        "inputs",
        nargs="*",
        metavar="INPUT",
        help="accept these top-level inputs without prompting",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="list the candidate changes and stop",
    )
    args = parser.parse_args(argv)
    try:
        return run(args.inputs, args.dry_run, Path.cwd())
    except FlakeUpdateError as error:
        print(f"update-flake: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

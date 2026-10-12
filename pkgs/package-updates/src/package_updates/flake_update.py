"""Flake input candidates and application for the interactive ``update``.

``candidate`` resolves every input into a scratch lock beside ``flake.lock``,
so the picker can preview changes without touching it. ``apply`` updates only
the accepted inputs by name with ``nix flake update``.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

LOCK = "flake.lock"
_MISSING = "—"
# How many recent commits a preview lists per input; keeps the pane readable.
PREVIEW_COMMITS = 15


class FlakeUpdateError(Exception):
    """A named refusal. Nothing has been applied when raised."""


@dataclass(frozen=True)
class InputChange:
    name: str
    before: str
    after: str
    date: str
    source: str
    old_rev: str
    new_rev: str
    github: tuple[str, str] | None


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


def _source(locked: dict) -> str:
    kind = locked.get("type", "?")
    if kind == "github":
        return f"github:{locked.get('owner')}/{locked.get('repo')}"
    return kind


def _github(locked: dict) -> tuple[str, str] | None:
    if locked.get("type") == "github" and locked.get("owner") and locked.get("repo"):
        return locked["owner"], locked["repo"]
    return None


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
                source=_source(after or before),
                old_rev=before.get("rev", ""),
                new_rev=after.get("rev", ""),
                github=_github(after or before),
            )
        )
    return found


def _nix(args: list[str], cwd: Path) -> None:
    result = subprocess.run(["nix", *args], cwd=cwd)
    if result.returncode != 0:
        raise FlakeUpdateError(f"nix {' '.join(args)} failed with exit {result.returncode}")


def read_lock(repo: Path) -> dict:
    path = repo / LOCK
    if not path.is_file():
        raise FlakeUpdateError(f"no {LOCK} in {repo}; run from the flake root")
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise FlakeUpdateError(f"cannot read {path}: {error}") from error


def candidate(repo: Path) -> dict:
    """Resolve every input into a candidate lock beside, never over, flake.lock."""
    with tempfile.TemporaryDirectory(prefix="update-flake-") as scratch:
        output = Path(scratch) / LOCK
        _nix(["flake", "update", "--output-lock-file", str(output)], repo)
        try:
            return json.loads(output.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise FlakeUpdateError(f"cannot read candidate lock: {error}") from error


def apply(names: list[str], repo: Path) -> list[InputChange]:
    """Update the named inputs, or all of them when empty, and return what moved."""
    old = read_lock(repo)
    _nix(["flake", "update", *names], repo)
    return changes(old, read_lock(repo))


def commits_between(change: InputChange, runner=subprocess.run) -> list[str] | None:
    """Return one-line commit subjects between the two revisions, or None.

    Only GitHub inputs with both revisions known can be compared. Anything else,
    or a failing ``gh``, is shown as unavailable rather than failing the picker.
    """
    if change.github is None or not change.old_rev or not change.new_rev:
        return None
    owner, repo = change.github
    result = runner(
        [
            "gh",
            "api",
            f"repos/{owner}/{repo}/compare/{change.old_rev}...{change.new_rev}",
            "--jq",
            '.commits[] | (.sha[0:7] + " " + (.commit.message | split("\\n")[0]))',
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return [line for line in result.stdout.splitlines() if line.strip()][-PREVIEW_COMMITS:]


def preview(change: InputChange, commits: list[str] | None) -> str:
    """Render the detail shown beside an input in the picker."""
    lines = [
        change.name,
        "",
        f"  source   {change.source}",
        f"  from     {change.before}",
        f"  to       {change.after}  ({change.date})",
        "",
    ]
    if commits is None:
        lines.append("  commits  unavailable (needs gh and a GitHub input)")
    elif not commits:
        lines.append("  commits  none between these revisions")
    else:
        lines.append(f"  commits  latest {len(commits)} (oldest first)")
        lines.extend(f"    {line}" for line in commits)
    return "\n".join(lines) + "\n"

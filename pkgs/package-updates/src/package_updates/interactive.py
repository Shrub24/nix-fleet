"""Interactive ``update``: one fzf picker over flake inputs and package updates.

Both lists are candidates the plain commands already compute: flake inputs
from a candidate lock, and registered packages whose ``checkUpdate`` reports a
newer release. Only what the user accepts is applied, through the same
``apply`` and batch runner the plain commands use.
"""

from __future__ import annotations

import argparse
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import flake_update
from .check import NEWER, Finding, check
from .runner import UpdateError, evaluate, load_registry, select, update

FLAKE = "flake"
PACKAGE = "package"


@dataclass(frozen=True)
class Candidate:
    kind: str
    name: str
    summary: str
    preview: str


def flake_candidate(change: flake_update.InputChange) -> Candidate:
    commits = flake_update.commits_between(change)
    return Candidate(FLAKE, change.name, f"{change.before} -> {change.after}", flake_update.preview(change, commits))


def package_candidate(finding: Finding, system: str) -> Candidate:
    _, changelog = evaluate(finding.name, system)
    lines = [
        finding.name,
        "",
        "  source   passthru.checkUpdate",
        f"  from     {finding.current}",
        f"  to       {finding.latest}",
        f"  changelog {changelog}" if changelog else "  changelog unavailable",
    ]
    return Candidate(PACKAGE, finding.name, f"{finding.current} -> {finding.latest}", "\n".join(lines) + "\n")


def rows(candidates: list[Candidate]) -> str:
    """Render the picker input: kind, name, summary, then a 1-based preview index."""
    return "".join(
        f"{candidate.kind}\t{candidate.name}\t{candidate.summary}\t{index}\n"
        for index, candidate in enumerate(candidates, 1)
    )


def picked(lines: list[str], candidates: list[Candidate]) -> list[Candidate]:
    """Map the picker's output lines back to their candidates."""
    return [candidates[int(line.split("\t")[3]) - 1] for line in lines if line.strip()]


def pick(candidates: list[Candidate], previews: Path) -> list[Candidate]:
    """Show both lists in one fzf multi-select; an empty result when cancelled."""
    fzf = shutil.which("fzf")
    if fzf is None:
        raise UpdateError("fzf not found on PATH")
    for index, candidate in enumerate(candidates, 1):
        (previews / f"{index}.txt").write_text(candidate.preview, encoding="utf-8")
    result = subprocess.run(
        [
            fzf,
            "--multi",
            "--delimiter=\t",
            "--with-nth=1,2,3",
            "--header=TAB marks, ENTER applies, ESC cancels",
            "--prompt=update > ",
            f"--preview=cat {shlex.quote(str(previews))}/{{4}}.txt",
            "--preview-window=right,60%,wrap",
        ],
        input=rows(candidates),
        capture_output=True,
        text=True,
    )
    # fzf: 0 accepted, 1 no match, 130 cancelled with ESC or Ctrl-C.
    if result.returncode in (1, 130):
        return []
    if result.returncode != 0:
        raise UpdateError(f"fzf exited with {result.returncode}")
    return picked(result.stdout.splitlines(), candidates)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="update",
        description="Choose flake inputs and package updates to apply, interactively.",
    )
    parser.parse_args(argv)
    try:
        if not sys.stdin.isatty():
            raise UpdateError("update is interactive; use update-flake or update-packages")
        repo = Path.cwd()
        registry = load_registry()
        found = flake_update.changes(flake_update.read_lock(repo), flake_update.candidate(repo))
        newer = [finding for finding in check(list(registry.registered), registry.system) if finding.status == NEWER]
        candidates = [flake_candidate(change) for change in found]
        candidates += [package_candidate(finding, registry.system) for finding in newer]
        if not candidates:
            print("update: everything is current")
            return 0
        with tempfile.TemporaryDirectory(prefix="update-preview-") as scratch:
            chosen = pick(candidates, Path(scratch))
        if not chosen:
            print("update: nothing selected; nothing changed")
            return 0
        code = 0
        flake_names = sorted(candidate.name for candidate in chosen if candidate.kind == FLAKE)
        package_names = sorted(candidate.name for candidate in chosen if candidate.kind == PACKAGE)
        if flake_names:
            moved = flake_update.apply(flake_names, repo)
            print(f"update: flake inputs updated: {', '.join(change.name for change in moved) or 'none moved'}")
        if package_names:
            code = update(select(registry, package_names), registry.system, None, None)
        return code
    except (UpdateError, flake_update.FlakeUpdateError) as error:
        print(f"update: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

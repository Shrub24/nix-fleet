"""Cheap ``--check``: ask each package whether a newer release exists.

A package that wants a cheap check declares ``passthru.checkUpdate``: a
derivation whose main program prints the newest release version on stdout and
exits 0. The package owns where to look (forge, repository, tag scheme), so the
runner never infers release locations. A package without one, a lookup that
fails, or a version that is not stable ``X.Y.Z`` is reported as unknown rather
than guessed.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

CURRENT = "current"
NEWER = "newer"
UNKNOWN = "unknown"

# One eval reads the version and the checkUpdate program name. Missing
# attributes come back null, so an undeclared package degrades to unknown.
_EVAL = (
    "p: { version = p.version or null;"
    " program = p.passthru.checkUpdate.meta.mainProgram or null; }"
)

_STABLE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


@dataclass(frozen=True)
class Finding:
    name: str
    status: str
    current: str | None
    latest: str | None
    note: str


def _version_key(text: str | None) -> tuple[int, ...] | None:
    match = _STABLE.match(text or "")
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())


def compare(name: str, current: str | None, latest: str) -> Finding:
    """Compare a current version with a lookup result; both must be stable."""
    current_key = _version_key(current)
    latest_key = _version_key(latest)
    if current_key is None:
        return Finding(name, UNKNOWN, current, latest, "current version is not stable X.Y.Z")
    if latest_key is None:
        return Finding(name, UNKNOWN, current, latest, "checkUpdate printed no stable X.Y.Z version")
    status = NEWER if latest_key > current_key else CURRENT
    return Finding(name, status, current, latest, "")


def _run(argv: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True)


def check_one(name: str, system: str, runner=_run) -> Finding:
    """Evaluate, build and run one package's ``checkUpdate``."""
    evaluated = runner(
        ["nix", "eval", "--json", "--no-write-lock-file", "--apply", _EVAL, f".#packages.{system}.{name}"]
    )
    try:
        data = json.loads(evaluated.stdout) if evaluated.returncode == 0 else {}
    except json.JSONDecodeError:
        data = {}
    version = data.get("version")
    program = data.get("program")
    if program is None:
        return Finding(name, UNKNOWN, version, None, "no passthru.checkUpdate declared")

    built = runner(
        ["nix", "build", "--no-link", "--print-out-paths", "--no-write-lock-file",
         f".#packages.{system}.{name}.passthru.checkUpdate"]
    )
    if built.returncode != 0:
        return Finding(name, UNKNOWN, version, None, "could not build checkUpdate")
    out = Path(built.stdout.strip().splitlines()[-1])

    lookup = runner([str(out / "bin" / program)])
    if lookup.returncode != 0:
        reason = (lookup.stderr or "").strip().splitlines()
        return Finding(name, UNKNOWN, version, None, f"release lookup failed: {reason[-1] if reason else 'no output'}")
    latest = lookup.stdout.strip()
    if not latest:
        return Finding(name, UNKNOWN, version, None, "release lookup printed nothing")
    return compare(name, version, latest)


def check(names: list[str], system: str, runner=_run) -> list[Finding]:
    """Check each named package and return findings in the given order."""
    return [check_one(name, system, runner) for name in names]


def render(findings: list[Finding]) -> str:
    """Render the human report in the same shape as the update report."""
    width = max((len(finding.name) for finding in findings), default=0)
    lines = []
    for finding in findings:
        if finding.status == NEWER:
            detail = f"{finding.current} -> {finding.latest}"
        elif finding.status == CURRENT:
            detail = f"{finding.current} (current)"
        else:
            detail = f"{finding.current or '—'} ({finding.note})"
        lines.append(f"  {finding.name:<{width}}  {detail}")
    newer = sum(1 for finding in findings if finding.status == NEWER)
    lines.append("")
    lines.append(f"package-updates: {newer} newer of {len(findings)} checked")
    return "\n".join(lines)

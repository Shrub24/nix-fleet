"""Report model and renderers for the package-update batch.

The batch reports what a refresh changed, never what it fetched: versions and
changelog links come from the evaluated flake, and a changelog stays a URL
recorded in the report. One set of entries feeds the stdout bullets, the JSON
artifact and the pull-request body.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

UPDATED = "updated"
UNCHANGED = "unchanged"
FAILED = "failed"

MAJOR = "major"
MINOR = "minor"
PATCH = "patch"
NONE = "none"
UNKNOWN = "unknown"

# Batch outcomes: a complete run, one that is proposable but carries failures, and
# one whose tree is not fit to propose (adoption stopped part-way).
COMPLETE = "complete"
PARTIAL = "partial"
ABORTED = "aborted"

# Placeholder for a value the flake did not yield.
MISSING = "—"

_LEVELS = (MAJOR, MINOR)

_HEADING = "## Package updates"
_CURRENT = "No registered package has a newer stable release; every pin is current."
_FOOTER = (
    "Refresh is not acceptance: this pull request is accepted only when the "
    "repository's declared checks pass. The `ci` workflow runs them on this pull request."
)


@dataclass(frozen=True)
class Entry:
    """One selected package's outcome."""

    name: str
    status: str
    before: str | None
    after: str | None
    change: str
    changelog: str | None

    @property
    def version(self) -> str:
        """The version to show for a package whose version did not move."""
        return self.after or self.before or MISSING


@dataclass(frozen=True)
class InputEntry:
    """One flake input whose locked revision moved in this refresh."""

    name: str
    before: str
    after: str
    date: str
    source: str
    compare: str | None


@dataclass(frozen=True)
class Report:
    """The batch's entries in selection order, for the evaluated system.

    ``inputs`` lists only the flake inputs that moved; ``input_failure`` names
    the refresh that did not complete, or is None.
    """

    system: str
    entries: tuple[Entry, ...]
    inputs: tuple[InputEntry, ...] = ()
    input_failure: str | None = None
    aborted: bool = False

    @property
    def outcome(self) -> str:
        """Whether the batch is proposable, proposable with failures, or not at all."""
        if self.aborted:
            return ABORTED
        return PARTIAL if self.failed or self.input_failure is not None else COMPLETE

    @property
    def updated(self) -> list[Entry]:
        return [entry for entry in self.entries if entry.status == UPDATED]

    @property
    def unchanged(self) -> list[Entry]:
        return [entry for entry in self.entries if entry.status == UNCHANGED]

    @property
    def failed(self) -> list[Entry]:
        return [entry for entry in self.entries if entry.status == FAILED]

    def summary(self) -> str:
        """The stdout count line, e.g. ``2 updated, 1 unchanged``."""
        counts = f"{len(self.updated)} updated, {len(self.unchanged)} unchanged"
        return f"{counts}, {len(self.failed)} failed" if self.failed else counts

    def document(self) -> dict:
        """The structured report. No timestamps, so two runs stay comparable."""
        return {
            "outcome": self.outcome,
            "system": self.system,
            "inputs": [
                {
                    "name": entry.name,
                    "version": {"before": entry.before, "after": entry.after},
                    "date": entry.date,
                    "source": entry.source,
                    "compare": entry.compare,
                }
                for entry in self.inputs
            ],
            "inputFailure": self.input_failure,
            "packages": [
                {
                    "name": entry.name,
                    "status": entry.status,
                    "version": {"before": entry.before, "after": entry.after},
                    "change": entry.change,
                    "changelog": entry.changelog,
                }
                for entry in self.entries
            ],
        }

    def json_text(self) -> str:
        return json.dumps(self.document(), indent=2) + "\n"

    def markdown_text(self) -> str:
        rows = [_HEADING, ""]
        if self.inputs:
            rows += [
                "| Flake input | From | To | Compare |",
                "| --- | --- | --- | --- |",
            ]
            for entry in self.inputs:
                link = f"[compare]({entry.compare})" if entry.compare else MISSING
                rows.append(f"| `{entry.name}` | {entry.before} | {entry.after} | {link} |")
            rows.append("")
        if self.updated:
            rows += [
                "| Package | Change | From | To | Changelog |",
                "| --- | --- | --- | --- | --- |",
            ]
            for entry in self.updated:
                link = f"[changelog]({entry.changelog})" if entry.changelog else MISSING
                rows.append(
                    f"| `{entry.name}` | {entry.change} | {entry.before or MISSING} "
                    f"| {entry.after or MISSING} | {link} |"
                )
            rows.append("")
        elif not self.inputs and not self.failed:
            rows.append(_CURRENT)
        if self.updated and self.unchanged:
            current = ", ".join(f"`{entry.name}` {entry.version}" for entry in self.unchanged)
            rows += [f"Already current: {current}.", ""]
        if self.failed:
            names = ", ".join(f"`{entry.name}`" for entry in self.failed)
            rows += [f"Not updated, the updater failed: {names}. Their pins are unchanged.", ""]
        if self.input_failure is not None:
            rows += [f"Flake input refresh did not complete: {self.input_failure}", ""]
        if self.inputs or self.updated or self.failed or self.input_failure is not None:
            rows.append(_FOOTER)
        return "\n".join(rows) + "\n"


def bullet(entry: Entry) -> str:
    """The stdout line for a package that ran to completion."""
    if entry.status == UPDATED:
        return f"• Updated '{entry.name}': {entry.before or MISSING} → {entry.after or MISSING}"
    return f"• Unchanged '{entry.name}': {entry.version}"


def input_bullet(entry: InputEntry) -> str:
    """The stdout line for a flake input whose locked revision moved."""
    return f"• Updated input '{entry.name}': {entry.before} → {entry.after}"


def failure(name: str, exit_code: int) -> str:
    """The stdout line for a package whose updater failed."""
    return f"✗ Failed '{name}': update failed (exit {exit_code})"


def classify(before: str | None, after: str | None) -> str:
    """Classify a version move by its highest differing component."""
    if before == after:
        return NONE
    old, new = _components(before), _components(after)
    if old is None or new is None:
        return UNKNOWN
    width = max(len(old), len(new))
    old += [0] * (width - len(old))
    new += [0] * (width - len(new))
    for index, (old_part, new_part) in enumerate(zip(old, new)):
        if old_part != new_part:
            return _LEVELS[index] if index < len(_LEVELS) else PATCH
    return NONE


def _components(version: str | None) -> list[int] | None:
    """Dotted numeric components, or None for any other version shape."""
    if not version:
        return None
    try:
        return [int(part) for part in version.split(".")]
    except ValueError:
        return None

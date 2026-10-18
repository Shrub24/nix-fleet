"""Exercise the native producer's decision step and its credential boundary.

The step reads the batch's report and exit status to decide whether anything is
proposable: a missing report, a report that contradicts the exit status, a missing
artifact, or nothing to propose all fail the step, and a successful refresh must
not fail its own step. The updaters run repository code, so the job that runs them
must hold no credential.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


workflow = yaml.load(Path(sys.argv[1]).read_text(), Loader=yaml.BaseLoader)
update = workflow["jobs"]["update"]
publish = workflow["jobs"]["publish"]

# The credential boundary: the code-executing job has nothing to leak.
assert "environment" not in update, "the update job selects an environment"
assert "secrets" not in str(update), "the update job must hold no secret"
assert "create-github-app-token" not in str(update), "the App key must not be minted where updaters run"
assert "create-pull-request" not in str(update), "the update job must not publish"
assert publish["environment"] == "automation"
assert publish["needs"] == "update"
assert "publish == 'true'" in publish["if"], publish["if"]
assert "secrets.AUTOMATION_APP_PRIVATE_KEY" in str(publish)
assert "changes.patch" in str(publish), "the proposal must cross to the publisher as data"

step = next(
    candidate
    for candidate in update["steps"]
    if candidate["name"] == "Refresh flake inputs and registered packages"
)
script = step["run"]

# outcome, the batch's exit status, which artifacts exist, the step's expected
# status, and whether the step may propose. The status and the report must agree:
# a missing report is a run that never finished, and the report is written before
# the pull-request body, so a completed report about a run that then failed must
# not propose a tree.
cases = [
    ("complete", "0", "both", 0, True),
    ("partial", "1", "both", 0, True),
    ("aborted", "2", "both", 2, False),
    (None, "1", "none", 2, False),
    ("complete", "2", "both", 2, False),
    ("partial", "0", "both", 2, False),
    ("aborted", "0", "both", 2, False),
    ("complete", "0", "report-only", 2, False),
    ("complete", "0", "none", 2, False),
]
for outcome, batch_exit, artifacts, expected, proposes in cases:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        if outcome is not None:
            (root / "report.json").write_text(json.dumps({"outcome": outcome}))
        if artifacts == "both":
            (root / "pr-body.md").write_text("body\n")
        stubs = root / "bin"
        stubs.mkdir()
        (stubs / "nix").write_text(f"#!/bin/sh\nexit {batch_exit}\n")
        (stubs / "nix").chmod(0o755)
        output = root / "github_output"
        output.write_text("")
        result = subprocess.run(
            ["bash", "-c", script],
            env={
                **os.environ,
                "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
                "RUNNER_TEMP": str(root),
                "GITHUB_OUTPUT": str(output),
            },
            capture_output=True,
            text=True,
        )
        context = f"outcome={outcome} exit={batch_exit} {artifacts}: {result.stdout}{result.stderr}"
        assert result.returncode == expected, context
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        assert values.get("propose") == ("true" if proposes else "false"), context
        if outcome == "partial" and proposes:
            assert "::warning::" in result.stdout, context
        if not proposes:
            assert "::error::" in result.stdout, context

print("producer decision step and credential boundary: ok")

"""Exercise the rule that the automation scripts are never taken from the workspace.

A consuming repository calls these workflows; its own tree has no `.github/scripts`
and must not need one. The copy that runs the procedure therefore has to come from
the revision that defines the workflow — except where the procedure is a guard
against the revision rewriting itself, which must come from the fleet's default
branch.
"""

from pathlib import Path
import sys

import yaml


def steps_of(path):
    workflow = yaml.load(Path(path).read_text(), Loader=yaml.BaseLoader)
    found = {}
    for job_name, job in workflow["jobs"].items():
        for step in job.get("steps", []):
            found.setdefault(job_name, []).append(step)
    return workflow, found


def script_steps(steps):
    return [
        step
        for step in steps
        if ".github/scripts/" in step.get("run", "")
    ]


def checkout_for(steps, path_name):
    for step in steps:
        if step.get("uses", "").startswith("actions/checkout@") and step.get("with", {}).get("path") == path_name:
            return step
    raise AssertionError(f"no checkout with path: {path_name}")


def assert_fleet_checkout(step, *, ref, hint):
    with_block = step["with"]
    assert with_block.get("repository") == "${{ job.workflow_repository }}", (
        f"{hint}: the scripts come from {with_block.get('repository')!r}, not the defining repository"
    )
    assert with_block.get("ref") == ref, f"{hint}: expected ref {ref!r}, got {with_block.get('ref')!r}"
    assert with_block.get("sparse-checkout") == ".github/scripts", hint
    assert with_block.get("persist-credentials") == "false", f"{hint}: the script checkout keeps credentials"


# --- the jobs that run the procedure on a candidate tree or on main --------------
for name, expected_ref in (
    ("candidate", "${{ job.workflow_sha }}"),
    ("promote-candidate", "${{ job.workflow_sha }}"),
):
    workflow, by_job = steps_of(f".github/workflows/{name}.yml")
    ran = False
    for job_name, steps in by_job.items():
        found = script_steps(steps)
        if not found:
            continue
        ran = True
        trusted = checkout_for(steps, "trusted")
        assert_fleet_checkout(trusted, ref=expected_ref, hint=f"{name}/{job_name}")
        for step in found:
            run = step["run"]
            assert "$GITHUB_WORKSPACE/trusted/.github/scripts/" in run, (
                f"{name}/{job_name} runs a script from the workspace: {run.strip()}"
            )
    assert ran, f"{name}: no step runs an automation script; the check would be vacuous"

# --- the consistency guard must not trust the revision it is checking ------------
_, by_job = steps_of(".github/workflows/validate.yml")
consistency = by_job["consistency"]
trusted = checkout_for(consistency, "trusted")
assert_fleet_checkout(trusted, ref="main", hint="validate/consistency")
assert any(
    "$GITHUB_WORKSPACE/trusted/.github/scripts/prepare-candidate.sh" in step.get("run", "")
    for step in consistency
), "validate/consistency does not run the trusted copy"

# The revision under test is checked out separately, so a rewrite of the script in
# that revision cannot change what runs.
targets = [
    step
    for step in consistency
    if step.get("uses", "").startswith("actions/checkout@") and step.get("with", {}).get("path") == "target"
]
assert targets, "validate/consistency no longer checks out the revision under test"

print("automation scripts resolve from the defining revision")

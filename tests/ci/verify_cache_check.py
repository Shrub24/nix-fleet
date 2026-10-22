"""Exercise the verify step against a stub `nix`: a served root reports clean, a missing
root is named without failing the job, a tool failure still fails, both systems are
asked, and no credential is held."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


workflow = yaml.load(Path(sys.argv[1]).read_text(), Loader=yaml.BaseLoader)

assert workflow["on"]["push"]["branches"] == ["main"], "the per-commit cache status of main is the point"
assert "workflow_dispatch" in workflow["on"]

# Read-only verification must not carry a credential, or it becomes another place
# a pull request could reach one.
verify = workflow["jobs"]["verify"]
assert verify["permissions"] == {"contents": "read"}
assert "id-token" not in str(verify), "the verify job asks for an OIDC token"
assert "tailscale" not in str(verify), "the verify job joins the tailnet for a public read"
assert "niks3-action" not in str(verify), "the verify job needs no cache client to ask about a path"
assert verify["outputs"]["cache"] == "${{ steps.cache.outputs.url }}"

# The substituter route comes from the fleet revision that defines this workflow, so
# verifying a consumer repository needs no fleet input and no fleet artifact there.
vsteps = {step.get("name"): step for step in verify["steps"]}
vfleet = vsteps["Resolve the fleet revision"]
assert vfleet["env"]["FLEET_REPO"] == "${{ job.workflow_repository }}"
assert vfleet["env"]["FLEET_SHA"] == "${{ job.workflow_sha }}"
cache_step = vsteps["Resolve the substituter URL"]
assert cache_step["env"]["FLEET"] == "${{ steps.fleet.outputs.ref }}"
assert '"$FLEET#packages.$RUNNER_SYSTEM.cache-substituter-url"' in cache_step["run"]
assert ".#packages.$RUNNER_SYSTEM.cache-substituter-url" not in cache_step["run"].replace(
    '"$FLEET#packages.$RUNNER_SYSTEM.cache-substituter-url"', ""
), "the substituter URL still comes from the caller's flake"

# Verification owns measurement only. Pinning moves a name that means "main's
# current build", so it belongs to promotion (pin-cache.yml); keeping it here would
# make a pin's correctness depend on the colour of a diagnostic.
assert set(workflow["jobs"]) == {"verify"}, f"verify-cache owns more than measurement: {sorted(workflow['jobs'])}"
assert "pin_name" not in str(workflow["on"]), "pinning inputs belong to pin-cache.yml"

script = next(
    s
    for s in verify["steps"]
    if s.get("name") == "Report whether the cache serves the pinned root"
)["run"]

with tempfile.TemporaryDirectory() as directory:
    root_dir = Path(directory)
    stub = root_dir / "nix"
    stub.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$*" >> "$CALLS"\n'
        'case "$1" in\n'
        "  eval) if [ -n \"${CHAOS:-}\" ]; then exit 1; fi; printf '%s' \"$ROOT\" ;;\n"
        '  path-info) case "$4" in\n'
        "    *missing*) echo \"error: path '$4' is not valid\" >&2; exit 1 ;;\n"
        "    *unreachable*) echo 'error: unable to download https://cache.invalid' >&2; exit 1 ;;\n"
        "  esac ;;\n"
        "esac\n"
    )
    stub.chmod(0o755)
    calls = root_dir / "calls"
    summary = root_dir / "summary"

    def run(root, systems="x86_64-linux aarch64-linux"):
        calls.write_text("")
        summary.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            env={
                **os.environ,
                "PATH": f"{root_dir}:{os.environ['PATH']}",
                "SYSTEMS": systems,
                "TARGETS": ".#packages",
                "SUBJECT": "cache-root",
                "CACHE": "https://cache.invalid",
                "ROOT": root,
                "CALLS": str(calls),
                "GITHUB_STEP_SUMMARY": str(summary),
                "GITHUB_SHA": "0" * 40,
            },
            text=True,
            capture_output=True,
            timeout=30,
        )
        return result, calls.read_text()

    result, log = run("/nix/store/aaaa-served")
    assert result.returncode == 0, result.stderr + result.stdout
    assert "serves .#packages.<system>.cache-root" in result.stdout, result.stdout
    assert "roots checked: 2" in summary.read_text(), summary.read_text()
    assert "unserved: 0" in summary.read_text(), summary.read_text()
    # The subject is the one pin-cache pins, one per system.
    assert ".#packages.x86_64-linux.cache-root.outPath" in log, log
    assert ".#packages.aarch64-linux.cache-root.outPath" in log, log
    assert "https://cache.invalid" in log, log

    # A miss is reported, never a failure.
    result, _ = run("/nix/store/cccc-missing")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "::error::" not in result.stdout and "::notice::" in result.stdout, result.stdout
    assert "2 of 2 pinned root(s) missing" in result.stdout, result.stdout
    assert "unserved: 2" in summary.read_text(), summary.read_text()

    # A store-query failure is this job's own, not a cache that serves nothing.
    result, _ = run("/nix/store/dddd-unreachable")
    assert result.returncode != 0, "an unreachable cache was reported as a miss"
    assert "store query failed" in result.stdout, result.stdout

    broken = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        env={
            **os.environ,
            "PATH": f"{root_dir}:{os.environ['PATH']}",
            "SYSTEMS": "x86_64-linux",
            "TARGETS": ".#packages",
            "SUBJECT": "cache-root",
            "CACHE": "https://cache.invalid",
            "ROOT": "/nix/store/aaaa-served",
            "CALLS": str(calls),
            "CHAOS": "1",
            "GITHUB_STEP_SUMMARY": str(summary),
            "GITHUB_SHA": "0" * 40,
        },
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert broken.returncode != 0, "a failing evaluation reported itself as a clean run"

print(
    "cache verification reads the pinned root of each system, reports a miss without failing, "
    "fails on its own errors, and holds no cache credential"
)

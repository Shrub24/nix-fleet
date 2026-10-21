"""Check build-push-cache.yml against its contract: the coordinator it installs, the
bootstrap cache it seeds, and the behaviour of the two scripts it cannot express
declaratively."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml


workflow = yaml.load(Path(sys.argv[1]).read_text(), Loader=yaml.BaseLoader)
metadata = json.loads(Path(sys.argv[2]).resolve().read_text())
substituter = os.environ["BOOTSTRAP_SUBSTITUTER"]
public_key = os.environ["BOOTSTRAP_PUBLIC_KEY"]

for event in ("workflow_call", "workflow_dispatch"):
    inputs = workflow["on"][event]["inputs"]
    assert inputs["runner_system"]["default"] == "aarch64-linux"
    assert inputs["systems"]["default"] == "x86_64-linux aarch64-linux"
    assert inputs["targets"]["default"] == ".#checks"
    assert inputs["profile"]["default"] == "ci", "the coordinator profile is not optional"
    assert inputs["tailnet"]["default"] == "true"
    assert inputs["ts_client_id"]["default"] == ""
    assert inputs["ts_audience"]["default"] == ""
    assert "builder_attr" not in inputs, "the old input name is gone; no alias"
assert set(workflow["on"]["workflow_call"]["secrets"]) == {"BUILDER_SSH_KEY", "FLEET_BUILDER_SSH_KEY"}
assert workflow["permissions"] == {"contents": "read", "id-token": "write"}

prepare = workflow["jobs"]["prepare"]
assert [step.get("id") for step in prepare["steps"]] == ["systems"], (
    "prepare selects a runner and nothing else: a caller's flake is not touched there"
)

build = workflow["jobs"]["build"]
assert build["runs-on"] == "${{ needs.prepare.outputs.runner }}"
steps = {step["name"]: step for step in build["steps"]}

installer = steps["Install Nix"]
bootstrap = installer["with"]["extra-conf"]
# The bootstrap cache must exist before the coordinator can be resolved, so these two
# values are stated in the workflow; they are the fleet's, not a second source.
assert f"extra-substituters = {substituter}" in bootstrap, bootstrap
assert f"extra-trusted-public-keys = {public_key}" in bootstrap, bootstrap

coordinator = steps["Install the fleet coordinator from this workflow's revision"]
env = coordinator["env"]
assert env["FLEET_REPO"] == "${{ job.workflow_repository }}"
assert env["FLEET_SHA"] == "${{ job.workflow_sha }}"
assert "github:${FLEET_REPO}/${FLEET_SHA}#packages.${RUNNER_SYSTEM}.ci-coordinator-${PROFILE}" in coordinator["run"], (
    "the flake reference must use the github: path form; `owner/repo@sha` is git-URL"
    " syntax and resolves to 404"
)
assert "@${FLEET_SHA}" not in coordinator["run"]
assert 'sudo "$coord/install.sh"' in coordinator["run"]
# The readback runs outside sudo: the installer's PATH has no nix, and the point is
# to observe the installed configuration from the caller's context.
assert coordinator["run"].index("nix config show builders") > coordinator["run"].index('sudo "$coord/install.sh"')

resolver = steps["Resolve the tailnet identity"]
assert resolver["if"] == "${{ inputs.tailnet }}"
assert resolver["env"]["COORDINATOR"] == "${{ steps.coordinator.outputs.coordinator }}"
join = steps["Join tailnet (fleet-host builders)"]
assert join["with"]["oauth-client-id"] == "${{ steps.tailscale.outputs.client-id }}"
assert join["with"]["audience"] == "${{ steps.tailscale.outputs.audience }}"
assert join["with"]["tags"] == "tag:ci"

key = steps["Install the builder SSH identity"]
assert "/etc/nix/builder_ed25519" in key["run"]
assert "chmod 0640" in key["run"], "the identity must not depend on the calling context"

assert steps["Resolve cache API URL"]["env"]["COORDINATOR"] == "${{ steps.coordinator.outputs.coordinator }}"

report = steps["Report builders and realisations"]
assert report["if"] == "always()", "reporting must run even when the build failed"
assert "GITHUB_STEP_SUMMARY" in report["run"]
assert "exit 1" not in report["run"], "an unavailable builder is reported, never a veto"
# Reporting runs after a failed build too, when the coordinator may never have
# installed: an absent machines file must be reported, not fail the step.
assert "-s /etc/nix/machines" in report["run"], report["run"]
assert "_SUMMARY" in report["run"] and "ssh failed" in report["run"]

build_step = steps["Build with the selected builder profile"]
assert build_step["id"] == "build"
build_script = build_step["run"]
assert "builders" not in build_script.replace("nix build", ""), (
    "builders belong to the coordinator; the workflow keeps runner policy only"
)


def run_script(script, env_extra, cwd_files=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        env = {**os.environ, **env_extra}
        for name, content in (cwd_files or {}).items():
            (root / name).write_text(content)
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            env=env,
            text=True,
            capture_output=True,
            timeout=30,
        )


# The resolver: overrides win, a partial override completes the audience, and an
# injected newline never reaches a job output.
coordinator_dir = {f"coordinator/tailscale.json": json.dumps(metadata)}
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / "coordinator").mkdir()
    (root / "coordinator" / "tailscale.json").write_text(json.dumps(metadata))

    def resolve(client_id, audience, expected):
        output = root / "output"
        output.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", resolver["run"]],
            env={
                **os.environ,
                "COORDINATOR": str(root / "coordinator"),
                "OVERRIDE_ID": client_id,
                "OVERRIDE_AUDIENCE": audience,
                "GITHUB_OUTPUT": str(output),
            },
            text=True,
            capture_output=True,
            timeout=10,
        )
        if expected is None:
            assert result.returncode != 0, "unsafe identity was accepted"
            assert not output.read_text(), "unsafe identity reached job outputs"
            return
        assert result.returncode == 0, result.stderr + result.stdout
        actual = dict(line.split("=", 1) for line in output.read_text().splitlines())
        assert actual == expected, actual

    resolve("", "", {"client-id": metadata["clientId"], "audience": metadata["audience"]})
    resolve("override-ci", "", {"client-id": "override-ci", "audience": "api.tailscale.com/override-ci"})
    resolve("", "custom-audience", {"client-id": metadata["clientId"], "audience": "custom-audience"})
    resolve("override-ci", "custom-audience", {"client-id": "override-ci", "audience": "custom-audience"})
    resolve("hostile\nclient", "custom-audience", None)
    resolve("override-ci", "hostile\naudience", None)

# The build step: runner policy only, and a failed build claims no outcome.
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / "nix"
    stub.write_text(
        f'#!{shutil.which("bash")}\n'
        'printf "%s\\n" "$NIX_CONFIG" > "$CAPTURE_CONFIG"\n'
        'printf "%s\\n" "$@" > "$CAPTURE_ARGS"\n'
        'exit "${BUILD_EXIT:-0}"\n'
    )
    stub.chmod(0o755)
    for systems, targets, build_exit in (
        ("x86_64-linux", "", 0),
        ("aarch64-linux", "", 0),
        ("x86_64-linux aarch64-linux", "", 0),
        ("x86_64-linux", "", 42),
    ):
        config_file = root / "config"
        args_file = root / "args"
        outcome_file = root / "outcome"
        outcome_file.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", build_script],
            env={
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "SYSTEMS": systems,
                "TARGETS": targets,
                "NIX_CONFIG": "post-build-hook = /action/hook",
                "CAPTURE_CONFIG": str(config_file),
                "CAPTURE_ARGS": str(args_file),
                "GITHUB_OUTPUT": str(outcome_file),
                "BUILD_EXIT": str(build_exit),
            },
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == build_exit, result.stderr
        # A failed build claims no outcome, so a caller cannot read a success that
        # never happened; an absent output is treated as failure.
        expected_outcome = "outcome=success\n" if build_exit == 0 else ""
        assert outcome_file.read_text() == expected_outcome, outcome_file.read_text()
        assert config_file.read_text().splitlines() == [
            "post-build-hook = /action/hook",
            "max-jobs = 1",
        ], config_file.read_text()
        assert args_file.read_text().splitlines() == [
            "run", "nixpkgs#nix-fast-build", "--", "--eval-workers", "2",
            "--eval-max-memory-size", "3072", "--max-jobs", "4", "--skip-cached",
            "--systems", systems, "--flake", targets or ".#checks",
        ]

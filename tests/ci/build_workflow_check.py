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

resolver = steps["Resolve the tailnet identity"]
assert resolver["if"] == "${{ inputs.tailnet }}"
assert resolver["env"]["COORDINATOR"] == "${{ steps.coordinator.outputs.coordinator }}"
join = steps["Join tailnet (fleet-host builders)"]
assert join["with"]["oauth-client-id"] == "${{ steps.tailscale.outputs.client-id }}"
assert join["with"]["audience"] == "${{ steps.tailscale.outputs.audience }}"
assert join["with"]["tags"] == "tag:ci"

key = steps["Install the builder SSH identity"]
assert key["env"]["BUILDER_KEY_PATH"] == "/etc/nix/builder_ed25519", (
    "the rendered ssh_config names this path"
)

# Behaviour, not the script's text: the installed identity must be the caller's file,
# at 0600. A group-readable key is not selected by OpenSSH, so the mode is the claim.
if os.geteuid() != 0:
    with tempfile.TemporaryDirectory() as directory:
        staged = Path(directory)
        (staged / "bin").mkdir()
        (staged / "bin" / "sudo").write_text("#!/bin/sh\nexec \"$@\"\n")
        (staged / "bin" / "sudo").chmod(0o755)
        target = staged / "builder_ed25519"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", key["run"]],
            env={
                **os.environ,
                "PATH": f"{staged / 'bin'}:{os.environ['PATH']}",
                "BUILDER_KEY": "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n",
                "BUILDER_KEY_PATH": str(target),
            },
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr
        stat = target.stat()
        assert stat.st_mode & 0o777 == 0o600, oct(stat.st_mode)
        assert stat.st_uid == os.getuid(), "the identity belongs to the caller"
        assert "fixture" in target.read_text()

assert steps["Resolve cache API URL"]["env"]["COORDINATOR"] == "${{ steps.coordinator.outputs.coordinator }}"

report = steps["Report builders and realisations"]
assert report["if"] == "always()", "reporting must run even when the build failed"

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


# The report runs after a failed build too, so it must never fail the job: an
# uninstalled coordinator and an unreachable builder are both facts, not verdicts.
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / "bin").mkdir()
    for name, body in (
        ("nix", "#!/bin/sh\necho 'ssh-ng://home-forge x86_64-linux /root/.ssh/key'\n"),
        ("ssh", '#!/bin/sh\nexit "${SSH_EXIT:-0}"\n'),
        ("sudo", '#!/bin/sh\nexec "$@"\n'),
    ):
        (root / "bin" / name).write_text(body)
        (root / "bin" / name).chmod(0o755)

    def report_run(machines, ssh_exit):
        machines_file = root / "machines"
        if machines is None:
            machines_file.unlink(missing_ok=True)
        else:
            machines_file.write_text(machines)
        summary = root / "summary"
        summary.write_text("")
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", report["run"]],
            env={
                **os.environ,
                "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                "MACHINES_FILE": str(machines_file),
                "GITHUB_STEP_SUMMARY": str(summary),
                "SSH_EXIT": str(ssh_exit),
            },
            text=True,
            capture_output=True,
            timeout=30,
        )

    absent = report_run(None, 1)
    assert absent.returncode == 0, absent.stderr
    assert "did not install" in absent.stdout, absent.stdout

    unreachable = report_run("ssh-ng://home-forge x86_64-linux /root/.ssh/key\n", 1)
    assert unreachable.returncode == 0, "an unavailable builder failed the report"
    assert "ssh failed" in unreachable.stdout, unreachable.stdout
    assert "configured, not proof of use" in unreachable.stdout, unreachable.stdout

    reachable = report_run("ssh-ng://home-forge x86_64-linux /root/.ssh/key\n", 0)
    assert reachable.returncode == 0 and reachable.stdout.count("ssh ok") == 2, reachable.stdout

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
                "FLEET_REPO": "Shrub24/nix-fleet",
                "FLEET_SHA": "f" * 40,
                "RUNNER_SYSTEM": "aarch64-linux",
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
        written = config_file.read_text().splitlines()
        assert not any(line.startswith("builders") for line in written), written
        assert "max-jobs = 1" in written, written
        argv = args_file.read_text().splitlines()
        assert argv[argv.index("--systems") + 1] == systems, argv
        assert argv[argv.index("--flake") + 1] == (targets or ".#checks"), argv
        assert not any("nixpkgs#" in arg for arg in argv), (
            "the build engine is resolved from the fleet revision, not the registry"
        )

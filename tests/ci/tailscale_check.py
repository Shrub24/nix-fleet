"""Exercise the workflow's public identity resolver without joining a tailnet."""

import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

import yaml


workflow = yaml.load(Path(sys.argv[1]).read_text(), Loader=yaml.BaseLoader)
metadata = Path(sys.argv[2]).resolve()
defaults = json.loads(metadata.read_text())
for event in ("workflow_call", "workflow_dispatch"):
    inputs = workflow["on"][event]["inputs"]
    assert inputs["runner_system"]["default"] == "aarch64-linux"
    assert inputs["systems"]["default"] == "x86_64-linux aarch64-linux"
    assert inputs["targets"]["default"] == ".#checks"
    assert inputs["tailnet"]["default"] == "true"
    assert inputs["ts_client_id"]["default"] == ""
    assert inputs["ts_audience"]["default"] == ""
assert set(workflow["on"]["workflow_call"]["secrets"]) == {"BUILDER_SSH_KEY", "FLEET_BUILDER_SSH_KEY"}
assert workflow["permissions"] == {"contents": "read", "id-token": "write"}
build_steps = workflow["jobs"]["build"]["steps"]
assert "refresh-oidc" not in str(build_steps)
build_script = build_steps[-1]["run"]
assert workflow["jobs"]["build"]["runs-on"] == "${{ needs.prepare.outputs.runner }}"
assert build_steps[-1]["env"]["SYSTEMS"] == "${{ needs.prepare.outputs.systems }}"
for event in ("workflow_call", "workflow_dispatch"):
    assert workflow["on"][event]["inputs"]["builder_attr"]["default"] == "ci"
builder_step = next(step for step in build_steps if step["name"] == "Install fleet builder artifacts from the registry")
assert builder_step["if"] == "${{ inputs.builder_attr != '' }}"
preflight = next(step for step in build_steps if step["name"] == "Verify the selected builders answer before scheduling")
assert preflight["if"] == "${{ inputs.builder_attr != '' }}"
assert preflight["env"]["SYSTEMS"] == "${{ needs.prepare.outputs.systems }}"
assert preflight["env"]["COORDINATOR"] == "${{ inputs.runner_system }}"
key_step = next(step for step in build_steps if step["name"] == "Set up coordinator SSH key")
preflight_script = preflight["run"]
prepare = workflow["jobs"]["prepare"]
bootstrap = prepare["steps"][:2]
assert bootstrap[0]["uses"].startswith("actions/checkout@")
assert bootstrap[1]["uses"].startswith("NixOS/nix-installer-action@")
for step in bootstrap:
    assert step["if"] == "${{ inputs.tailnet && inputs.ts_client_id == '' }}"
resolver = next(step for step in prepare["steps"] if step.get("id") == "tailscale")
assert resolver["if"] == "${{ inputs.tailnet }}"
for job_name in ("build",):
    job = workflow["jobs"][job_name]
    assert job["needs"] == "prepare"
    join = next(step for step in job["steps"] if step.get("uses", "").startswith("tailscale/github-action@"))
    assert join["if"] == "${{ inputs.tailnet }}"
    assert join["with"]["oauth-client-id"] == "${{ needs.prepare.outputs.ts-client-id }}"
    assert join["with"]["audience"] == "${{ needs.prepare.outputs.ts-audience }}"

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / "nix"
    stub.write_text(f'#!{shutil.which("bash")}\nprintf "%s\\n" called >> "$CALLS"\nprintf "%s\\n" "$METADATA"\n')
    stub.chmod(0o755)

    def resolve(client_id, audience, expected, fetch):
        output = root / "output"
        calls = root / "calls"
        output.write_text("")
        calls.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", resolver["run"]],
            env={
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "CLIENT_ID": client_id,
                "AUDIENCE": audience,
                "METADATA": str(metadata),
                "CALLS": str(calls),
                "GITHUB_OUTPUT": str(output),
            },
            text=True,
            capture_output=True,
        )
        if expected is None:
            assert result.returncode != 0, "unsafe identity was accepted"
            assert not output.read_text(), "unsafe identity reached job outputs"
        else:
            assert result.returncode == 0, result.stderr + result.stdout
            actual = dict(line.split("=", 1) for line in output.read_text().splitlines())
            assert actual == expected, actual
            assert bool(calls.read_text()) == fetch

    resolve("", "", {"client-id": defaults["clientId"], "audience": defaults["audience"]}, True)
    resolve("override-ci", "", {"client-id": "override-ci", "audience": "api.tailscale.com/override-ci"}, False)
    resolve("", "custom-audience", {"client-id": defaults["clientId"], "audience": "custom-audience"}, True)
    resolve("override-ci", "custom-audience", {"client-id": "override-ci", "audience": "custom-audience"}, False)
    resolve("hostile\nclient", "custom-audience", None, False)
    resolve("override-ci", "hostile\naudience", None, False)

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
    for profile, system, targets, builders, selection, build_exit in (
        ("", "x86_64-linux", "", "", ".#checks", 0),
        ("", "aarch64-linux", "", "", ".#checks", 0),
        ("ci", "x86_64-linux", ".#checks", "@/tmp/nix-builders", ".#checks", 0),
        ("ci", "x86_64-linux aarch64-linux", ".#checks", "@/tmp/nix-builders", ".#checks", 0),
        ("ci", "x86_64-linux", ".#checks", "@/tmp/nix-builders", ".#checks", 42),
    ):
        config_file = root / "config"
        args_file = root / "args"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", build_script],
            env={
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "BUILDER_ATTR": profile,
                "SYSTEMS": system,
                "TARGETS": targets,
                "NIX_CONFIG": "post-build-hook = /action/hook",
                "CAPTURE_CONFIG": str(config_file),
                "CAPTURE_ARGS": str(args_file),
                "BUILD_EXIT": str(build_exit),
            },
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert result.returncode == build_exit, result.stderr
        assert config_file.read_text().splitlines() == [
            "post-build-hook = /action/hook",
            f"builders = {builders}",
            "max-jobs = 1",
        ]
        assert args_file.read_text().splitlines() == [
            "run", "nixpkgs#nix-fast-build", "--", "--eval-workers", "2",
            "--eval-max-memory-size", "2048", "--max-jobs", "4", "--skip-cached", "--systems", system, "--flake", selection,
        ]

with tempfile.TemporaryDirectory() as directory:
    output = Path(directory) / "output"
    systems_script = next(step for step in prepare["steps"] if step.get("id") == "systems")["run"]
    for runner_system, selected, expected in (
        ("x86_64-linux", "x86_64-linux", {"systems": "x86_64-linux", "runner": "ubuntu-latest"}),
        ("aarch64-linux", "x86_64-linux aarch64-linux x86_64-linux", {"systems": "aarch64-linux x86_64-linux", "runner": "ubuntu-24.04-arm"}),
        ("aarch64-linux", "", None),
        ("aarch64-linux", "unsupported-linux", None),
        ("unsupported-linux", "x86_64-linux", None),
    ):
        output.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", systems_script],
            env={**os.environ, "RUNNER_SYSTEM": runner_system, "SYSTEMS": selected, "GITHUB_OUTPUT": str(output)},
            text=True,
            capture_output=True,
        )
        if expected is None:
            assert result.returncode != 0
            assert not output.read_text()
        else:
            assert result.returncode == 0, result.stderr
            actual = dict(line.split("=", 1) for line in output.read_text().splitlines())
            assert actual == expected

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / "ssh"
    stub.write_text(
        f'#!{shutil.which("bash")}\n'
        'for arg in "$@"; do case "$arg" in *@*) host=${arg#*@} ;; esac; done\n'
        'if grep -qx "$host" "$REACHABLE"; then exit 0; fi\n'
        'echo "stub: no route to $host" >&2\n'
        "exit 255\n"
    )
    stub.chmod(0o755)
    machines = Path("/tmp/nix-builders")
    machines.write_text(
        "ssh-ng://nixbuild@home-forge x86_64-linux - 4 2 big-parallel,kvm,nixos-test -\n"
        "ssh-ng://nixbuild@oci-melb-1 aarch64-linux - 4 2 big-parallel -\n"
    )
    reachable = root / "reachable"
    for selected, coordinator, answering, expected in (
        # Both systems, both builders answering.
        ("x86_64-linux aarch64-linux", "aarch64-linux", ["home-forge", "oci-melb-1"], 0),
        # The ARM coordinator cannot cover x86_64 once its builder is silent.
        ("x86_64-linux aarch64-linux", "aarch64-linux", ["oci-melb-1"], 1),
        # An x86_64 coordinator covers its own system locally.
        ("x86_64-linux aarch64-linux", "x86_64-linux", ["oci-melb-1"], 0),
        ("x86_64-linux", "aarch64-linux", ["oci-melb-1"], 1),
        # A silent builder for a system nothing else can produce.
        ("aarch64-linux", "x86_64-linux", [], 1),
        # The coordinator's own system needs no builder at all.
        ("aarch64-linux", "aarch64-linux", [], 0),
        # A silent builder whose system is not requested only warns.
        ("aarch64-linux", "aarch64-linux", ["home-forge"], 0),
    ):
        reachable.write_text("\n".join(answering) + "\n")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", preflight_script],
            env={
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "SYSTEMS": selected,
                "COORDINATOR": coordinator,
                "REACHABLE": str(reachable),
            },
            text=True,
            capture_output=True,
        )
        assert (result.returncode == 0) == (expected == 0), result.stderr + result.stdout
        if expected != 0:
            assert "no reachable builder serves" in result.stdout, result.stdout

print("CI identity, OIDC permissions, coordinator architecture and target systems, profile selection, builder reachability and checks defaults passed")

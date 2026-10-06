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
    assert inputs["tailnet"]["default"] == "true"
    assert inputs["ts_client_id"]["default"] == ""
    assert inputs["ts_audience"]["default"] == ""
assert set(workflow["on"]["workflow_call"]["secrets"]) == {"BUILDER_SSH_KEY"}
prepare = workflow["jobs"]["prepare"]
bootstrap = prepare["steps"][:2]
assert bootstrap[0]["uses"].startswith("actions/checkout@")
assert bootstrap[1]["uses"].startswith("NixOS/nix-installer-action@")
for step in bootstrap:
    assert step["if"] == "${{ inputs.tailnet && inputs.ts_client_id == '' }}"
assert prepare["steps"][2]["id"] == "tailscale"
resolver = next(step for step in prepare["steps"] if step.get("id") == "tailscale")
assert resolver["if"] == "${{ inputs.tailnet }}"
for job_name in ("fleet-build", "gha-build"):
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

print("CI Tailscale defaults, overrides, shared outputs and rejection checks passed")

"""Exercise the pin step against stubs: one pin per system, a refusal without a pin
name, and the credential boundary."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml


workflow = yaml.load(Path(sys.argv[1]).read_text(), Loader=yaml.BaseLoader)

for event in ("workflow_dispatch", "workflow_call"):
    inputs = workflow["on"][event]["inputs"]
    assert inputs["revision"]["default"] == ""
    assert inputs["pin_name"]["default"] == ""
    assert inputs["systems"]["default"] == "x86_64-linux aarch64-linux"
    # The pin subject is the artefact aggregate, not the check set.
    assert inputs["targets"]["default"] == ".#packages"

# A pin needs the private API, so this is the workflow that joins the tailnet and
# mints the OIDC token; verification deliberately does neither.
assert workflow["permissions"] == {"contents": "read", "id-token": "write"}
pin = workflow["jobs"]["pin"]
join = next(s for s in pin["steps"] if s.get("uses", "").startswith("tailscale/github-action@"))
assert join["with"]["oauth-client-id"] == "${{ steps.ts.outputs.client-id }}"
assert not any(s.get("name", "").startswith("Require the cache") for s in pin["steps"]), (
    "the pin step asserts presence by creating the pin, not by verifying first"
)

script = next(s for s in pin["steps"] if s.get("name") == "Pin one aggregate root per system")["run"]

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    calls = root / "calls"
    summary = root / "summary"

    # The stub echoes the selection, so a wrong one appears in the pinned path.
    stub_nix = root / "nix"
    stub_nix.write_text(f'#!{shutil.which("bash")}\nprintf "%s\\n" "$*" >> "$CALLS"\nprintf "root-%s\\n" "${{@: -1}}" | sed "s|.*/||"\n')
    stub_nix.chmod(0o755)

    binary = root / "bin"
    binary.mkdir()
    stub_niks3 = binary / "niks3"
    stub_niks3.write_text(f'#!{shutil.which("bash")}\nprintf "%s\\n" "$*" >> "$CALLS"\n')
    stub_niks3.chmod(0o755)

    token_script = root / "token.sh"
    token_script.write_text(f'#!{shutil.which("bash")}\necho token\n')
    token_script.chmod(0o755)

    def run(pin_name):
        calls.write_text("")
        summary.write_text("")
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            env={
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "SYSTEMS": "x86_64-linux aarch64-linux",
                "TARGETS": ".#packages",
                "PIN": pin_name,
                "API": "https://api.invalid",
                "BINARY_DIR": str(binary),
                "TOKEN_SCRIPT": f'{shutil.which("bash")} {token_script}',
                "CALLS": str(calls),
                "GITHUB_REPOSITORY": "Shrub24/nix-fleet",
                "GITHUB_STEP_SUMMARY": str(summary),
                "GITHUB_SHA": "0" * 40,
            },
            text=True,
            capture_output=True,
        )

    result = run("nix-fleet-main")
    assert result.returncode == 0, result.stderr
    created = [line for line in calls.read_text().splitlines() if line.startswith("pins create")]
    # A name that skips a system leaves its closure unprotected and silent.
    assert len(created) == 2, created
    assert "nix-fleet-main-x86_64-linux" in created[0], created
    assert "nix-fleet-main-aarch64-linux" in created[1], created
    assert all("https://api.invalid" in line for line in created), created
    assert "nix-fleet-main-<system>" in summary.read_text(), summary.read_text()

    # `auto` derives the prefix from the repository, so a consumer needs no variable.
    result = run("auto")
    assert result.returncode == 0, result.stderr
    created = [line for line in calls.read_text().splitlines() if line.startswith("pins create")]
    assert len(created) == 2, created
    # The owner is dropped: pin names share one registry, so the repository alone
    # names the prefix.
    assert "nix-fleet-main-x86_64-linux" in created[0], created
    assert "nix-fleet-main-aarch64-linux" in created[1], created
    assert "nix-fleet-main-<system>" in summary.read_text(), summary.read_text()

    # Without a name the shell would otherwise create pins called "-<system>".
    result = run("")
    assert result.returncode != 0, result.stdout
    assert "no pin name" in result.stdout, result.stdout
    assert not calls.read_text(), calls.read_text()

print("pin-cache: pin step exercised")

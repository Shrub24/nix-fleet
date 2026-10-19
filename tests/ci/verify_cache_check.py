"""Exercise the post-merge cache verifier without a cache or a tailnet.

The verify step is the repository's own claim that the cache serves what the fleet
built, so it is executed here against a stub `nix`: a served root passes, a missing
root fails naming the path, and both systems are asked. The credential boundary is
asserted structurally, because that is the property that decides whether a read
check can be run by anyone.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


workflow = yaml.load(Path(sys.argv[1]).read_text(), Loader=yaml.BaseLoader)

# Read-only verification must not carry a credential, or it becomes another place
# a pull request could reach one.
verify = workflow["jobs"]["verify"]
assert verify["permissions"] == {"contents": "read"}
assert "id-token" not in str(verify), "the verify job asks for an OIDC token"
assert "tailscale" not in str(verify), "the verify job joins the tailnet for a public read"
assert "niks3-action" not in str(verify), "the verify job needs no cache client to ask about a path"
assert verify["outputs"]["cache"] == "${{ steps.cache.outputs.url }}"

# A pin may only move after a green verify, which is what makes a failed revision
# leave the previous pin in place.
pin = workflow["jobs"]["pin"]
assert pin["needs"] == "verify"
assert "pin_name" in pin["if"], "pinning is not gated on an explicit pin name"

script = next(
    s for s in verify["steps"] if s.get("name") == "Require the cache to serve every realised root"
)["run"]

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / "nix"
    stub.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$*" >> "$CALLS"\n'
        'case "$1" in\n'
        "  eval) printf '%s\\n' \"$ROOTS\" ;;\n"
        '  path-info) case "$4" in *missing*) exit 1 ;; esac ;;\n'
        "esac\n"
    )
    stub.chmod(0o755)
    calls = root / "calls"

    def run(roots):
        calls.write_text("")
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            env={
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "SYSTEMS": "x86_64-linux aarch64-linux",
                "TARGETS": ".#checks",
                "CACHE": "https://cache.invalid",
                "ROOTS": roots,
                "CALLS": str(calls),
            },
            text=True,
            capture_output=True,
            timeout=30,
        )
        return result, calls.read_text()

    served = "/nix/store/aaaa-served\n/nix/store/bbbb-served"
    result, log = run(served)
    assert result.returncode == 0, result.stderr + result.stdout
    assert "serves every root" in result.stdout, result.stdout
    assert "::error::" not in result.stdout, result.stdout
    # A verifier that checked one system would pass while proving half the claim.
    assert ".#checks.x86_64-linux" in log and ".#checks.aarch64-linux" in log, log
    assert "https://cache.invalid" in log, log

    # A miss is the finding this workflow exists for: named per system, counted,
    # non-zero. The stub answers both systems with the same roots, so one missing
    # root is reported once per system rather than deduplicated away.
    result, _ = run(served + "\n/nix/store/cccc-missing")
    assert result.returncode != 0, result.stdout
    assert result.stdout.count("/nix/store/cccc-missing") == 2, result.stdout
    assert "2 store path(s) missing" in result.stdout, result.stdout

print(
    "cache verification passes a served root, names a missing root, asks every system, "
    "and holds no cache credential"
)

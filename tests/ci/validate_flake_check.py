"""The evaluation gate: priming is best-effort, the stock check is the verdict, and
every caller passes a reference Nix resolves as a directory rather than an indirect
flake id.

The cold-store claim itself is not asserted here: it needs a real store and a real
`nix`, which a nix check cannot provide. Its evidence is a live `validate.yml` run,
and `docs/contracts/ci.md` carries the local reproduction.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import yaml


root = Path.cwd()
load = lambda path: yaml.load(Path(path).read_text(), Loader=yaml.BaseLoader)
action = load(".github/actions/validate-flake/action.yml")
script = next(step["run"] for step in action["runs"]["steps"])

# The action's interface: an ordinary Nix flake reference. `directory` was renamed,
# so a caller that still passes it would be silently ignored by a laxer action.
declared = set(action["inputs"])
for path in [*Path(".github/workflows").glob("*.yml"), *Path(".github/templates").glob("*.yml")]:
    for step in (s for job in load(path)["jobs"].values() for s in job.get("steps", [])):
        if "validate-flake" not in step.get("uses", ""):
            continue
        unknown = set(step.get("with") or {}) - declared
        assert not unknown, f"{path}: unknown validate-flake input(s) {sorted(unknown)}"

# A bare word is an indirect flake id, not a directory: `nix flake prefetch target`
# fails with "cannot find flake 'flake:target' in the flake registries", so a caller
# that names its checkout without `./` breaks the gate for every revision.
scheme = re.compile(r"^(flake|path|github|gitlab|sourcehut|git\+[a-z]+|https?|file|tarball):")


def is_reference(value):
    return (
        value in (".", "..")
        or value.startswith(("./", "../", "/", "~/"))
        or bool(scheme.match(value))
        or value.startswith("${{")
    )


assert is_reference("./target") and is_reference("path:.") and is_reference(".")
assert not is_reference("target"), "the rule must reject the indirect form this gate shipped"
for path in [*Path(".github/workflows").glob("*.yml"), *Path(".github/templates").glob("*.yml")]:
    for step in (s for job in load(path)["jobs"].values() for s in job.get("steps", [])):
        if "validate-flake" not in step.get("uses", ""):
            continue
        reference = (step.get("with") or {}).get("flake", action["inputs"].get("flake", {}).get("default"))
        assert is_reference(reference), f"{path}: {reference!r} is not a flake reference Nix accepts"

# Behaviour: the check decides, and priming only ever warns.
with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory)
    binary = temporary / "bin"
    binary.mkdir()
    (binary / "nix").write_text(
        f"""#!{shutil.which("bash")}
set -eu
case "$1" in
  build) echo "nix build must never be called: $*" >&2; exit 3 ;;
  flake)
    case "$2" in
      prefetch) printf '{{"hash":"sha256-fixture","storePath":"/nix/store/%s-source"}}\\n' "$SOURCE" ;;
      check) exit "$CHECK_EXIT" ;;
    esac
    ;;
  eval) exit "$PRIME_EXIT" ;;
esac
"""
    )
    (binary / "nix").chmod(0o755)

    for prime_exit, check_exit, want_exit, want_warning in (
        (0, 0, 0, False),
        (1, 0, 0, True),
        (0, 1, 1, False),
        (1, 1, 1, True),
    ):
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            env={
                **os.environ,
                "PATH": f"{binary}:{os.environ['PATH']}",
                "GITHUB_ACTION_PATH": str(root / ".github/actions/validate-flake"),
                "PRIME_EXIT": str(prime_exit),
                "SOURCE": "a" * 32,
                "CHECK_EXIT": str(check_exit),
            },
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == want_exit, (prime_exit, check_exit, result.stdout, result.stderr)
        assert ("::warning::" in result.stdout) is want_warning, (
            prime_exit,
            check_exit,
            result.stdout,
        )
        assert "must never be called" not in result.stderr, "the gate built something"

print(
    "the evaluation gate passes references through, warns on a failed prime, "
    "lets the check decide the verdict, and builds nothing"
)

"""The evaluation gate primes source paths writably, then stock flake check decides."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml


root = Path.cwd()
load = lambda path: yaml.load(Path(path).read_text(), Loader=yaml.BaseLoader)

evaluate = load(".github/workflows/validate.yml")["jobs"]["evaluate"]["steps"]
step = next(step for step in evaluate if step.get("name") == "Evaluate all systems")
assert step["uses"] == "$/.github/actions/validate-flake", step
assert step["with"] == {"flake": "target"}, step
assert not any("flake check" in step.get("run", "") for step in evaluate), (
    "the evaluation command lives in the action, not in the workflow"
)

producer = load(".github/workflows/package-updates-refresh.yml")["jobs"]["update"]
steps = producer["steps"]
evaluation = next(step for step in steps if step.get("uses") == "$/.github/actions/validate-flake")
approval = next(step for step in steps if step.get("id") == "evaluate")
assert steps.index(evaluation) < steps.index(approval)
assert evaluation["if"] == "${{ steps.propose.outputs.patch == 'true' }}"
assert approval["if"] == "${{ success() && steps.propose.outputs.patch == 'true' }}"
assert producer["outputs"]["publish"] == "${{ steps.evaluate.outputs.publish }}"

template = load(".github/templates/nvfetcher-refresh.yml")["jobs"]["regenerate"]["steps"]
validation = next(step for step in template if "/validate-flake@" in step.get("uses", ""))
assert validation["with"] == {"flake": "path:."}, "regeneration must include untracked sources"

action = load(".github/actions/validate-flake/action.yml")
prime = Path(".github/actions/validate-flake/prime.nix").read_text()
for kind in ("checks", "devShells", "legacyPackages", "packages", "nixosConfigurations", "hydraJobs"):
    assert kind in prime, f"the prime does not reach {kind}, which an all-systems check evaluates"
assert "drvPath" in prime, "the prime must force derivations to instantiate their inputs"

source = "/nix/store/" + "a" * 32 + "-source"
nar_hash = "sha256-fixture"

with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory)
    target = temporary / "target"
    binary = temporary / "bin"
    target.mkdir()
    binary.mkdir()
    bash = shutil.which("bash")
    base = {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}"}

    (binary / "nix").write_text(
        f"""#!{bash}
set -eu
printf '%s\\n' "$*" | tr '\\n' ' ' >> "$CALLS"; echo >> "$CALLS"
case "$1" in
  flake)
    case "$2" in
      prefetch)
        [ "$PREFETCH" = ok ] || exit 1
        printf '{{"hash":"%s","storePath":"%s"}}\\n' "{nar_hash}" "{source}"
        ;;
      check) [ "$CHECK" = ok ] ;;
      *) echo "unexpected flake call: $*" >&2; exit 2 ;;
    esac
    ;;
  eval) [ "$PRIME" = ok ] ;;
  build) echo "nix build must never be called: $*" >&2; exit 3 ;;
  *) echo "unexpected nix call: $*" >&2; exit 2 ;;
esac
"""
    )
    (binary / "nix").chmod(0o755)

    calls = temporary / "calls"
    command = [bash, "-euo", "pipefail", "-c", action["runs"]["steps"][0]["run"]]
    for case, expected in (("ok", 0), ("prime", 0), ("prefetch", 0), ("check", 1)):
        calls.write_text("")
        env = {
            **base,
            "CALLS": str(calls),
            "PREFETCH": "fail" if case == "prefetch" else "ok",
            "PRIME": "fail" if case == "prime" else "ok",
            "CHECK": "fail" if case == "check" else "ok",
            "GITHUB_ACTION_PATH": str(root / ".github/actions/validate-flake"),
            "FLAKE": f"path:{target}" if case == "ok" else str(target),
        }
        # Deliberately run away from the target: the action names the directory.
        result = subprocess.run(command, cwd=temporary, env=env, text=True, capture_output=True)
        assert result.returncode == expected, (case, result.stdout, result.stderr)

        lines = [line.strip() for line in calls.read_text().splitlines() if line.strip()]
        assert not any(line.startswith("build") for line in lines), (case, lines)
        assert lines[-1] == f"flake check --no-build --no-write-lock-file --all-systems --option allow-import-from-derivation false {env['FLAKE']}", (
            case,
            lines,
        )
        if case in ("ok", "prime"):
            evaluation = " ".join(next(line for line in lines if line.startswith("eval ")).split())
            assert "--option allow-import-from-derivation false" in evaluation, evaluation
            ref = f'builtins.getFlake "path:{source}?narHash={nar_hash}"'
            assert f"--expr {ref}" in evaluation, evaluation
            assert " ".join(prime.split()) in evaluation, "the prime expression must be the shipped one"
        assert lines[0].startswith("flake prefetch "), (case, lines)
        if case in ("prime", "prefetch"):
            assert "::warning::" in result.stdout, (
                f"a failed prime must not hide the check's verdict ({case})",
                result.stdout,
            )
        if case == "check":
            assert "::warning::" not in result.stdout, result.stdout

print("the evaluation gate primes writably, builds nothing, and lets the check decide")

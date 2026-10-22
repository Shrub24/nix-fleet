"""Bundled procedures, successful-promotion handoff, and self-repository composition."""

import datetime
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml


root = Path.cwd()
load = lambda path: yaml.load(Path(path).read_text(), Loader=yaml.BaseLoader)
workflows = {path.stem: load(path) for path in Path(".github/workflows").glob("*.yml")}

# Adoption of the reusable build alone must not create a lifecycle: a repository
# without the automation App runs `pipeline` on every ci completion, and any job
# there that reaches the App fails. So every job must be unreachable without
# `AUTOMATION_APP_ID` — `resolve` by its guard, the rest through `needs`.
pipeline_jobs = workflows["pipeline"]["jobs"]
resolve = pipeline_jobs["resolve"]
assert "AUTOMATION_APP_ID" in resolve.get("if", ""), (
    "the pipeline must be inert in a repository that has not configured the App"
)
for name, job in pipeline_jobs.items():
    if name == "resolve":
        continue
    needs = job.get("needs") or []
    needs = [needs] if isinstance(needs, str) else needs
    assert "resolve" in needs, (
        f"pipeline job {name} can run without resolve, so a configured guard cannot reach it"
    )

candidate = workflows["candidate"]["jobs"]["prepare"]
assert not any(step.get("with", {}).get("path") == "trusted" for step in candidate["steps"]), (
    "a script checkout inside the candidate is rejected by its write-set guard"
)

consistency = workflows["validate"]["jobs"]["consistency"]["steps"]
trusted = next(step["with"] for step in consistency if step.get("with", {}).get("path") == "trusted")
assert trusted["repository"] == "${{ job.workflow_repository }}"
assert trusted["ref"] == "${{ github.repository == job.workflow_repository && 'main' || job.workflow_sha }}", (
    "the fleet's own revisions use the default branch; external callers use their pinned revision"
)
assert trusted["persist-credentials"] == "false"
guard = next(step for step in consistency if step.get("uses") == "./trusted/.github/actions/prepare-candidate")
assert guard["with"] == {"mode": "check", "directory": "target"}

promotion = workflows["promote-candidate"]["jobs"]
assert "gh workflow run" not in str(promotion), "pinning must not assume a workflow exists in the consumer"
promote_step = next(step for step in promotion["promote"]["steps"] if step.get("id") == "promote")
assert promote_step["uses"] == "$/.github/actions/promote-candidate"
assert promote_step["env"]["CANDIDATE"] == "${{ github.event.sha }}"
assert promotion["promote"]["outputs"]["promoted_sha"] == "${{ steps.promote.outputs.promoted_sha }}"
pin = promotion["pin"]
assert pin["needs"] == "promote" and "needs.promote.outputs.promoted_sha != ''" in pin["if"]
assert pin["uses"] == "$/.github/workflows/pin-cache.yml"
assert pin["with"]["revision"] == "${{ needs.promote.outputs.promoted_sha }}"
assert pin["permissions"] == {"contents": "read", "id-token": "write"}
assert "inputs.systems" in pin["with"]["systems"] and "vars.CANDIDATE_SYSTEMS" in pin["with"]["systems"]
for name in ("targets", "subject"):
    assert f"inputs.{name}" in pin["with"][name], f"retention {name} is not forwarded"

with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory)
    target = temporary / "target"
    binary = temporary / "bin"
    target.mkdir()
    binary.mkdir()
    bash = shutil.which("bash")
    base = {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}"}
    def stub(name, body):
        path = binary / name
        path.write_text(f"#!{bash}\nset -eu\n{body}\n")
        path.chmod(0o755)

    # Run the actual preparation action outside its package directory. Its files
    # must not dirty the target checkout, and unexpected edits must still fail.
    subprocess.run(["git", "init", "-q", str(target)], check=True)
    (target / "flake.nix").write_text("{}\n")
    subprocess.run(["git", "-C", str(target), "add", "flake.nix"], check=True)
    subprocess.run(["git", "-C", str(target), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
    prepare = load(".github/actions/prepare-candidate/action.yml")
    stub("nix", "exit 0")
    env = {**base, "MODE": "check", "GITHUB_ACTION_PATH": str(root / ".github/actions/prepare-candidate")}
    command = [bash, "-euo", "pipefail", "-c", prepare["runs"]["steps"][0]["run"]]
    result = subprocess.run(command, cwd=target, env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr + result.stdout
    (target / "unexpected").write_text("not owned by preparation\n")
    result = subprocess.run(command, cwd=target, env=env, text=True, capture_output=True)
    assert result.returncode != 0 and "unexpected" in result.stdout, result

    # External APIs and push are stubbed; the actual promotion procedure must
    # publish its output only after the push, never on no-op, refusal or failure.
    candidate_sha = "a" * 40
    source_sha = "b" * 40
    stub("gh", '''
case "$2" in
  */git/matching-refs/candidates)
    if [ "$CASE" != human ]; then printf 'refs/candidates/7/%s-%s\\n' "$SOURCE" "$CANDIDATE"; fi ;;
  */statuses) printf '{"creator":{"login":"fixture[bot]"},"state":"success","created_at":"%s"}\\n' "$CREATED" ;;
  */pulls/7) printf '{"state":"open","base":"main","head":"%s","labels":[]}\\n' "$SOURCE" ;;
  *) echo "unexpected API: $*" >&2; exit 2 ;;
esac''')
    stub("git", '''
case "$1" in
  fetch|merge-base) exit 0 ;;
  rev-parse) echo "$CANDIDATE" ;;
  push) echo push >> "$PUSHES"; [ "$CASE" != failed-push ] ;;
  *) echo "unexpected git: $*" >&2; exit 2 ;;
esac''')
    action = load(".github/actions/promote-candidate/action.yml")
    assert action["outputs"]["promoted_sha"]["value"] == "${{ steps.promote.outputs.promoted_sha }}"
    output = temporary / "output"
    pushes = temporary / "pushes"
    for case, success, emitted in (("human", True, False), ("failed-push", False, False), ("promoted", True, True)):
        output.write_text("")
        pushes.write_text("")
        env = {
            **base, "CASE": case, "CANDIDATE": candidate_sha, "SOURCE": source_sha,
            "APP_LOGIN": "fixture[bot]", "POLICY": "auto", "GH_TOKEN": "fixture",
            "GITHUB_REPOSITORY": "fixture/consumer", "GITHUB_OUTPUT": str(output), "PUSHES": str(pushes),
            "CREATED": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "GITHUB_ACTION_PATH": str(root / ".github/actions/promote-candidate"),
        }
        result = subprocess.run([bash, "-euo", "pipefail", "-c", action["runs"]["steps"][0]["run"]], env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == success, (case, result.stdout, result.stderr)
        assert output.read_text() == (f"promoted_sha={candidate_sha}\n" if emitted else ""), case
        assert bool(pushes.read_text()) == (case != "human"), case

print("bundled preparation stays clean; only successful promotion hands its exact revision to retention")

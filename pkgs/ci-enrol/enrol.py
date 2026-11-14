"""Reconcile each enrolled repository's forge side with the federation plan.

Per repository: the nixbot App is installed on it, auto-merge is allowed, a
`nixbot` ruleset requires the instance's checks on the retained branch, and the
nixbot project is enabled. Every step reads before it writes, so a rerun on a
reconciled repository changes nothing.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
RULESET = "nixbot"
# The admin repository role; on a personal repository this is the owner.
ADMIN_ROLE = 5


class Failed(Exception):
    """The run stops with this message."""


def send(url: str, token: str, method: str = "GET", payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        raise Failed(f"{method} {url}: {error.code} {error.read().decode().strip()}") from error
    return json.loads(body) if body else {}


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def ruleset(plan: dict, branch: str) -> dict:
    return {
        "name": RULESET,
        "target": "branch",
        "enforcement": "active",
        "conditions": {"ref_name": {"include": [f"refs/heads/{branch}"], "exclude": []}},
        # The owner keeps direct pushes; everyone else lands through the checks.
        "bypass_actors": (
            [{"actor_id": ADMIN_ROLE, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
            if plan.get("bypassAdmins", True)
            else []
        ),
        "rules": [
            {
                "type": "required_status_checks",
                "parameters": {
                    # Auto-merge never brings a branch up to date, so strict
                    # checks would stall every automated pull request.
                    "strict_required_status_checks_policy": False,
                    "required_status_checks": [
                        {"context": check, "integration_id": plan["appId"]}
                        for check in plan["requiredChecks"]
                    ],
                },
            }
        ],
    }


def reconcile(plan: dict, repository: str, entry: dict, token: str, dry_run: bool) -> list[str]:
    """Return the changes made (or, dry, that would be made) to one repository."""
    changes = []

    def write(description: str, url: str, method: str, payload: dict | None = None) -> None:
        changes.append(description)
        if not dry_run:
            send(url, token, method, payload)

    repo = send(f"{API}/repos/{repository}", token)
    installation = plan.get("installationId")
    if installation is not None:
        installed = send(f"{API}/user/installations/{installation}/repositories?per_page=100", token)
        if repo["id"] not in {r["id"] for r in installed.get("repositories", [])}:
            write(
                "install the nixbot App",
                f"{API}/user/installations/{installation}/repositories/{repo['id']}",
                "PUT",
            )
    if not repo.get("allow_auto_merge"):
        write("allow auto-merge", f"{API}/repos/{repository}", "PATCH", {"allow_auto_merge": True})

    wanted = ruleset(plan, entry.get("branch", "main"))
    existing = [r for r in send(f"{API}/repos/{repository}/rulesets", token) if r["name"] == RULESET]
    if not existing:
        write("create the nixbot ruleset", f"{API}/repos/{repository}/rulesets", "POST", wanted)
    else:
        url = f"{API}/repos/{repository}/rulesets/{existing[0]['id']}"
        current = send(url, token)
        if any(current.get(key) != value for key, value in wanted.items()):
            write("update the nixbot ruleset", url, "PUT", wanted)

    changes.append("enable the nixbot project")
    if not dry_run:
        run(["nbo", "repo", "enable", f"github/{repository}"])
    return changes


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    argv = [argument for argument in argv if argument != "--dry-run"]
    if len(argv) != 2:
        print("usage: ci-enrol [--dry-run] PLAN", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as handle:
            plan = json.load(handle)
        token = os.environ.get("GH_TOKEN") or subprocess.run(
            ["gh", "auth", "token"], check=True, capture_output=True, text=True
        ).stdout.strip()
        if not dry_run:
            os.environ.setdefault("NIXBOT_URL", plan["nixbotUrl"])
        for repository, entry in sorted(plan["repositories"].items()):
            changes = reconcile(plan, repository, entry, token, dry_run)
            print(f"{repository}: {', '.join(changes)}{' (dry run)' if dry_run else ''}")
    except (Failed, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"ci-enrol: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

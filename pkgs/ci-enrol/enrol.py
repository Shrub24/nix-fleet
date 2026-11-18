"""Enrol repositories in the nixbot instance, or withdraw them.

Enrolling enables the project in nixbot, allows auto-merge and gives the default
branch a `nixbot` ruleset requiring the instance's checks. Withdrawing removes
the ruleset before disabling, so a required check is never left that nothing will
post. Every step reads before it writes, so a rerun changes nothing.
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
    # Cloudflare's bot rules refuse urllib's default agent (error 1010) in front of nixbot.
    request.add_header("User-Agent", "nix-fleet-ci-enrol")
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


def enabled_projects(nixbot_url: str, token: str) -> set[str]:
    """nixbot's enabled GitHub projects, `owner/name`; the API lists no others."""
    listed = send(f"{nixbot_url.rstrip('/')}/api/repos", token)
    return {f"{p['owner']}/{p['name']}" for p in listed if p.get("forge", "github") == "github"}


def set_enabled(nixbot_url: str, token: str, repository: str, enabled: bool) -> None:
    action = "enable" if enabled else "disable"
    send(f"{nixbot_url.rstrip('/')}/api/repos/github/{repository}/{action}", token, "POST")


def ruleset(plan: dict) -> dict:
    return {
        "name": RULESET,
        "target": "branch",
        "enforcement": "active",
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
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
                    # GitHub returns this default; omitting it reads back as drift.
                    "do_not_enforce_on_create": False,
                    "required_status_checks": [
                        {"context": check, "integration_id": plan["appId"]}
                        for check in plan["requiredChecks"]
                    ],
                },
            }
        ],
    }


class Reconciler:
    def __init__(self, plan: dict, github: str, nixbot: str, dry_run: bool):
        self.plan, self.github, self.nixbot, self.dry_run = plan, github, nixbot, dry_run
        self.enabled = enabled_projects(plan["nixbotUrl"], nixbot)

    def write(self, changes: list[str], description: str, url: str, method: str, payload=None) -> None:
        changes.append(description)
        if not self.dry_run:
            send(url, self.github, method, payload)

    def existing_ruleset(self, repository: str) -> dict | None:
        found = [r for r in send(f"{API}/repos/{repository}/rulesets", self.github) if r["name"] == RULESET]
        return found[0] if found else None

    def enrol(self, repository: str) -> list[str]:
        changes = []
        if repository not in self.enabled:
            changes.append("enable in nixbot")
            if not self.dry_run:
                try:
                    set_enabled(self.plan["nixbotUrl"], self.nixbot, repository, True)
                except Failed as error:
                    raise Failed(f"{repository}: not enabled (is the App installed on it?): {error}") from error
        repo = send(f"{API}/repos/{repository}", self.github)
        if not repo.get("allow_auto_merge"):
            self.write(changes, "allow auto-merge", f"{API}/repos/{repository}", "PATCH", {"allow_auto_merge": True})
        wanted = ruleset(self.plan)
        existing = self.existing_ruleset(repository)
        if existing is None:
            self.write(changes, "create the nixbot ruleset", f"{API}/repos/{repository}/rulesets", "POST", wanted)
        else:
            url = f"{API}/repos/{repository}/rulesets/{existing['id']}"
            current = send(url, self.github)
            if any(current.get(key) != value for key, value in wanted.items()):
                self.write(changes, "update the nixbot ruleset", url, "PUT", wanted)
        return changes

    def withdraw(self, repository: str) -> list[str]:
        changes = []
        existing = self.existing_ruleset(repository)
        if existing is not None:
            url = f"{API}/repos/{repository}/rulesets/{existing['id']}"
            self.write(changes, "remove the nixbot ruleset", url, "DELETE")
        if repository in self.enabled:
            changes.append("disable in nixbot")
            if not self.dry_run:
                set_enabled(self.plan["nixbotUrl"], self.nixbot, repository, False)
        return changes


def current_repository() -> str:
    """The GitHub repository of the working directory's checkout."""
    try:
        return subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        raise Failed(f"no repository given and none found here: {error.stderr.strip()}") from error


USAGE = "usage: ci-enrol [--dry-run] [--withdraw] [OWNER/REPO ...]"


def main(argv: list[str]) -> int:
    flags = {argument for argument in argv[1:] if argument.startswith("-")}
    repositories = [argument for argument in argv[1:] if not argument.startswith("-")]
    if flags - {"--dry-run", "--withdraw"}:
        print(USAGE, file=sys.stderr)
        return 2
    dry_run, withdraw = "--dry-run" in flags, "--withdraw" in flags
    try:
        with open(os.environ["CI_ENROL_PLAN"], encoding="utf-8") as handle:
            plan = json.load(handle)
        github = os.environ.get("GH_TOKEN") or subprocess.run(
            ["gh", "auth", "token"], check=True, capture_output=True, text=True
        ).stdout.strip()
        reconciler = Reconciler(plan, github, os.environ["NIXBOT_TOKEN"], dry_run)
        for repository in repositories or [current_repository()]:
            changes = reconciler.withdraw(repository) if withdraw else reconciler.enrol(repository)
            summary = ", ".join(changes) or "up to date"
            print(f"{repository}: {summary}{' (dry run)' if dry_run and changes else ''}")
    except KeyError as error:
        print(f"ci-enrol: {error} is not set", file=sys.stderr)
        return 1
    except (Failed, OSError, subprocess.CalledProcessError) as error:
        print(f"ci-enrol: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

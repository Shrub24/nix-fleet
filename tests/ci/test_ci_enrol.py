"""ci-enrol's enrol and withdraw decisions, with GitHub and nixbot replaced by one stub."""

import importlib.util
import os
import unittest
from pathlib import Path

loader = importlib.util.spec_from_file_location("enrol", Path(os.environ["ENROL_SCRIPT"]))
enrol = importlib.util.module_from_spec(loader)
loader.loader.exec_module(enrol)

NIXBOT = "https://bot.example"
PLAN = {
    "appId": 42,
    "nixbotUrl": NIXBOT,
    "requiredChecks": ["nixbot/nix-eval"],
}
REPO = "owner/repo"


class Fleet:
    """GitHub repositories and nixbot's enabled set, recording every write."""

    def __init__(self, enabled=(), auto_merge=(), rulesets=None):
        self.enabled = set(enabled)
        self.auto_merge = set(auto_merge)
        self.rulesets = dict(rulesets or {})
        self.writes = []

    def __call__(self, url, token, method="GET", payload=None):
        if url.startswith(NIXBOT):
            path = url.removeprefix(NIXBOT)
            if method == "GET":
                owner_names = [r.split("/") for r in sorted(self.enabled)]
                return [{"forge": "github", "owner": o, "name": n} for o, n in owner_names]
            self.writes.append((method, path))
            return {}
        path = url.removeprefix(enrol.API)
        if method != "GET":
            self.writes.append((method, path))
            return {}
        repository = "/".join(path.split("/")[2:4])
        if path.endswith("/rulesets"):
            return [{"id": 9, "name": "nixbot"}] if repository in self.rulesets else []
        if path.endswith("/rulesets/9"):
            return self.rulesets[repository]
        return {"allow_auto_merge": repository in self.auto_merge}


class Enrol(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, enrol, "send", enrol.send)

    def reconciler(self, fleet, dry_run=False):
        enrol.send = fleet
        return enrol.Reconciler(PLAN, "gh", "bot", dry_run)

    def github_shaped(self, checks):
        """The ruleset as GitHub returns it: the sent fields plus its own."""
        wanted = enrol.ruleset(PLAN)
        rule = wanted["rules"][0]
        # Stated independently of ci-enrol's payload: GitHub always returns this default.
        parameters = dict(rule["parameters"], required_status_checks=checks, do_not_enforce_on_create=False)
        rule = dict(rule, parameters=parameters)
        return dict(wanted, rules=[rule], id=9, source=REPO, source_type="Repository")

    def enrolled(self):
        checks = enrol.ruleset(PLAN)["rules"][0]["parameters"]["required_status_checks"]
        return Fleet(enabled={REPO}, auto_merge={REPO}, rulesets={REPO: self.github_shaped(checks)})

    def test_enrolling_enables_allows_and_rules(self):
        fleet = Fleet()
        self.reconciler(fleet).enrol(REPO)
        self.assertEqual(
            fleet.writes,
            [
                ("POST", f"/api/repos/github/{REPO}/enable"),
                ("PATCH", f"/repos/{REPO}"),
                ("POST", f"/repos/{REPO}/rulesets"),
            ],
        )

    def test_an_enrolled_repository_as_github_returns_it_gets_no_writes(self):
        fleet = self.enrolled()
        self.assertEqual(self.reconciler(fleet).enrol(REPO), [])
        self.assertEqual(fleet.writes, [])

    def test_a_changed_required_check_is_rewritten_in_place(self):
        fleet = self.enrolled()
        fleet.rulesets[REPO] = self.github_shaped([{"context": "nixbot/nix-eval", "integration_id": 1}])
        self.reconciler(fleet).enrol(REPO)
        self.assertEqual(fleet.writes, [("PUT", f"/repos/{REPO}/rulesets/9")])

    def test_withdrawing_removes_the_ruleset_before_disabling(self):
        fleet = self.enrolled()
        self.reconciler(fleet).withdraw(REPO)
        self.assertEqual(
            fleet.writes,
            [("DELETE", f"/repos/{REPO}/rulesets/9"), ("POST", f"/api/repos/github/{REPO}/disable")],
        )

    def test_withdrawing_a_withdrawn_repository_gets_no_writes(self):
        fleet = Fleet(auto_merge={REPO})
        self.assertEqual(self.reconciler(fleet).withdraw(REPO), [])
        self.assertEqual(fleet.writes, [])

    def test_a_dry_run_writes_nothing(self):
        fleet = Fleet()
        changes = self.reconciler(fleet, dry_run=True).enrol(REPO)
        self.assertEqual(fleet.writes, [])
        self.assertIn("enable in nixbot", changes)


if __name__ == "__main__":
    unittest.main()

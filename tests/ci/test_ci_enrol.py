"""ci-enrol's reconcile decisions, with GitHub and nixbot replaced by one stub."""

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
    "repositories": {"owner/listed": {"branch": "main"}},
}


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


class Reconcile(unittest.TestCase):
    def setUp(self):
        self.original = enrol.send
        self.addCleanup(setattr, enrol, "send", self.original)

    def run_with(self, fleet, dry_run=False):
        enrol.send = fleet
        return enrol.Reconciler(PLAN, "gh", "bot", dry_run).run()

    def test_a_newly_listed_repository_is_enabled_allowed_and_ruled(self):
        fleet = Fleet()
        self.run_with(fleet)
        self.assertEqual(
            fleet.writes,
            [
                ("POST", "/api/repos/github/owner/listed/enable"),
                ("PATCH", "/repos/owner/listed"),
                ("POST", "/repos/owner/listed/rulesets"),
            ],
        )

    def test_a_reconciled_repository_gets_no_writes(self):
        wanted = dict(enrol.ruleset(PLAN, "main"), id=9)
        fleet = Fleet(enabled={"owner/listed"}, auto_merge={"owner/listed"}, rulesets={"owner/listed": wanted})
        self.run_with(fleet)
        self.assertEqual(fleet.writes, [])

    def test_a_drifted_ruleset_is_updated_in_place(self):
        fleet = Fleet(
            enabled={"owner/listed"},
            auto_merge={"owner/listed"},
            rulesets={"owner/listed": {"id": 9, "name": "nixbot", "rules": []}},
        )
        self.run_with(fleet)
        self.assertEqual(fleet.writes, [("PUT", "/repos/owner/listed/rulesets/9")])

    def test_an_enabled_unlisted_repository_is_disabled_and_unruled(self):
        fleet = Fleet(
            enabled={"owner/listed", "owner/gone"},
            auto_merge={"owner/listed"},
            rulesets={"owner/listed": dict(enrol.ruleset(PLAN, "main"), id=9), "owner/gone": {"id": 9}},
        )
        self.run_with(fleet)
        self.assertEqual(
            fleet.writes,
            [
                ("POST", "/api/repos/github/owner/gone/disable"),
                ("DELETE", "/repos/owner/gone/rulesets/9"),
            ],
        )

    def test_a_dry_run_writes_nothing(self):
        fleet = Fleet(enabled={"owner/gone"})
        changes = self.run_with(fleet, dry_run=True)
        self.assertEqual(fleet.writes, [])
        self.assertIn("enable in nixbot", changes["owner/listed"])
        self.assertIn("disable in nixbot", changes["owner/gone"])


if __name__ == "__main__":
    unittest.main()

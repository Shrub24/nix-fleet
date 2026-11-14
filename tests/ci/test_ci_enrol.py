"""ci-enrol's reconcile decisions, with the forge and nbo replaced by stubs."""

import importlib.util
import os
import unittest
from pathlib import Path

loader = importlib.util.spec_from_file_location("enrol", Path(os.environ["ENROL_SCRIPT"]))
enrol = importlib.util.module_from_spec(loader)
loader.loader.exec_module(enrol)

PLAN = {"appId": 42, "installationId": 7, "requiredChecks": ["nixbot/nix-eval"]}
REPO = "owner/repo"


class Forge:
    def __init__(self, installed=False, auto_merge=False, ruleset=None):
        self.repo = {"id": 1, "allow_auto_merge": auto_merge}
        self.installed = installed
        self.ruleset = ruleset
        self.writes = []

    def __call__(self, url, token, method="GET", payload=None):
        if method != "GET":
            self.writes.append((method, url.removeprefix(enrol.API)))
            return {}
        if url.endswith(f"/repos/{REPO}"):
            return self.repo
        if "/user/installations/" in url:
            return {"repositories": [{"id": 1}] if self.installed else []}
        if url.endswith("/rulesets"):
            return [] if self.ruleset is None else [{"id": 9, "name": "nixbot"}]
        if url.endswith("/rulesets/9"):
            return self.ruleset
        raise AssertionError(url)


class Reconcile(unittest.TestCase):
    def setUp(self):
        self.commands = []
        self.originals = enrol.send, enrol.run
        enrol.run = self.commands.append
        self.addCleanup(self.restore)

    def restore(self):
        enrol.send, enrol.run = self.originals

    def reconcile(self, forge, dry_run=False):
        enrol.send = forge
        return enrol.reconcile(PLAN, REPO, {"branch": "main"}, "token", dry_run)

    def test_a_new_repository_is_installed_allowed_ruled_and_enabled(self):
        forge = Forge()
        self.reconcile(forge)
        self.assertEqual(
            forge.writes,
            [
                ("PUT", "/user/installations/7/repositories/1"),
                ("PATCH", f"/repos/{REPO}"),
                ("POST", f"/repos/{REPO}/rulesets"),
            ],
        )
        self.assertEqual(self.commands, [["nbo", "repo", "enable", f"github/{REPO}"]])

    def test_a_reconciled_repository_gets_no_forge_writes(self):
        wanted = enrol.ruleset(PLAN, "main")
        forge = Forge(installed=True, auto_merge=True, ruleset=dict(wanted, id=9))
        self.reconcile(forge)
        self.assertEqual(forge.writes, [])

    def test_a_drifted_ruleset_is_updated_in_place(self):
        forge = Forge(installed=True, auto_merge=True, ruleset={"id": 9, "name": "nixbot", "rules": []})
        self.reconcile(forge)
        self.assertEqual(forge.writes, [("PUT", f"/repos/{REPO}/rulesets/9")])

    def test_a_dry_run_writes_nothing(self):
        forge = Forge()
        changes = self.reconcile(forge, dry_run=True)
        self.assertEqual(forge.writes, [])
        self.assertEqual(self.commands, [])
        self.assertIn("create the nixbot ruleset", changes)


if __name__ == "__main__":
    unittest.main()

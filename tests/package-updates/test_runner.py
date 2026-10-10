"""Offline contract tests for the shared package-update batch runner.

A fixture ``nix-update`` records each invocation and simulates success or
refusal, so selection ordering, rollback, continuation and environment flow
are provable without any upstream query.
"""

import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

from package_updates import cli
from package_updates.transaction import (
    TransactionError,
    allowed,
    staged_package,
    valid_write_set,
)

STUB = """#!{bash}
set -euo pipefail
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
name="${{!#}}"
printf '%s\\n' "$name" >> "$FIXTURE_EDITS"
printf 'target=%s\\n' "${{BIFROST_UPDATE_VERSION:-}}" >> "$FIXTURE_ENV"
if [ "$name" = "${{FIXTURE_FAIL:-}}" ]; then
  echo "fixture: $name refused" >&2
  exit 7
fi
"""


class BatchTestCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.original_path = os.environ.get("PATH", "")

        self.calls = self.root / "calls"
        self.edits = self.root / "edits"
        self.env_file = self.root / "env"

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "nix-update"
        stub.write_text(STUB.format(bash=shutil.which("bash")))
        stub.chmod(0o755)

        self.original_environ = dict(os.environ)
        self.addCleanup(self.restore_environ)
        os.environ.update(
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            FIXTURE_CALLS=str(self.calls),
            FIXTURE_EDITS=str(self.edits),
            FIXTURE_ENV=str(self.env_file),
        )

    def restore_environ(self):
        os.environ.clear()
        os.environ.update(self.original_environ)

    def jj_checkout(self):
        jj = shutil.which("jj", path=self.original_environ["PATH"])
        if jj is None:
            self.skipTest("transaction tests require jj")
        checkout = self.root / "checkout"
        checkout.mkdir()
        (checkout / "pkgs/alpha").mkdir(parents=True)
        (checkout / "pkgs/alpha/default.nix").write_text("{}\n")
        subprocess.run(
            [jj, "git", "init", str(checkout)], check=True, capture_output=True
        )
        subprocess.run(
            [jj, "new", "-m", "test baseline"],
            cwd=checkout,
            check=True,
            capture_output=True,
        )
        return checkout

    def register(self, registered, available=None, system="x86_64-linux"):
        registry = self.root / "registry.json"
        root = self.jj_checkout() if registered else self.root
        registry.write_text(
            json.dumps(
                {
                    "system": system,
                    "registered": list(registered),
                    "available": list(registered if available is None else available),
                    "root": str(root),
                    "packagePaths": {name: f"pkgs/{name}" for name in registered},
                }
            )
        )
        os.environ["PACKAGE_UPDATES_REGISTRY"] = str(registry)

    def invoked(self):
        if not self.calls.exists():
            return []
        return self.calls.read_text().splitlines()

    def edited(self):
        if not self.edits.exists():
            return []
        return self.edits.read_text().splitlines()

    def test_default_updates_the_whole_registry_in_order(self):
        self.register(["zeta", "alpha"])
        self.assertEqual(cli.main([]), 0)
        self.assertEqual(self.edited(), ["alpha", "zeta"])
        for call in self.invoked():
            self.assertIn("--flake", call)
            self.assertIn("--use-update-script", call)
            self.assertIn("--system x86_64-linux", call)

    def test_subset_selection_runs_only_the_requested_package(self):
        self.register(["alpha", "beta"])
        self.assertEqual(cli.main(["beta"]), 0)
        self.assertEqual(self.edited(), ["beta"])

    def test_write_set_defaults_and_rejects_unsafe_paths(self):
        roots = valid_write_set(("pkgs/alpha",))
        self.assertTrue(allowed("pkgs/alpha/default.nix", roots))
        self.assertFalse(allowed("pkgs/beta/default.nix", roots))
        with self.assertRaisesRegex(TransactionError, "invalid"):
            valid_write_set(("../outside",))

    def test_staging_keeps_initial_edits_and_applies_successes_cumulatively(self):
        checkout = self.jj_checkout()
        package_file = checkout / "pkgs/alpha/default.nix"
        package_file.write_text("uncommitted starting edit\n")
        user_file = checkout / "notes.txt"
        user_file.write_text("keep this edit\n")

        class Result:
            returncode = 0

        def first(candidate):
            self.assertEqual(
                (candidate / "pkgs/alpha/default.nix").read_text(),
                "uncommitted starting edit\n",
            )
            (candidate / "pkgs/alpha/default.nix").write_text("first success\n")
            return Result()

        staged_package(checkout, "alpha", ("pkgs/alpha",), first)
        self.assertEqual(package_file.read_text(), "first success\n")
        self.assertEqual(user_file.read_text(), "keep this edit\n")

        def second(candidate):
            self.assertEqual(
                (candidate / "pkgs/alpha/default.nix").read_text(),
                "first success\n",
            )
            (candidate / "pkgs/alpha/default.nix").write_text("second success\n")
            return Result()

        staged_package(checkout, "alpha", ("pkgs/alpha",), second)
        self.assertEqual(package_file.read_text(), "second success\n")
        self.assertEqual(user_file.read_text(), "keep this edit\n")

    def test_jj_workspace_stages_and_rejects_out_of_scope_updates(self):
        checkout = self.jj_checkout()
        package = checkout / "pkgs/alpha"

        class Result:
            returncode = 0

        def update(candidate):
            (candidate / "pkgs/alpha/default.nix").write_text("new\n")
            return Result()

        result, paths = staged_package(checkout, "alpha", ("pkgs/alpha",), update)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(paths, ("pkgs/alpha/default.nix",))
        self.assertEqual((package / "default.nix").read_text(), "new\n")

        def outside(candidate):
            (candidate / "docs/unowned.txt").parent.mkdir(parents=True)
            (candidate / "docs/unowned.txt").write_text("bad\n")
            return Result()

        with self.assertRaisesRegex(TransactionError, "outside declared"):
            staged_package(checkout, "alpha", ("pkgs/alpha",), outside)
        self.assertFalse((checkout / "docs/unowned.txt").exists())

        def failed_after_writes(candidate):
            (candidate / "pkgs/alpha/default.nix").write_text("partial\n")
            (candidate / "pkgs/alpha/extra.txt").write_text("partial\n")
            return type("Failure", (), {"returncode": 9})()

        failed, failed_paths = staged_package(
            checkout, "alpha", ("pkgs/alpha",), failed_after_writes
        )
        self.assertEqual(failed.returncode, 9)
        self.assertEqual(len(failed_paths), 2)
        self.assertEqual((package / "default.nix").read_text(), "new\n")
        self.assertFalse((package / "extra.txt").exists())

    def test_update_script_dispatch_uses_the_standard_interface(self):
        # Package policy reaches nix-update through passthru.updateScript;
        # the batch must not invent a second engine to run it.
        self.register(["alpha"])
        self.assertEqual(cli.main([]), 0)
        self.assertIn("--use-update-script", self.invoked()[0])

    def test_recorded_target_environment_flows_through_unchanged(self):
        self.register(["alpha"])
        os.environ["BIFROST_UPDATE_VERSION"] = "2.2.6"
        self.assertEqual(cli.main([]), 0)
        self.assertEqual(self.env_file.read_text().splitlines(), ["target=2.2.6"])

    def test_empty_registry_is_refused_before_any_update(self):
        self.register([])
        self.assertNotEqual(cli.main([]), 0)
        self.assertEqual(self.invoked(), [])

    def test_duplicate_selection_is_refused_before_any_update(self):
        self.register(["alpha", "beta"])
        self.assertNotEqual(cli.main(["alpha", "alpha"]), 0)
        self.assertEqual(self.invoked(), [])

    def test_unregistered_selection_is_refused_before_any_update(self):
        self.register(["alpha"], available=["alpha", "gamma"])
        self.assertNotEqual(cli.main(["alpha", "gamma"]), 0)
        self.assertEqual(self.invoked(), [])

    def test_missing_output_is_refused_before_any_update(self):
        self.register(["alpha", "beta"], available=["alpha"])
        self.assertNotEqual(cli.main([]), 0)
        self.assertEqual(self.invoked(), [])

    def test_failure_is_rolled_back_and_later_packages_continue(self):
        self.register(["alpha", "beta", "gamma"])
        os.environ["FIXTURE_FAIL"] = "beta"
        self.assertEqual(cli.main([]), 7)
        self.assertEqual(self.edited(), ["alpha", "beta", "gamma"])
        self.assertIn("gamma", self.invoked()[-1])


if __name__ == "__main__":
    unittest.main()
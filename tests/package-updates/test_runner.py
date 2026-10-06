"""Offline contract tests for the shared package-update batch runner.

A fixture ``nix-update`` records each invocation and simulates a successful
edit, a refused update and a package update script, so selection ordering,
preflight refusal, fail-fast behavior and environment flow-through are
provable without any upstream query.
"""

import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

from package_updates import cli

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

    def register(self, registered, available=None, system="x86_64-linux"):
        registry = self.root / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "system": system,
                    "registered": list(registered),
                    "available": list(registered if available is None else available),
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

    def test_failure_stops_the_batch_and_preserves_edits(self):
        self.register(["alpha", "beta", "gamma"])
        os.environ["FIXTURE_FAIL"] = "beta"
        self.assertEqual(cli.main([]), 7)
        self.assertEqual(self.edited(), ["alpha", "beta"])
        self.assertNotIn("gamma", self.edited())


if __name__ == "__main__":
    unittest.main()
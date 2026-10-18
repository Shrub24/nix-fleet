"""Flake input refresh: selection, deferral, registry refusals and report sections.

These tests need no jj and no network: ``nix`` is a fixture that rewrites the
named inputs' revisions in ``flake.lock`` and records its arguments.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from package_updates.report import FAILED, Entry, InputEntry, Report, input_bullet
from package_updates.runner import (
    UpdateError,
    _refresh,
    load_registry,
    lock_refresh,
    select_inputs,
)

OLD = "a" * 40
NEW = "b" * 40

NIX = """#!{python}
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["FIXTURE_NIX_CALLS"], "a") as calls:
    calls.write(" ".join(args) + "\\n")
if os.environ.get("FIXTURE_NIX_FAIL"):
    sys.exit(3)
if args[:2] == ["flake", "update"]:
    lock = pathlib.Path("flake.lock")
    data = json.loads(lock.read_text())
    for name in args[2:]:
        data["nodes"][name]["locked"]["rev"] = "{new}"
    lock.write_text(json.dumps(data))
"""


def lock_document() -> dict:
    def github(repo: str) -> dict:
        return {
            "locked": {
                "type": "github",
                "owner": "fixture",
                "repo": repo,
                "rev": OLD,
                "lastModified": 0,
            }
        }

    return {
        "root": "root",
        "version": 7,
        "nodes": {
            "root": {"inputs": {"nixpkgs": "nixpkgs", "niks3": "niks3", "sops-nix": "sops-nix"}},
            "nixpkgs": github("nixpkgs"),
            "niks3": github("niks3"),
            "sops-nix": github("sops-nix"),
        },
    }


class SelectInputsTest(unittest.TestCase):
    AVAILABLE = ["nixpkgs", "niks3", "sops-nix"]

    def test_default_refreshes_every_input_not_deferred(self):
        self.assertEqual(
            select_inputs(self.AVAILABLE, {"nixpkgs": "upstream held"}, []),
            ["niks3", "sops-nix"],
        )

    def test_an_explicit_request_overrides_deferral(self):
        self.assertEqual(
            select_inputs(self.AVAILABLE, {"nixpkgs": "upstream held"}, ["nixpkgs"]),
            ["nixpkgs"],
        )

    def test_a_deferral_naming_no_input_is_refused_by_name(self):
        with self.assertRaisesRegex(UpdateError, "deferred input is not a flake input: gone"):
            select_inputs(self.AVAILABLE, {"gone": "stale"}, [])

    def test_an_unknown_request_is_refused_by_name(self):
        with self.assertRaisesRegex(UpdateError, "not a flake input: nope"):
            select_inputs(self.AVAILABLE, {}, ["nope"])


class LockRefreshTest(unittest.TestCase):
    def test_package_only_runs_leave_the_lock_alone(self):
        self.assertIsNone(lock_refresh([], False))

    def test_the_producer_run_refreshes_every_non_deferred_input(self):
        self.assertEqual(lock_refresh([], True), [])

    def test_explicit_inputs_win_over_the_producer_flag(self):
        self.assertEqual(lock_refresh(["niks3"], True), ["niks3"])
        self.assertEqual(lock_refresh(["niks3"], False), ["niks3"])


class RegistryValidationTest(unittest.TestCase):
    def registry(self, document: dict) -> dict:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "registry.json"
        path.write_text(json.dumps({"system": "x86_64-linux", "registered": [], "available": [], **document}))
        return {"PACKAGE_UPDATES_REGISTRY": str(path)}

    def test_a_deferral_without_a_reason_is_refused_by_name(self):
        environ = self.registry({"deferredInputs": {"nixpkgs": "  "}})
        with self.assertRaisesRegex(UpdateError, "deferred input 'nixpkgs' needs a non-empty reason"):
            load_registry(environ)

    def test_a_write_set_without_a_reason_is_refused_by_name(self):
        environ = self.registry({"writeSets": {"alpha": {"paths": ["lib/shared.nix"], "reason": ""}}})
        with self.assertRaisesRegex(UpdateError, "write set for 'alpha' needs a non-empty reason"):
            load_registry(environ)

    def test_declared_write_sets_and_deferrals_reach_the_registry(self):
        registry = load_registry(
            self.registry(
                {
                    "writeSets": {"alpha": {"paths": ["pkgs/alpha", "lib/shared.nix"], "reason": "shared"}},
                    "deferredInputs": {"nixpkgs": "held"},
                }
            )
        )
        self.assertEqual(registry.write_sets, {"alpha": ("pkgs/alpha", "lib/shared.nix")})
        self.assertEqual(registry.deferred_inputs, {"nixpkgs": "held"})


class RefreshTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "flake.lock").write_text(json.dumps(lock_document()))
        self.calls = self.root / "calls"

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "nix"
        stub.write_text(NIX.format(python=sys.executable, new=NEW))
        stub.chmod(0o755)

        self.original_environ = dict(os.environ)
        self.addCleanup(self.restore_environ)
        os.environ.update(
            PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            FIXTURE_NIX_CALLS=str(self.calls),
        )
        os.environ.pop("FIXTURE_NIX_FAIL", None)

    def restore_environ(self):
        os.environ.clear()
        os.environ.update(self.original_environ)

    def revisions(self) -> dict[str, str]:
        lock = json.loads((self.root / "flake.lock").read_text())
        return {name: node["locked"]["rev"] for name, node in lock["nodes"].items() if "locked" in node}

    def test_a_deferred_input_keeps_its_locked_revision(self):
        entries, failure = _refresh([], {"nixpkgs": "upstream held"}, self.root)

        self.assertIsNone(failure)
        self.assertEqual(self.calls.read_text().splitlines(), ["flake update niks3 sops-nix"])
        self.assertEqual(self.revisions()["nixpkgs"], OLD)
        self.assertEqual(self.revisions()["niks3"], NEW)
        self.assertEqual([entry.name for entry in entries], ["niks3", "sops-nix"])
        self.assertEqual(entries[0].compare, f"https://github.com/fixture/niks3/compare/{OLD}...{NEW}")

    def test_everything_deferred_runs_no_nix_at_all(self):
        # `nix flake update` with no names would move every input.
        entries, failure = _refresh(
            [],
            {"nixpkgs": "held", "niks3": "held", "sops-nix": "held"},
            self.root,
        )

        self.assertEqual((entries, failure), ([], None))
        self.assertFalse(self.calls.exists())

    def test_a_failing_refresh_is_named_and_leaves_the_lock_unchanged(self):
        os.environ["FIXTURE_NIX_FAIL"] = "1"

        entries, failure = _refresh(["niks3"], {}, self.root)

        self.assertEqual(entries, [])
        self.assertIn("nix flake update niks3 failed", failure)
        self.assertEqual(self.revisions()["niks3"], OLD)


class ReportInputsTest(unittest.TestCase):
    def report(self, **kwargs) -> Report:
        input_entry = InputEntry(
            name="niks3",
            before=OLD[:12],
            after=NEW[:12],
            date="2026-10-10",
            source="github:fixture/niks3",
            compare=f"https://github.com/fixture/niks3/compare/{OLD}...{NEW}",
        )
        return Report(system="x86_64-linux", entries=(), inputs=(input_entry,), **kwargs)

    def test_moved_inputs_render_a_table_with_a_compare_link(self):
        body = self.report().markdown_text()

        self.assertIn("| Flake input | From | To | Compare |", body)
        self.assertIn(f"| `niks3` | {OLD[:12]} | {NEW[:12]} | [compare](https://github.com/fixture/niks3/compare/", body)
        self.assertNotIn("every pin is current", body)

    def test_the_document_names_inputs_and_a_failed_refresh(self):
        document = self.report(input_failure="nix flake update niks3 failed").document()

        self.assertEqual(document["inputs"][0]["name"], "niks3")
        self.assertEqual(document["inputs"][0]["version"], {"before": OLD[:12], "after": NEW[:12]})
        self.assertEqual(document["inputFailure"], "nix flake update niks3 failed")

    def test_a_failed_refresh_is_stated_in_the_pull_request_body(self):
        body = Report(
            system="x86_64-linux", entries=(), input_failure="nix flake update niks3 failed"
        ).markdown_text()

        self.assertIn("Flake input refresh did not complete: nix flake update niks3 failed", body)

    def test_a_failed_package_is_named_and_never_reported_as_current(self):
        failed = Entry("beta", FAILED, "1.0.0", "1.0.0", "none", None)
        body = Report(system="x86_64-linux", entries=(failed,)).markdown_text()

        self.assertIn("Not updated, the updater failed: `beta`. Their pins are unchanged.", body)
        self.assertNotIn("every pin is current", body)

    def test_the_stdout_line_names_both_revisions(self):
        entry = self.report().inputs[0]
        self.assertEqual(input_bullet(entry), f"• Updated input 'niks3': {OLD[:12]} → {NEW[:12]}")


if __name__ == "__main__":
    unittest.main()

"""Flake input refresh: branch inputs, registry refusals and report sections.

These tests need no jj and no network: ``nix`` is a fixture that rewrites the
named inputs' revisions in ``flake.lock`` and records its arguments. Tag inputs
are covered by test_tags.py.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from package_updates.input_policy import Override
from package_updates.report import FAILED, PARTIAL, Entry, InputEntry, Report, input_bullet
from package_updates.runner import UpdateError, _refresh, load_registry, lock_refresh

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


class LockRefreshTest(unittest.TestCase):
    def test_package_only_runs_leave_the_lock_alone(self):
        self.assertIsNone(lock_refresh([], False))

    def test_the_scheduled_run_moves_every_input_by_its_policy(self):
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

    def test_a_fixed_input_without_a_reason_is_refused_by_name(self):
        environ = self.registry({"inputs": {"nixpkgs": {"version": "fixed", "reason": "  "}}})
        with self.assertRaisesRegex(UpdateError, "input 'nixpkgs' is fixed without a reason"):
            load_registry(environ)

    def test_a_version_regex_needs_exactly_one_capture_group(self):
        for regex in ("v.*", "(v)(.*)"):
            environ = self.registry({"inputs": {"hermes": {"versionRegex": regex}}})
            with self.assertRaisesRegex(UpdateError, "input 'hermes' versionRegex needs exactly one capture group"):
                load_registry(environ)

    def test_a_write_set_without_a_reason_is_refused_by_name(self):
        environ = self.registry({"writeSets": {"alpha": {"paths": ["lib/shared.nix"], "reason": ""}}})
        with self.assertRaisesRegex(UpdateError, "write set for 'alpha' needs a non-empty reason"):
            load_registry(environ)

    def test_declared_write_sets_and_input_policy_reach_the_registry(self):
        registry = load_registry(
            self.registry(
                {
                    "writeSets": {"alpha": {"paths": ["pkgs/alpha", "lib/shared.nix"], "reason": "shared"}},
                    "inputs": {"nixpkgs": {"version": "fixed", "reason": "held", "file": "flake.nix"}},
                    "writeFlake": "/nix/store/write-flake",
                }
            )
        )
        self.assertEqual(registry.write_sets, {"alpha": ("pkgs/alpha", "lib/shared.nix")})
        self.assertEqual(
            registry.input_overrides, {"nixpkgs": Override("fixed", None, "held", "flake.nix")}
        )
        self.assertEqual(registry.write_flake, "/nix/store/write-flake")


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

    def refresh(self, requested, overrides):
        return _refresh(requested, overrides, self.root, None)

    def test_a_fixed_input_keeps_its_locked_revision(self):
        held = {"nixpkgs": Override("fixed", reason="upstream held")}
        entries, failed, failure = self.refresh([], held)

        self.assertEqual((failed, failure), ({}, None))
        self.assertEqual(self.calls.read_text().splitlines(), ["flake update niks3 sops-nix"])
        self.assertEqual(self.revisions()["nixpkgs"], OLD)
        self.assertEqual(self.revisions()["niks3"], NEW)
        self.assertEqual([entry.name for entry in entries], ["niks3", "sops-nix"])
        self.assertEqual(entries[0].compare, f"https://github.com/fixture/niks3/compare/{OLD}...{NEW}")

    def test_an_explicit_request_moves_a_fixed_input(self):
        held = {"nixpkgs": Override("fixed", reason="upstream held")}
        entries, _, failure = self.refresh(["nixpkgs"], held)

        self.assertIsNone(failure)
        self.assertEqual([entry.name for entry in entries], ["nixpkgs"])
        self.assertEqual(self.revisions()["nixpkgs"], NEW)

    def test_everything_fixed_runs_no_nix_at_all(self):
        # `nix flake update` with no names would move every input.
        held = {name: Override("fixed", reason="held") for name in ("nixpkgs", "niks3", "sops-nix")}
        self.assertEqual(self.refresh([], held), ([], {}, None))
        self.assertFalse(self.calls.exists())

    def test_a_policy_naming_no_input_is_refused_by_name(self):
        _, _, failure = self.refresh([], {"gone": Override("fixed", reason="stale")})
        self.assertEqual(failure, "input policy names no flake input: gone")

    def test_an_unknown_request_is_refused_by_name(self):
        _, _, failure = self.refresh(["nope"], {})
        self.assertEqual(failure, "not a flake input: nope")

    def test_a_failing_refresh_is_named_and_leaves_the_lock_unchanged(self):
        os.environ["FIXTURE_NIX_FAIL"] = "1"

        entries, _, failure = self.refresh(["niks3"], {})

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

    def test_a_failed_input_is_named_with_its_reason_and_makes_the_run_partial(self):
        report = Report(system="x86_64-linux", entries=(), failed_inputs=(("hermes", "rate limited"),))

        self.assertEqual(report.outcome, PARTIAL)
        self.assertIn("- `hermes`: rate limited", report.markdown_text())
        self.assertEqual(report.document()["failedInputs"], [{"name": "hermes", "reason": "rate limited"}])

    def test_a_moved_tag_links_its_release(self):
        entry = InputEntry(
            "vicinae", "v0.29.2", "v0.30.1", "—", "github:vicinaehq/vicinae",
            "https://github.com/vicinaehq/vicinae/compare/v0.29.2...v0.30.1",
            "https://github.com/vicinaehq/vicinae/releases/tag/v0.30.1",
        )
        body = Report(system="x86_64-linux", entries=(), inputs=(entry,)).markdown_text()

        self.assertIn(
            "| `vicinae` | v0.29.2 | v0.30.1 | "
            "[compare](https://github.com/vicinaehq/vicinae/compare/v0.29.2...v0.30.1) · "
            "[release](https://github.com/vicinaehq/vicinae/releases/tag/v0.30.1) |",
            body,
        )

    def test_the_stdout_line_names_both_revisions(self):
        entry = self.report().inputs[0]
        self.assertEqual(input_bullet(entry), f"• Updated input 'niks3': {OLD[:12]} → {NEW[:12]}")


if __name__ == "__main__":
    unittest.main()

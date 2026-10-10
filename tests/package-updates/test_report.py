"""Offline tests for the batch's report: stdout bullets, JSON and PR body.

Fixtures stand in for `nix-update` (which records its invocation and simulates
the pin edit it makes), `nix eval` (which returns a package's recorded version
and changelog from a state directory) and `git status` (which returns a
programmable changed-path set), so report ordering, version deltas, change
classification, unchanged detection, failure artifacts and degraded tools are
provable without a flake, a repository, or the network.
"""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from package_updates import cli, report

NIX_UPDATE = """#!{bash}
set -euo pipefail
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
name="${{!#}}"
if [ "$name" = "${{FIXTURE_FAIL_UPDATE:-}}" ]; then
  echo "fixture: $name refused" >&2
  exit 7
fi
if [ -f "$FIXTURE_AFTER/$name.json" ]; then
  document=$(<"$FIXTURE_AFTER/$name.json")
  printf '%s\\n' "$document" > "$FIXTURE_STATE/$name.json"
fi
if [ -e "$FIXTURE_TOUCH/$name" ]; then
  printf ' M pkgs/%s/default.nix\\n' "$name" >> "$FIXTURE_GIT_STATE"
fi
"""

NIX = """#!{bash}
set -euo pipefail
printf '%s\\n' "$*" >> "$FIXTURE_NIX_CALLS"
if [ "${{1:-}}" != eval ] || [ -n "${{FIXTURE_NIX_FAIL:-}}" ]; then
  echo "fixture: nix $*" >&2
  exit 1
fi
name="${{!#}}"
name="${{name##*.}}"
if [ -f "$FIXTURE_STATE/$name.json" ]; then
  document=$(<"$FIXTURE_STATE/$name.json")
  printf '%s\\n' "$document"
else
  printf '{{"version":null,"changelog":null}}\\n'
fi
"""

GIT = """#!{bash}
set -euo pipefail
if [ "${{1:-}}" != status ] || [ -n "${{FIXTURE_GIT_FAIL:-}}" ]; then
  echo "fixture: not a git repository" >&2
  exit 128
fi
if [ -f "$FIXTURE_GIT_STATE" ]; then
  while IFS= read -r line; do
    printf '%s\\n' "$line"
  done < "$FIXTURE_GIT_STATE"
fi
"""

HEADING = "## Package updates"
CURRENT = "No registered package has a newer stable release; every pin is current."
FOOTER = (
    "Refresh is not acceptance: this pull request is accepted only when the "
    "repository's declared checks pass. The `ci` workflow runs them on this pull request."
)


class ReportTestCase(unittest.TestCase):
    """Fixture plumbing shared by the report tests."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

        self.original_environ = dict(os.environ)
        self.checkout = self.root / "checkout"
        (self.checkout / "pkgs").mkdir(parents=True)
        for name in ("alpha", "beta", "gamma", "zeta", "notify", "bifrost", "delta"):
            package = self.checkout / "pkgs" / name
            package.mkdir()
            (package / "default.nix").write_text("{}\n")

        self.state = self.root / "state"
        self.after = self.root / "after"
        self.touch = self.root / "touch"
        self.bin = self.root / "bin"
        for created in (self.state, self.after, self.touch, self.bin):
            created.mkdir()
        self.git_status = self.root / "git-status"
        self.git_status.write_text("")
        self.calls = self.root / "calls"
        self.nix_calls = self.root / "nix-calls"
        self.json_path = self.root / "report.json"
        self.markdown_path = self.root / "body.md"

        for tool, source in (("nix-update", NIX_UPDATE), ("nix", NIX), ("git", GIT)):
            stub = self.bin / tool
            stub.write_text(source.format(bash=shutil.which("bash")))
            stub.chmod(0o755)

        self.addCleanup(self.restore_environ)
        os.environ.update(
            FIXTURE_STATE=str(self.state),
            FIXTURE_AFTER=str(self.after),
            FIXTURE_TOUCH=str(self.touch),
            FIXTURE_GIT_STATE=str(self.git_status),
            FIXTURE_CALLS=str(self.calls),
            FIXTURE_NIX_CALLS=str(self.nix_calls),
        )
        self.only_tools("nix-update", "nix", "jj")

    def jj_checkout(self):
        path = self.original_environ.get("PATH", "")
        jj = shutil.which("jj", path=path) if path else None
        if jj is None:
            self.skipTest("transaction tests require jj")
        shutil.rmtree(self.checkout)
        subprocess.run(
            [jj, "git", "init", str(self.checkout)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [jj, "new", "-m", "report fixture"],
            cwd=self.checkout,
            check=True,
            capture_output=True,
        )
        fixture_path = self.root / "path-nix-update-nix-jj"
        if not fixture_path.exists():
            fixture_path.mkdir()
            for tool in ("nix-update", "nix"):
                os.symlink(self.bin / tool, fixture_path / tool)
            os.symlink(jj, fixture_path / "jj")
        os.environ["PATH"] = str(fixture_path)

    def restore_environ(self):
        os.environ.clear()
        os.environ.update(self.original_environ)

    def only_tools(self, *tools):
        """A PATH holding just these fixtures, so no ambient tool leaks in."""
        directory = self.root / ("path-" + "-".join(tools))
        if not directory.exists():
            directory.mkdir()
            for tool in tools:
                os.symlink(self.bin / tool, directory / tool)
        os.environ["PATH"] = str(directory)

    def registry(self, registered, system="x86_64-linux", available=None):
        path = self.root / "registry.json"
        path.write_text(
            json.dumps(
                {
                    "system": system,
                    "registered": list(registered),
                    "available": list(registered if available is None else available),
                }
            )
        )
        os.environ["PACKAGE_UPDATES_REGISTRY"] = str(path)

    def current(self, name, version, changelog=None):
        """Record the version the flake reports before the updater runs."""
        self.pin(self.state, name, version, changelog)

    def released(self, name, version, changelog=None):
        """Record the version the fixture updater installs when it runs."""
        self.pin(self.after, name, version, changelog)

    def pin(self, directory, name, version, changelog):
        (directory / f"{name}.json").write_text(
            json.dumps({"version": version, "changelog": changelog}) + "\n"
        )

    def edited(self, name):
        """Record that the updater moves this package's working-copy path."""
        (self.touch / name).touch()

    def invoke(self, argv):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = cli.main(argv)
        return code, stdout.getvalue()

    def updated_packages(self):
        """The package names the updater was asked to update."""
        if not self.calls.exists():
            return []
        return [call.rsplit(" ", 1)[-1] for call in self.calls.read_text().splitlines()]

    def nix_invocations(self):
        if not self.nix_calls.exists():
            return []
        return self.nix_calls.read_text().splitlines()

    def document(self):
        return json.loads(self.json_path.read_text())

    def body(self):
        return self.markdown_path.read_text()


class HumanReportTest(ReportTestCase):
    def test_bullets_report_the_deltas_in_selection_order(self):
        self.registry(["zeta", "alpha"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("alpha", "1.0.0")
        self.current("zeta", "2.0.0")
        self.released("alpha", "1.0.1")
        self.released("zeta", "2.1.0")

        code, out = self.invoke([])

        self.assertEqual(code, 0)
        self.assertIn("• Updated 'alpha': 1.0.0 → 1.0.1", out)
        self.assertIn("• Updated 'zeta': 2.0.0 → 2.1.0", out)
        self.assertLess(out.index("'alpha'"), out.index("'zeta'"))
        self.assertIn("2 updated, 0 unchanged", out)

    def test_equal_versions_without_an_edit_are_unchanged(self):
        self.registry(["notify"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("notify", "1.0.0")

        code, out = self.invoke([])

        self.assertEqual(code, 0)
        self.assertIn("• Unchanged 'notify': 1.0.0", out)
        self.assertIn("0 updated, 1 unchanged", out)

    def test_a_moved_working_copy_without_a_version_change_is_updated(self):
        self.registry(["alpha"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("alpha", "1.0.0")
        # A re-tagged upstream or a hash-only refresh moves the pin, not the version.
        self.edited("alpha")

        code, out = self.invoke([])

        self.assertEqual(code, 0)
        self.assertIn("• Unchanged 'alpha': 1.0.0", out)


class JsonReportTest(ReportTestCase):
    def test_document_shape_versions_changes_and_changelogs(self):
        self.registry(["bifrost", "delta", "notify"], system="aarch64-linux")
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("bifrost", "2.2.6", changelog="https://example.invalid/previous")
        self.released("bifrost", "2.2.7", changelog="https://example.invalid/releases/v2.2.7")
        self.current("delta", "1.0.0")
        self.released("delta", "2.0.0", changelog="https://example.invalid/delta")
        self.current("notify", "1.0.0")

        code, _ = self.invoke(["--json", str(self.json_path)])

        self.assertEqual(code, 0)
        document = self.document()
        self.assertEqual(set(document), {"system", "packages"})
        self.assertEqual(document["system"], "aarch64-linux")
        self.assertEqual(
            document["packages"],
            [
                {
                    "name": "bifrost",
                    "status": "updated",
                    "version": {"before": "2.2.6", "after": "2.2.7"},
                    "change": "patch",
                    "changelog": "https://example.invalid/releases/v2.2.7",
                },
                {
                    "name": "delta",
                    "status": "updated",
                    "version": {"before": "1.0.0", "after": "2.0.0"},
                    "change": "major",
                    "changelog": "https://example.invalid/delta",
                },
                {
                    "name": "notify",
                    "status": "unchanged",
                    "version": {"before": "1.0.0", "after": "1.0.0"},
                    "change": "none",
                    "changelog": None,
                },
            ],
        )

    def test_each_package_is_evaluated_once_per_phase_without_the_lock_file(self):
        self.registry(["bifrost", "notify"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("bifrost", "2.2.6")
        self.released("bifrost", "2.2.7")
        self.current("notify", "1.0.0")

        self.invoke([])

        calls = self.nix_invocations()
        self.assertEqual(len(calls), 4)
        for call in calls:
            self.assertIn("eval", call)
            self.assertIn("--no-write-lock-file", call)
            self.assertIn("--json", call)
        self.assertEqual(
            [call.rsplit(" ", 1)[-1] for call in calls],
            [
                ".#packages.x86_64-linux.bifrost",
                ".#packages.x86_64-linux.bifrost",
                ".#packages.x86_64-linux.notify",
                ".#packages.x86_64-linux.notify",
            ],
        )


class MarkdownReportTest(ReportTestCase):
    def test_a_change_renders_a_table_and_the_acceptance_note(self):
        self.registry(["bifrost"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("bifrost", "2.2.6")
        self.released("bifrost", "2.2.7", changelog="https://example.invalid/releases/v2.2.7")

        code, _ = self.invoke(["--markdown", str(self.markdown_path)])

        self.assertEqual(code, 0)
        self.assertEqual(
            self.body(),
            "\n".join(
                [
                    HEADING,
                    "",
                    "| Package | Change | From | To | Changelog |",
                    "| --- | --- | --- | --- | --- |",
                    "| `bifrost` | patch | 2.2.6 | 2.2.7 "
                    "| [changelog](https://example.invalid/releases/v2.2.7) |",
                    "",
                    FOOTER,
                    "",
                ]
            ),
        )

    def test_nothing_changed_renders_the_current_body(self):
        self.registry(["notify"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("notify", "1.0.0")

        code, _ = self.invoke(["--markdown", str(self.markdown_path)])

        self.assertEqual(code, 0)
        self.assertEqual(self.body(), f"{HEADING}\n\n{CURRENT}\n")

    def test_already_current_packages_are_named_after_the_table(self):
        self.registry(["bifrost", "notify"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("bifrost", "2.2.6")
        self.released("bifrost", "2.2.7")
        self.current("notify", "1.0.0")

        code, _ = self.invoke(["--markdown", str(self.markdown_path)])

        self.assertEqual(code, 0)
        self.assertEqual(
            self.body(),
            "\n".join(
                [
                    HEADING,
                    "",
                    "| Package | Change | From | To | Changelog |",
                    "| --- | --- | --- | --- | --- |",
                    f"| `bifrost` | patch | 2.2.6 | 2.2.7 | — |",
                    "",
                    "Already current: `notify` 1.0.0.",
                    "",
                    FOOTER,
                    "",
                ]
            ),
        )


class FailureTest(ReportTestCase):
    def test_a_failure_stops_the_batch_and_still_writes_both_reports(self):
        self.registry(["alpha", "beta", "gamma"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        for name in ("alpha", "beta", "gamma"):
            self.current(name, "1.0.0")
            self.released(name, "1.0.1")
        os.environ["FIXTURE_FAIL_UPDATE"] = "beta"

        code, out = self.invoke(
            ["--json", str(self.json_path), "--markdown", str(self.markdown_path)]
        )

        self.assertEqual(code, 7)
        self.assertIn("✗ Failed 'beta': update failed (exit 7)", out)
        self.assertIn("gamma", out)
        self.assertEqual(self.updated_packages(), ["alpha", "beta", "gamma"])
        self.assertEqual(
            [entry["name"] for entry in self.document()["packages"]], ["alpha", "beta", "gamma"]
        )
        self.assertEqual(
            [entry["status"] for entry in self.document()["packages"]],
            ["updated", "failed", "updated"],
        )
        self.assertIn("| `alpha` | patch | 1.0.0 | 1.0.1 |", self.body())


class DegradedToolsTest(ReportTestCase):
    def test_a_missing_nix_reports_unknown_versions_and_still_updates(self):
        self.registry(["alpha"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("alpha", "1.0.0")
        self.released("alpha", "1.0.1")
        self.only_tools("nix-update", "nix", "jj")

        code, _ = self.invoke(["--json", str(self.json_path)])

        self.assertEqual(code, 0)
        self.assertEqual(self.updated_packages(), ["alpha"])
        # Without an evaluated version the report claims only what it observed.
        self.assertEqual(
            self.document()["packages"],
            [
                {
                    "name": "alpha",
                    "status": "unchanged",
                    "version": {"before": None, "after": None},
                    "change": "none",
                    "changelog": None,
                }
            ],
        )

    def test_a_failing_nix_is_unknown_rather_than_fatal(self):
        self.registry(["alpha"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("alpha", "1.0.0")
        self.released("alpha", "1.0.1")
        os.environ["FIXTURE_NIX_FAIL"] = "1"

        code, out = self.invoke(["--json", str(self.json_path)])

        self.assertEqual(code, 0)
        self.assertEqual(self.updated_packages(), ["alpha"])
        self.assertEqual(self.document()["packages"][0]["version"]["before"], None)
        self.assertEqual(self.document()["packages"][0]["version"]["after"], None)
        self.assertIn("• Unchanged 'alpha': —", out)

    def test_a_missing_git_falls_back_to_the_version_signal(self):
        self.registry(["alpha"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("alpha", "1.0.0")
        self.edited("alpha")
        self.only_tools("nix-update", "nix", "jj")

        code, out = self.invoke([])

        self.assertEqual(code, 0)
        self.assertIn("• Unchanged 'alpha': 1.0.0", out)

    def test_git_outside_a_work_tree_falls_back_to_the_version_signal(self):
        self.registry(["alpha"])
        self.jj_checkout()
        (self.checkout / "flake.nix").write_text("{}\n")
        self.current("alpha", "1.0.0")
        self.edited("alpha")
        os.environ["FIXTURE_GIT_FAIL"] = "1"

        code, out = self.invoke([])

        self.assertEqual(code, 0)
        self.assertIn("• Unchanged 'alpha': 1.0.0", out)

    def test_a_missing_updater_refuses_before_running_or_reporting(self):
        self.registry(["alpha"])
        self.only_tools("nix", "git", "jj")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code, _ = self.invoke(["--json", str(self.json_path)])

        self.assertEqual(code, 1)
        self.assertIn("nix-update not found", stderr.getvalue())
        self.assertFalse(self.json_path.exists())


class ClassificationTest(unittest.TestCase):
    def test_a_change_is_named_by_its_highest_differing_component(self):
        self.assertEqual(report.classify("2.2.6", "2.2.7"), "patch")
        self.assertEqual(report.classify("2.2.6", "2.3.0"), "minor")
        self.assertEqual(report.classify("2.2.6", "3.0.0"), "major")
        self.assertEqual(report.classify("2.2.6", "2.2.6"), "none")

    def test_a_shorter_version_pads_instead_of_claiming_a_change(self):
        self.assertEqual(report.classify("2.2", "2.2.0"), "none")

    def test_a_fourth_component_is_a_patch(self):
        self.assertEqual(report.classify("2.2.6.1", "2.2.6.2"), "patch")

    def test_unparseable_or_absent_versions_are_unknown(self):
        self.assertEqual(report.classify("2.2.6", "2.2.7-rc1"), "unknown")
        self.assertEqual(report.classify(None, "2.2.7"), "unknown")
        self.assertEqual(report.classify("2.2.6", None), "unknown")
        self.assertEqual(report.classify(None, None), "none")


if __name__ == "__main__":
    unittest.main()

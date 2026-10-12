"""Offline tests for the cheap ``--check`` contract.

The package's ``checkUpdate`` is replaced by a stub runner, so no test reaches
a forge or builds a derivation. The contract under test is the runner's
reading of the lookup: stable-version comparison, and unknown rather than a
guess whenever the lookup cannot answer.
"""

import subprocess
import unittest

from package_updates.check import CURRENT, NEWER, UNKNOWN, Finding, check_one, compare, render


def completed(code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], code, stdout=stdout, stderr=stderr)


def stub(evaluation, build=None, lookup=None):
    """Answer the three runner steps: eval, build, then the checkUpdate program."""
    import json

    def run(argv):
        if argv[0] == "nix" and argv[1] == "eval":
            return completed(stdout=json.dumps(evaluation)) if evaluation is not None else completed(code=1)
        if argv[0] == "nix" and argv[1] == "build":
            return build if build is not None else completed(stdout="/nix/store/fake-check-update\n")
        return lookup if lookup is not None else completed(stdout="2.2.7\n")

    return run


BIFROST = {"version": "2.2.6", "program": "bifrost-check-update"}


class CompareTest(unittest.TestCase):
    def test_a_newer_release_is_reported_with_both_versions(self):
        finding = compare("bifrost", "2.2.6", "2.2.7")

        self.assertEqual(finding.status, NEWER)
        self.assertEqual((finding.current, finding.latest), ("2.2.6", "2.2.7"))

    def test_versions_compare_numerically_not_lexically(self):
        self.assertEqual(compare("p", "2.9.0", "2.10.0").status, NEWER)

    def test_the_current_release_is_current(self):
        self.assertEqual(compare("bifrost", "2.2.6", "2.2.6").status, CURRENT)

    def test_a_prerelease_current_version_is_unknown_rather_than_compared(self):
        self.assertEqual(compare("p", "2.3.0-rc.1", "2.3.0").status, UNKNOWN)

    def test_a_non_stable_lookup_result_is_unknown(self):
        finding = compare("p", "1.0.0", "v2.0.0")

        self.assertEqual(finding.status, UNKNOWN)
        self.assertIn("no stable", finding.note)


class CheckOneTest(unittest.TestCase):
    def test_a_declared_checkupdate_reports_a_newer_release(self):
        finding = check_one("bifrost", "x86_64-linux", stub(BIFROST))

        self.assertEqual(finding.status, NEWER)
        self.assertEqual(finding.latest, "2.2.7")

    def test_a_package_without_checkupdate_is_unknown_not_guessed(self):
        finding = check_one("notify", "x86_64-linux", stub({"version": "1.0", "program": None}))

        self.assertEqual(finding.status, UNKNOWN)
        self.assertIn("no passthru.checkUpdate", finding.note)

    def test_an_unevaluable_package_is_unknown(self):
        finding = check_one("gone", "x86_64-linux", stub(None))

        self.assertEqual(finding.status, UNKNOWN)

    def test_a_failed_build_is_unknown(self):
        finding = check_one("bifrost", "x86_64-linux", stub(BIFROST, build=completed(code=1)))

        self.assertEqual(finding.status, UNKNOWN)
        self.assertIn("could not build", finding.note)

    def test_a_failing_lookup_reports_its_last_error_line(self):
        lookup = completed(code=128, stderr="fatal: unable to access\nfatal: could not resolve host")

        finding = check_one("bifrost", "x86_64-linux", stub(BIFROST, lookup=lookup))

        self.assertEqual(finding.status, UNKNOWN)
        self.assertIn("could not resolve host", finding.note)

    def test_an_empty_lookup_is_unknown(self):
        finding = check_one("bifrost", "x86_64-linux", stub(BIFROST, lookup=completed(stdout="\n")))

        self.assertEqual(finding.status, UNKNOWN)


class RenderTest(unittest.TestCase):
    def test_summary_counts_only_newer_packages(self):
        report = render(
            [
                Finding("bifrost", NEWER, "2.2.6", "2.2.7", ""),
                Finding("notify", UNKNOWN, "1.0", None, "no passthru.checkUpdate declared"),
            ]
        )

        self.assertIn("package-updates: 1 newer of 2 checked", report)
        self.assertIn("2.2.6 -> 2.2.7", report)


if __name__ == "__main__":
    unittest.main()

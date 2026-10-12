"""Offline tests for the interactive preview content.

``gh`` is replaced by a stub runner and ``shutil.which`` is patched, so the
tests neither reach GitHub nor depend on the host having ``gh`` installed.
"""

import subprocess
import unittest
from unittest import mock

from package_updates.interactive import EXCERPT_LINES, excerpt, release_url


def completed(stdout="", code=0):
    return subprocess.CompletedProcess([], code, stdout=stdout, stderr="")


BIFROST_CHANGELOG = "https://github.com/maximhq/bifrost/releases/tag/transports%2Fv2.2.6"


class ReleaseUrlTest(unittest.TestCase):
    def test_the_changelog_points_at_the_newest_release(self):
        self.assertEqual(
            release_url(BIFROST_CHANGELOG, "2.2.6", "2.2.7"),
            "https://github.com/maximhq/bifrost/releases/tag/transports%2Fv2.2.7",
        )

    def test_a_package_without_a_changelog_has_no_release_link(self):
        self.assertIsNone(release_url(None, "1.0", "1.1"))


class ExcerptTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch("package_updates.interactive.shutil.which", return_value="/bin/gh")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_github_release_body_is_read_for_its_repository_and_decoded_tag(self):
        seen = []

        def runner(argv, **_):
            seen.append(argv)
            return completed(stdout="Fixes things\n")

        excerpt(
            "https://github.com/maximhq/bifrost/releases/tag/transports%2Fv2.2.7",
            runner=runner,
        )

        self.assertEqual(
            seen[0][:6],
            ["gh", "release", "view", "transports/v2.2.7", "--repo", "maximhq/bifrost"],
        )

    def test_a_long_body_is_shortened_and_marked(self):
        body = "\n".join(f"line {number}" for number in range(EXCERPT_LINES + 8))

        text = excerpt(BIFROST_CHANGELOG.replace("2.2.6", "2.2.7"), runner=lambda *_, **__: completed(stdout=body))

        self.assertEqual(len(text.splitlines()), EXCERPT_LINES + 1)
        self.assertTrue(text.endswith("..."))

    def test_a_non_github_changelog_is_not_fetched(self):
        calls = []

        text = excerpt("https://example.org/notes", runner=lambda *a, **k: calls.append(a) or completed())

        self.assertIsNone(text)
        self.assertEqual(calls, [])

    def test_a_failing_lookup_shows_the_link_alone(self):
        self.assertIsNone(excerpt(BIFROST_CHANGELOG, runner=lambda *_, **__: completed(code=1)))


if __name__ == "__main__":
    unittest.main()

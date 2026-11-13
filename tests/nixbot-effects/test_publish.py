"""The publish helper's merge decision, with the network replaced by a stub.

Auto-merge is repository policy: the effect passes `--auto-merge` when a
repository wants updates landed, and the helper must never merge without it.
"""

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

PUBLISH = Path(os.environ["PUBLISH_SCRIPT"])
loader = importlib.util.spec_from_file_location("publish", PUBLISH)
publish = importlib.util.module_from_spec(loader)
loader.loader.exec_module(publish)

PULL = {"number": 7, "mergeable": True, "node_id": "PR_7"}


class Transport:
    """Records every request; answers the three calls main can make."""

    def __init__(self, pull=PULL, auto_merge_error=None):
        self.pull = pull
        self.auto_merge_error = auto_merge_error
        self.calls = []

    def __call__(self, url, token, method="GET", payload=None):
        self.calls.append((method, url, payload))
        if "/pulls?" in url:
            return [self.pull]
        if "/pulls/" in url and method == "PATCH":
            return self.pull
        if "repository(owner:" in (payload or {}).get("query", ""):
            return {"data": {"repository": {"pullRequest": {"id": "PR_7"}}}}
        if url.endswith("/graphql"):
            if self.auto_merge_error is not None:
                return {"errors": self.auto_merge_error}
            return {"data": {"enablePullRequestAutoMerge": {}}}
        return {}


class Publish(unittest.TestCase):
    def setUp(self):
        self.body = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        self.body.write("report")
        self.body.close()
        os.environ["TOKEN"] = "fixture"
        self.transport = Transport()
        self.original = publish.send
        publish.send = self.transport

    def tearDown(self):
        publish.send = self.original
        Path(self.body.name).unlink()

    def run_main(self, *flags):
        argv = [
            "publish",
            *flags,
            "https://github.com/owner/repo.git",
            "owner/repo",
            "automation/package-updates",
            "main",
            "title",
            self.body.name,
        ]
        out = io.StringIO()
        with redirect_stdout(out):
            code = publish.main(argv)
        return code, out.getvalue()

    def merges(self):
        return [c for c in self.transport.calls if "/merge" in c[1] or "graphql" in c[1]]

    def test_without_the_flag_the_pull_request_is_left_open(self):
        code, out = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("Updated pull request #7", out)
        self.assertIn("Left #7 open for review", out)
        self.assertEqual(self.merges(), [], "merged without the repository asking")

    def test_with_the_flag_auto_merge_is_requested(self):
        code, out = self.run_main("--auto-merge")
        self.assertEqual(code, 0)
        self.assertIn("Enabled auto-merge (squash) on #7", out)
        self.assertEqual(
            [c[1].rsplit("/", 1)[-1] for c in self.merges()], ["graphql", "graphql"]
        )

    def test_the_flag_is_not_mistaken_for_a_positional_argument(self):
        code, out = self.run_main("--auto-merge")
        self.assertEqual(code, 0)
        self.assertIn("Updated pull request #7", out)
        self.assertIn("Enabled auto-merge", out)

    def test_unavailable_auto_merge_merges_directly(self):
        self.transport = Transport(auto_merge_error=[{"message": "auto-merge disabled"}])
        publish.send = self.transport
        code, out = self.run_main("--auto-merge")
        self.assertEqual(code, 0)
        self.assertIn("merged #7 directly", out)
        self.assertIn("/merge", self.merges()[-1][1])

    def test_an_unmergeable_pull_request_fails_loudly(self):
        self.transport = Transport(
            pull={"number": 7, "mergeable": False},
            auto_merge_error=[{"message": "auto-merge disabled"}],
        )
        publish.send = self.transport
        code, _ = self.run_main("--auto-merge")
        self.assertEqual(code, 1)


if __name__ == "__main__":
    sys.exit(unittest.main())

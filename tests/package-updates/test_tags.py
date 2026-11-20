"""Tag-pinned inputs: classification, resolution, write-back and relock.

No network and no real Nix: ``git`` answers ``ls-remote`` for tags named in the
fixture, ``nix`` reads ``<name>.url = "…";`` lines for ``eval`` and rewrites
revisions for ``flake update``, and ``flake-edit`` moves an input to the ref the
fixture names for it.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from package_updates import input_policy
from package_updates.input_policy import (
    BRANCH,
    FIXED,
    STABLE,
    Override,
    PolicyError,
    classify,
    derive,
)
from package_updates.runner import _refresh

OLD = "a" * 40
NEW = "b" * 40

NIX = """#!{python}
import json, os, pathlib, re, sys
args = sys.argv[1:]
with open(os.environ["FIXTURE_CALLS"], "a") as calls:
    calls.write("nix " + " ".join(args[:2]) + (" " + " ".join(args[2:]) if args[:2] == ["flake", "update"] else "") + "\\n")
if args[:2] == ["eval", "--impure"]:
    path = re.search(r'import "([^"]+)"', args[-1]).group(1)
    text = pathlib.Path(path).read_text()
    print(json.dumps(dict(re.findall(r'([A-Za-z][\\w-]*)\\.url = "([^"]+)";', text))))
    sys.exit(0)
if args[:2] == ["flake", "update"]:
    if set(args[2:]) & set(os.environ.get("FIXTURE_UNLOCKABLE", "").split()):
        sys.exit(1)
    lock = pathlib.Path("flake.lock")
    data = json.loads(lock.read_text())
    for name in args[2:]:
        data["nodes"][name]["locked"]["rev"] = "{new}"
    lock.write_text(json.dumps(data))
"""

GIT = """#!{python}
import os, sys
ref = sys.argv[-1].removeprefix("refs/tags/")
sys.exit(0 if ref in os.environ.get("FIXTURE_TAGS", "").split() else 2)
"""

FLAKE_EDIT = """#!{python}
import json, os, pathlib, re, sys
args = sys.argv[1:]
flake = pathlib.Path(args[args.index("--flake") + 1])
name = args[-1]
with open(os.environ["FIXTURE_CALLS"], "a") as calls:
    calls.write(f"flake-edit {{name}}\\n")
target = json.loads(os.environ["FIXTURE_RELEASES"]).get(name)
if target is None:
    print("Failed to fetch tags for fixture/" + name + ": rate limited", file=sys.stderr)
    sys.exit(0)
text = flake.read_text()
url = re.search(name + r'\\.url = "([^"]+)";', text).group(1)
current = url.rsplit("/", 1)[1]
if current == target:
    print(f"{{name}} is already on the latest version: {{current}}.")
    sys.exit(0)
flake.write_text(text.replace(url, url.rsplit("/", 1)[0] + "/" + target))
"""

# flake-file's role: flake.nix is rendered from the module that declares the inputs.
WRITE_FLAKE = """#!/bin/sh
[ -n "$FIXTURE_BROKEN_WRITE_FLAKE" ] && exit 0
cp modules/inputs.nix flake.nix
"""


def github(repo: str, ref: str | None = None) -> dict:
    original = {"type": "github", "owner": "fixture", "repo": repo}
    if ref:
        original["ref"] = ref
    return {"locked": {**original, "rev": OLD, "lastModified": 0}, "original": original}


class DeriveTest(unittest.TestCase):
    def ls_remote(self, tags):
        return lambda argv, **_: SimpleNamespace(
            returncode=0 if argv[-1].removeprefix("refs/tags/") in tags else 2, stderr=""
        )

    def test_a_version_tag_is_stable(self):
        original = github("vicinae", "v0.29.2")["original"]
        self.assertEqual(derive(original, self.ls_remote({"v0.29.2"})), STABLE)

    def test_a_version_shaped_branch_is_a_branch(self):
        original = github("nixpkgs", "nixos-25.11")["original"]
        self.assertEqual(derive(original, self.ls_remote(set())), BRANCH)

    def test_a_revision_pin_is_fixed(self):
        self.assertEqual(derive({**github("x")["original"], "rev": OLD}), FIXED)

    def test_no_ref_is_a_branch_without_asking_the_remote(self):
        def refuse(*_, **__):
            raise AssertionError("asked the remote")

        self.assertEqual(derive(github("x")["original"], refuse), BRANCH)

    def test_an_unreachable_remote_is_named(self):
        failing = lambda *_, **__: SimpleNamespace(returncode=128, stderr="could not resolve host")
        with self.assertRaisesRegex(PolicyError, "cannot list tags of https://github.com/fixture/x"):
            derive(github("x", "v1.0.0")["original"], failing)

    def test_a_scheduled_run_skips_fixed_inputs(self):
        lock = {"nodes": {"a": github("a", "v1.0.0"), "b": github("b")}}
        policies = classify(lock, {"a": "a", "b": "b"}, {"a": Override(FIXED, reason="held")}, [])
        self.assertEqual(policies, {"b": BRANCH})


class TagMoveTest(unittest.TestCase):
    """The scheduled run over a repository with tag-pinned inputs."""

    INPUTS = {
        "hermes": "github:fixture/hermes/v0.22.4",
        "vicinae": "github:fixture/vicinae/v0.29.2",
        "nixpkgs": "github:fixture/nixpkgs/nixos-unstable",
    }

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.calls = self.root / "calls"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, text in (("nix", NIX), ("git", GIT), ("flake-edit", FLAKE_EDIT), ("write-flake", WRITE_FLAKE)):
            stub = bin_dir / name
            stub.write_text(text.format(python=sys.executable, new=NEW))
            stub.chmod(0o755)
        self.write_flake = str(bin_dir / "write-flake")

        self.lock = {
            "root": "root",
            "version": 7,
            "nodes": {
                "root": {"inputs": {name: name for name in self.INPUTS}},
                **{name: github(name, url.rsplit("/", 1)[1]) for name, url in self.INPUTS.items()},
            },
        }
        (self.root / "flake.lock").write_text(json.dumps(self.lock))
        (self.root / "modules").mkdir()
        declarations = "".join(f'  {name}.url = "{url}";\n' for name, url in self.INPUTS.items())
        (self.root / "modules" / "inputs.nix").write_text("{\n" + declarations + "}\n")
        (self.root / "flake.nix").write_text("{\n" + declarations + "}\n")

        self.original_environ = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self.original_environ)))
        os.environ.update(
            PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
            FIXTURE_CALLS=str(self.calls),
            FIXTURE_TAGS="v0.22.4 v0.29.2",
            FIXTURE_RELEASES=json.dumps({"hermes": "v0.23.3", "vicinae": "v0.30.1"}),
        )

    def run_refresh(self, overrides=None, write_flake="default"):
        overrides = overrides or {
            "hermes": Override(file="modules/inputs.nix"),
            "vicinae": Override(file="modules/inputs.nix"),
        }
        flake = self.write_flake if write_flake == "default" else write_flake
        return _refresh([], overrides, self.root, flake)

    def text(self, path: str) -> str:
        return (self.root / path).read_text()

    def revision(self, name: str) -> str:
        return json.loads(self.text("flake.lock"))["nodes"][name]["locked"]["rev"]

    def test_a_tag_moves_in_its_declaring_module_and_relocks(self):
        entries, failed, failure = self.run_refresh()

        self.assertEqual((failed, failure), ({}, None))
        moved = {entry.name: (entry.before, entry.after) for entry in entries}
        self.assertEqual(moved["hermes"], ("v0.22.4", "v0.23.3"))
        self.assertEqual(moved["vicinae"], ("v0.29.2", "v0.30.1"))
        for path in ("modules/inputs.nix", "flake.nix"):
            self.assertIn('"github:fixture/hermes/v0.23.3"', self.text(path))
        self.assertEqual(self.revision("hermes"), NEW)
        hermes = next(entry for entry in entries if entry.name == "hermes")
        self.assertEqual(hermes.compare, "https://github.com/fixture/hermes/compare/v0.22.4...v0.23.3")
        self.assertEqual(hermes.release, "https://github.com/fixture/hermes/releases/tag/v0.23.3")

    def test_branch_inputs_refresh_their_lock_and_keep_their_declaration(self):
        self.run_refresh()

        self.assertIn("nix flake update nixpkgs", self.calls.read_text().splitlines())
        self.assertEqual(self.revision("nixpkgs"), NEW)
        self.assertIn('"github:fixture/nixpkgs/nixos-unstable"', self.text("flake.nix"))

    def test_a_plain_flake_is_edited_in_place(self):
        overrides = {"hermes": Override(), "vicinae": Override()}
        entries, failed, _ = self.run_refresh(overrides, write_flake=None)

        self.assertEqual(failed, {})
        self.assertIn('"github:fixture/hermes/v0.23.3"', self.text("flake.nix"))
        self.assertIn('"github:fixture/hermes/v0.22.4"', self.text("modules/inputs.nix"))
        self.assertEqual({entry.name for entry in entries}, {"hermes", "vicinae", "nixpkgs"})

    def test_a_doubled_declaration_fails_by_name_and_the_others_still_move(self):
        module = self.root / "modules" / "inputs.nix"
        module.write_text(module.read_text() + '  # was "github:fixture/hermes/v0.22.4"\n')

        entries, failed, _ = self.run_refresh()

        self.assertIn("occurs 2 times in modules/inputs.nix", failed["hermes"])
        self.assertEqual(self.text("modules/inputs.nix").count("v0.22.4"), 2)
        self.assertEqual(self.revision("hermes"), OLD)
        self.assertIn("vicinae", {entry.name for entry in entries})

    def test_a_regeneration_that_drops_the_move_is_refused_and_restored(self):
        os.environ["FIXTURE_BROKEN_WRITE_FLAKE"] = "1"
        before = {path: self.text(path) for path in ("modules/inputs.nix", "flake.nix")}

        entries, failed, _ = self.run_refresh()

        self.assertIn("write-flake did not carry the move", failed["hermes"])
        self.assertEqual({path: self.text(path) for path in before}, before)
        self.assertEqual({entry.name for entry in entries}, {"nixpkgs"})

    def test_a_release_that_does_not_lock_is_restored(self):
        os.environ["FIXTURE_UNLOCKABLE"] = "hermes"
        lock = self.text("flake.lock")

        _, failed, _ = self.run_refresh()

        self.assertIn("the new release does not lock", failed["hermes"])
        self.assertIn('"github:fixture/hermes/v0.22.4"', self.text("modules/inputs.nix"))
        self.assertIn('"github:fixture/hermes/v0.22.4"', self.text("flake.nix"))
        self.assertEqual(json.loads(self.text("flake.lock"))["nodes"]["hermes"], json.loads(lock)["nodes"]["hermes"])

    def test_a_current_input_is_neither_moved_nor_failed(self):
        os.environ["FIXTURE_RELEASES"] = json.dumps({"hermes": "v0.22.4", "vicinae": "v0.30.1"})

        entries, failed, _ = self.run_refresh()

        self.assertEqual(failed, {})
        self.assertNotIn("hermes", {entry.name for entry in entries})

    def test_a_failed_lookup_is_reported_not_taken_for_current(self):
        os.environ["FIXTURE_RELEASES"] = json.dumps({"vicinae": "v0.30.1"})

        _, failed, _ = self.run_refresh()

        self.assertEqual(failed["hermes"], "Failed to fetch tags for fixture/hermes: rate limited")

    def test_a_flake_file_input_declared_outside_the_repository_is_refused(self):
        _, failed, _ = self.run_refresh({"vicinae": Override(file="modules/inputs.nix")})

        self.assertEqual(failed["hermes"], "input 'hermes' is not declared in a file of this repository")


if __name__ == "__main__":
    unittest.main()

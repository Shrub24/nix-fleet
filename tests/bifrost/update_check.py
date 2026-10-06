#!/usr/bin/env python3
"""Offline policy checks; real hash and ABI checks run in update acceptance."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bifrost_update", sys.argv.pop(1))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


def tag(name, revision="a" * 40):
    return {"name": name, "commit": {"sha": revision}}


class ReleasePolicy(unittest.TestCase):
    def test_only_stable_transports_and_numeric_order(self):
        tags = [tag("transports/v2.2.9"), tag("core/v99.0.0"),
                tag("transports/v2.2.11-rc1"), tag("transports/v2.2.10", "b" * 40)]
        self.assertEqual(update.select_release(tags), ("2.2.10", "b" * 40))
        self.assertEqual(update.select_release(tags, "2.2.9"), ("2.2.9", "a" * 40))

    def test_missing_or_invalid_target_fails(self):
        for target in (None, "2.2.5", "2.2.5-rc1"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                update.select_release([tag("core/v2.2.5")], target)

    def test_missing_commit_fails(self):
        with self.assertRaises(ValueError):
            update.select_release([tag("transports/v2.2.6", "not-a-commit")])

    def test_update_pins_then_refresh_coupled_dependencies(self):
        initial = ('  version = "2.2.5";\n'
                   '    rev = "' + "a" * 40 + '"; # tag transports/v2.2.5\n'
                   '    hash = "sha256-old=";\n'
                   '    vendorHash = "sha256-vendor=";\n')
        with tempfile.TemporaryDirectory() as directory:
            old_cwd = Path.cwd()
            os.chdir(directory)
            try:
                path = Path("pkgs/bifrost/default.nix")
                path.parent.mkdir(parents=True)
                path.write_text(initial)
                calls = []

                def run(command, **kwargs):
                    calls.append(command)
                    if command[0] == "nix-prefetch-url":
                        return subprocess.CompletedProcess(command, 0, stdout="base32\n")
                    if command[0] == "nix":
                        return subprocess.CompletedProcess(command, 0, stdout="sha256-new=\n")
                    self.assertIn('version = "2.2.6"', path.read_text())
                    self.assertIn('hash = "sha256-new="', path.read_text())
                    raise subprocess.CalledProcessError(1, command)

                with patch.object(update, "fetch_tags", return_value=[tag("transports/v2.2.6", "b" * 40)]), \
                     patch.object(update.subprocess, "run", side_effect=run), \
                     patch.dict(os.environ, {"BIFROST_UPDATE_VERSION": "2.2.6"}):
                    with self.assertRaises(subprocess.CalledProcessError):
                        update.main()
                self.assertEqual(calls[-1], ["nix-update", "--flake", "--version=skip",
                                            "--no-src", "--subpackage", "ui", "bifrost"])
                self.assertIn("b" * 40, path.read_text())
                self.assertIn('vendorHash = "sha256-vendor="', path.read_text())
            finally:
                os.chdir(old_cwd)

    def test_ambiguous_pin_is_not_silently_rewritten(self):
        with self.assertRaises(ValueError):
            update.replace_one('version = "1";\nversion = "2";', r'^version = .*;', 'version = "3";')


unittest.main()

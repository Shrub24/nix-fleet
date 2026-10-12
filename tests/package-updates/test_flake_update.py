"""Offline tests for flake-input change detection and the interactive mapping.

Synthetic lock dictionaries stand in for flake.lock, so no test resolves an
upstream input. The picker is exercised only through its pure row and
selection mapping; fzf itself is not driven here.
"""

import unittest

from package_updates.flake_update import changes
from package_updates.interactive import FLAKE, PACKAGE, Candidate, picked, rows


def lock(**inputs):
    nodes = {"root": {"inputs": {}}}
    for name, (rev, date) in inputs.items():
        nodes["root"]["inputs"][name] = name
        nodes[name] = {"locked": {"rev": rev, "lastModified": date}}
    return {"root": "root", "nodes": nodes}


class ChangeDetectionTest(unittest.TestCase):
    def test_reports_only_top_level_inputs_whose_locked_source_moved(self):
        old = lock(nixpkgs=("aaaaaaaaaaaaaaaa", 1_700_000_000), flake_parts=("bbbbbbbbbbbbbbbb", 1))
        new = lock(nixpkgs=("cccccccccccccccc", 1_700_000_000), flake_parts=("bbbbbbbbbbbbbbbb", 1))

        moved = changes(old, new)

        self.assertEqual([change.name for change in moved], ["nixpkgs"])
        self.assertEqual(moved[0].before, "aaaaaaaaaaaa")
        self.assertEqual(moved[0].after, "cccccccccccc")
        self.assertEqual(moved[0].date, "2023-11-14")

    def test_follows_redirections_are_not_offered_as_choices(self):
        old = {
            "root": "root",
            "nodes": {
                "root": {"inputs": {"nixpkgs": "nixpkgs", "lib": ["nixpkgs", "lib"]}},
                "nixpkgs": {"locked": {"rev": "aaaa"}},
            },
        }
        new = {
            "root": "root",
            "nodes": {
                "root": {"inputs": {"nixpkgs": "nixpkgs", "lib": ["nixpkgs", "lib"]}},
                "nixpkgs": {"locked": {"rev": "bbbb"}},
            },
        }

        self.assertEqual([change.name for change in changes(old, new)], ["nixpkgs"])


class PickerMappingTest(unittest.TestCase):
    def candidates(self):
        return [
            Candidate(FLAKE, "nixpkgs", "a -> b", "flake preview\n"),
            Candidate(PACKAGE, "bifrost", "2.2.6 -> 2.2.7", "package preview\n"),
        ]

    def test_each_row_carries_its_kind_name_summary_and_preview_index(self):
        self.assertEqual(
            rows(self.candidates()),
            "flake\tnixpkgs\ta -> b\t1\npackage\tbifrost\t2.2.6 -> 2.2.7\t2\n",
        )

    def test_picker_output_maps_back_to_the_chosen_candidates_in_any_order(self):
        chosen = picked(["package\tbifrost\t2.2.6 -> 2.2.7\t2", "flake\tnixpkgs\ta -> b\t1"], self.candidates())

        self.assertEqual([candidate.name for candidate in chosen], ["bifrost", "nixpkgs"])
        self.assertEqual({candidate.kind for candidate in chosen}, {FLAKE, PACKAGE})


if __name__ == "__main__":
    unittest.main()

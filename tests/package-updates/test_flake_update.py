"""Offline tests for the flake-input picker: change detection and selection.

Synthetic lock dictionaries stand in for flake.lock, so no test resolves an
upstream input.
"""

import unittest

from package_updates.flake_update import FlakeUpdateError, changes, parse_selection


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


class SelectionTest(unittest.TestCase):
    def test_numbers_all_and_blank_map_to_indexes(self):
        self.assertEqual(parse_selection("3, 1", 4), [1, 3])
        self.assertEqual(parse_selection("all", 2), [1, 2])
        self.assertEqual(parse_selection("", 2), [])
        self.assertEqual(parse_selection("none", 2), [])

    def test_out_of_range_or_non_numeric_entries_are_refused_by_name(self):
        for answer in ("0", "5", "nixpkgs"):
            with self.subTest(answer=answer), self.assertRaisesRegex(FlakeUpdateError, "not a listed number"):
                parse_selection(answer, 4)


if __name__ == "__main__":
    unittest.main()

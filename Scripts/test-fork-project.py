#!/usr/bin/env python3
"""Exercise explicit target retirement and upstream replay without writing files."""
import importlib.util
import json
import sys
import unittest

from pathlib import Path

spec = importlib.util.spec_from_file_location("fork_project", Path(__file__).with_name("fork-project.py"))
sys.dont_write_bytecode = True
fork_project = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fork_project)


class TargetRetirementTests(unittest.TestCase):
    def setUp(self):
        self.overrides = json.loads(fork_project.OVERRIDES.read_text())
        self.upstream = fork_project.git_show("upstream/main")

    def test_replay_matches_working_project(self):
        self.assertEqual(fork_project.apply(self.upstream, self.overrides), fork_project.PROJECT.read_text())

    def test_removal_is_idempotent_and_has_no_dangling_references(self):
        ids = self.overrides["removedObjects"]
        removed = fork_project.remove_objects(self.upstream, ids)
        self.assertEqual(fork_project.remove_objects(removed, ids), removed)
        self.assertNotIn("LumeWidgets", removed)
        for object_id in ids:
            self.assertNotIn(object_id, removed)

    def test_other_targets_and_configurations_survive(self):
        removed = fork_project.remove_objects(self.upstream, self.overrides["removedObjects"])
        configs = fork_project.configs(self.upstream)
        expected = set(configs) - set(self.overrides["removedObjects"])
        self.assertEqual(set(fork_project.configs(removed)), expected)
        self.assertIn("LumePerformanceTests", removed)
        self.assertIn("LumeUITests", removed)

    def test_unknown_scalar_reference_is_rejected(self):
        object_id = self.overrides["removedObjects"][0]
        with self.assertRaises(ValueError):
            fork_project.remove_objects(f"\t\t\tproductReference = {object_id};\n", [object_id])

    def test_invalid_ids_are_rejected(self):
        with self.assertRaises(ValueError):
            fork_project.remove_objects(self.upstream, [".*"])


if __name__ == "__main__":
    unittest.main()

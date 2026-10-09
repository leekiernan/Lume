#!/usr/bin/env python3
"""Small synthetic checks for the offline XMLTV comparison, no downloads."""

import gzip
import importlib.util
import pathlib
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("trial", pathlib.Path(__file__).with_name("epg-source-trial.py"))
sys.dont_write_bytecode = True
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


def row(start, end, title="News"):
    return {"start": start, "end": end, "title": title, "fields": {}, "description_chars": 0}


class TrialTests(unittest.TestCase):
    def test_timezone_offsets_are_converted_not_discarded(self):
        self.assertEqual(trial.timestamp("20261009010000 +0100"), trial.timestamp("20261009000000 +0000"))
        self.assertEqual(trial.timestamp("20261008170000 -0700"), trial.timestamp("20261009000000Z"))

    def test_rejects_unsupported_dates(self):
        for value in (None, "", "tomorrow", "20261309000000 +0000"):
            with self.assertRaises(ValueError):
                trial.timestamp(value)

    def test_only_exact_new_badge_is_removed(self):
        self.assertEqual(trial.normal_title("News Hour  ᴺᵉʷ"), trial.normal_title("NEWS HOUR"))
        self.assertNotEqual(trial.normal_title("News Hour New"), trial.normal_title("News Hour"))

    def test_coverage_uses_union_and_records_gaps(self):
        result = trial.coverage([row(0, 30), row(20, 40), row(50, 70)], 0, 100)
        self.assertEqual(result["coverage_pct"], 60)
        self.assertEqual([gap[2] for gap in result["gaps"]], [round(10 / 60, 1), round(30 / 60, 1)])
        self.assertEqual(result["overlapping_adjacent_rows"], 1)

    def test_current_requires_start_not_just_a_future_end(self):
        self.assertEqual(trial.coverage([row(10, 20)], 0, 30)["current"], [])

    def test_duplicate_rows_do_not_inflate_coverage(self):
        result = trial.coverage([row(0, 50), row(0, 50)], 0, 100)
        self.assertEqual(result["coverage_pct"], 50)
        self.assertEqual(result["duplicate_intervals"], 1)

    def test_fallback_never_clips_conflicting_programmes(self):
        primary = [row(0, 10), row(20, 30)]
        secondary = [row(10, 20), row(5, 15), row(30, 40)]
        self.assertEqual(trial.fallback(primary, secondary), primary + [secondary[0], secondary[2]])

    def test_diagnostic_shift_is_not_applied_to_agreement(self):
        result = trial.agreement([row(0, 60)], [row(28800, 28860)], 0, 90000)
        self.assertEqual(result["identical_titles_and_times"], 0)
        self.assertEqual(result["best_diagnostic_shift_hours"], -8)
        self.assertEqual(result["matches_after_diagnostic_shift"], 1)

    def test_streaming_scan_retains_children_and_filters_unmapped_rows(self):
        body = b'''<tv><channel id="a"><display-name>Station A</display-name></channel>
        <programme channel="a" start="20261009000000 +0000" stop="20261009010000 +0000">
        <title>News</title><sub-title>Election</sub-title><category>News</category><icon src="https://example.test/a.jpg"/></programme>
        <programme channel="b" start="20261009000000 +0000" stop="20261009010000 +0000"><title>Other</title></programme>
        <programme channel="a" start="bad" stop="bad"><title>Invalid</title></programme></tv>'''
        with tempfile.TemporaryDirectory(prefix="epg-trial-test-") as directory:
            base = pathlib.Path(directory)
            (base / "guide.xml.gz").write_bytes(gzip.compress(body))
            result = trial.scan({"name": "test", "path": "guide.xml.gz"}, base, {"a"})
            self.assertEqual(result["xml_bytes"], len(body))
            self.assertEqual(result["counts"]["programmes"], 3)
            self.assertEqual(result["counts"]["invalid_times"], 1)
            self.assertEqual(result["definitions"]["a"], ["Station A"])
            self.assertNotIn("b", result["rows"])
            self.assertEqual(result["rows"]["a"][0]["title"], "News")
            self.assertTrue(result["rows"]["a"][0]["fields"]["sub-title"])
            self.assertTrue(result["rows"]["a"][0]["fields"]["icon"])

    def test_non_xmltv_input_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="epg-trial-test-") as directory:
            base = pathlib.Path(directory)
            (base / "guide.xml").write_text("<html><body>Error</body></html>")
            with self.assertRaises(ValueError):
                trial.scan({"name": "test", "path": "guide.xml"}, base, set())


if __name__ == "__main__":
    unittest.main()

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_coverage import coverage_by_file, included, main, read_lcov


class CoverageGateTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "lcov.info"

    def write(self, text):
        self.path.write_text(text, encoding="utf-8")

    def run_gate(self, *arguments):
        with patch("sys.argv", ["coverage", str(self.path), *arguments]), contextlib.redirect_stdout(io.StringIO()):
            return main()

    def test_repeated_records_count_each_line_once_and_merge_hits(self):
        self.write("SF:lib/audio.dart\nDA:1,0\nDA:2,1\nend_of_record\n"
                   "SF:lib/audio.dart\nDA:1,3\nDA:2,0\nDA:3,0\nend_of_record\n")
        self.assertEqual(read_lcov(self.path), (3, 2))

    def test_windows_paths_and_bom_work(self):
        self.write("\ufeffSF:lib\\audio.dart\nDA:1,1,checksum\nend_of_record\n")
        self.assertEqual(coverage_by_file(self.path), {"lib/audio.dart": {1: True}})

    def test_only_generated_files_are_excluded(self):
        for source in ("lib/generated/value.dart", "lib/l10n/strings.dart", "lib/model.g.dart", "lib/model.freezed.dart", "lib/di.config.dart"):
            self.assertFalse(included(source))
        for source in ("lib/main.dart", "lib/platform/driver.dart", "lib/audio/fallback.dart"):
            self.assertTrue(included(source))

    def test_filtered_gate_counts_selected_core_only(self):
        self.write("SF:lib/audio.dart\nDA:1,1\nend_of_record\nSF:lib/ui.dart\nDA:1,0\nend_of_record\n")
        self.assertEqual(read_lcov(self.path, ["*/audio.dart"]), (1, 1))
        self.assertEqual(self.run_gate("--minimum", "100", "--include", "*/audio.dart"), 0)

    def test_threshold_is_enforced_without_rounding_up(self):
        self.write("SF:lib/audio.dart\nDA:1,1\nDA:2,1\nDA:3,0\nend_of_record\n")
        self.assertEqual(self.run_gate("--minimum", "66.66"), 0)
        self.assertEqual(self.run_gate("--minimum", "66.67"), 1)

    def test_empty_or_unmatched_report_fails_closed(self):
        self.write("SF:lib/generated/a.dart\nDA:1,1\nend_of_record\n")
        with self.assertRaisesRegex(SystemExit, "no executable"):
            self.run_gate("--minimum", "0")

    def test_record_end_prevents_stray_lines_counting(self):
        self.write("SF:lib/audio.dart\nDA:1,1\nend_of_record\nDA:2,0\n")
        self.assertEqual(read_lcov(self.path), (1, 1))

    def test_invalid_counts_fail(self):
        for line in ("DA:0,1", "DA:1,-1", "DA:x,1", "DA:1,x"):
            self.write(f"SF:lib/audio.dart\n{line}\nend_of_record\n")
            with self.assertRaises(ValueError):
                read_lcov(self.path)

    def test_invalid_thresholds_fail(self):
        self.write("SF:lib/audio.dart\nDA:1,1\nend_of_record\n")
        for value in ("nan", "inf", "-1", "101"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.run_gate("--minimum", value)


if __name__ == "__main__":
    unittest.main()

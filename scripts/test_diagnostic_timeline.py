from __future__ import annotations

import unittest
from datetime import datetime

import diagnostic_timeline as timeline


class BuildProvenanceReportTest(unittest.TestCase):
    def test_new_build_header_is_parsed(self) -> None:
        result = timeline.parse_build_provenance(
            [
                "app: tark 1.0.18+19 on android (16)",
                "build: version=1.0.18+19 "
                "commit=abcdef0123456789abcdef0123456789abcdef01 "
                "dirty=clean channel=beta builtAt=2026-08-24T04:00:00Z",
            ]
        )
        self.assertEqual(result["version"], "1.0.18+19")
        self.assertEqual(
            result["commit"], "abcdef0123456789abcdef0123456789abcdef01"
        )
        self.assertEqual(result["dirty"], "clean")
        self.assertEqual(result["channel"], "beta")

    def test_old_log_without_optional_build_header_stays_supported(self) -> None:
        self.assertIsNone(
            timeline.parse_build_provenance(
                ["app: tark 1.0.17+18 on android (14)"]
            )
        )

    def test_malformed_optional_build_line_does_not_break_old_report(self) -> None:
        self.assertIsNone(
            timeline.parse_build_provenance(
                ["build: version=1.0.18 commit=abc channel=beta"]
            )
        )


class CorrelatedTimelineTest(unittest.TestCase):
    def test_events_remain_ordered(self) -> None:
        first = datetime.fromisoformat("2026-08-24T04:00:01")
        second = datetime.fromisoformat("2026-08-24T04:00:02")
        events = timeline.correlated_transitions(
            [
                (first, "hotspot: start requested"),
                (second, "mediaProjection: capture start accepted"),
            ]
        )
        self.assertEqual(
            [event["event"] for event in events],
            [
                "hotspot: start requested",
                "mediaProjection: capture start accepted",
            ],
        )

    def test_unknown_or_sensitive_network_text_is_not_copied(self) -> None:
        events = timeline.correlated_transitions(
            [
                (None, "wifi: local=192.168.4.2 ssid=secret"),
                (None, "network: arbitrary ip=10.0.0.2"),
                (None, "network: hotspot join accepted"),
            ]
        )
        self.assertEqual(
            events,
            [{"at": None, "event": "network: hotspot join accepted"}],
        )


if __name__ == "__main__":
    unittest.main()

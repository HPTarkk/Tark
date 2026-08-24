from __future__ import annotations

import unittest

import decode_tark_log as dtl


class BuildReportProvenanceIntegrationTest(unittest.TestCase):
    def test_body_provenance_and_allowlisted_transitions_are_reported(self) -> None:
        text = "\n".join(
            [
                "08:00:00.000 --- session ride opened 2026-08-24T08:00:00.000",
                "08:00:00.010 build: version=1.0.18+19 "
                "commit=abcdef0123456789abcdef0123456789abcdef01 "
                "dirty=clean channel=beta builtAt=2026-08-24T04:00:00Z",
                "08:00:01.000 hotspot: start requested",
                "08:00:02.000 mediaProjection: capture start accepted",
                "08:00:03.000 wifi: local=192.168.4.2 ssid=must-not-leak",
            ]
        )
        report = dtl.build_report(
            {"app": "tark", "version": "1.0.18+19"}, text, None
        )

        self.assertIn("commit=abcdef0123456789abcdef0123456789abcdef01", report)
        self.assertIn("hotspot: start requested", report)
        self.assertIn("mediaProjection: capture start accepted", report)
        self.assertNotIn("192.168.4.2", report)
        self.assertNotIn("must-not-leak", report)

    def test_old_header_without_optional_provenance_still_reports(self) -> None:
        text = "\n".join(
            [
                "08:00:00.000 --- session old opened 2026-08-24T08:00:00.000",
                "08:00:01.000 app: tark 1.0.17+18 on android (14)",
            ]
        )
        report = dtl.build_report(
            {"app": "tark", "version": "1.0.17+18", "platform": "android"},
            text,
            None,
        )
        self.assertIn("session   : old", report)
        self.assertIn("commit=None", report)


if __name__ == "__main__":
    unittest.main()

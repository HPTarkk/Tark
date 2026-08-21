#!/usr/bin/env python3
"""Tests for the --report analyzer in decode_tark_log.py.

    python3 scripts/test_decode_tark_log.py

Uses only synthetic lines modeled on the real `Logger.diagnostic(...)` call
sites in `lib/` — never real device data. stdlib unittest only, no extra
dependency, matching decode_tark_log.py itself.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import decode_tark_log as dtl  # noqa: E402 — path must be set up first


def _session_text(session_id: str, opened_at: str, lines: list[str]) -> str:
    body = "\n".join(lines)
    return f"--- session {session_id} opened {opened_at}\n{body}\n"


class SplitSessionsTest(unittest.TestCase):
    def test_a_single_session_is_one_block(self) -> None:
        text = _session_text(
            "abc123",
            "2026-08-19T08:00:00.000",
            ["08:00:00.100 app: tark 1.2.3+45 on android (14)"],
        )
        sessions = dtl.split_sessions(text)
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0].session_id, "abc123")

    def test_two_sessions_never_merge(self) -> None:
        text = (
            _session_text(
                "first",
                "2026-08-19T08:00:00.000",
                [
                    "08:00:01.000 wifi: in=10(+10) out=10(+10) over 15s "
                    "peers=[] recovery=0 heard=[] routes=[] pinned=[] "
                    "dupRoute=0 staleEpoch=0 epoch=1 channel=open "
                    "rtt=40ms txLoss=? opus=20kbps/loss0%/fecon local=[] "
                    "bcast=[] sendSocket=up rxSocket=up blocked=0 errs=0 "
                    "quietFor=0s"
                ],
            )
            + _session_text(
                "second",
                "2026-08-19T09:00:00.000",
                [
                    "09:00:01.000 wifi: in=999(+999) out=999(+999) over 15s "
                    "peers=[] recovery=0 heard=[] routes=[] pinned=[] "
                    "dupRoute=0 staleEpoch=0 epoch=1 channel=open "
                    "rtt=999ms txLoss=? opus=20kbps/loss0%/fecon local=[] "
                    "bcast=[] sendSocket=up rxSocket=up blocked=0 errs=0 "
                    "quietFor=0s"
                ],
            )
        )

        sessions = dtl.split_sessions(text)
        self.assertEqual(len(sessions), 2)

        first_metrics = dtl.analyze_session(sessions[0])
        second_metrics = dtl.analyze_session(sessions[1])

        self.assertEqual(first_metrics["rtt_ms"], "40")
        self.assertEqual(first_metrics["packets_in"], "10")
        self.assertEqual(second_metrics["rtt_ms"], "999")
        self.assertEqual(second_metrics["packets_in"], "999")

    def test_lines_before_the_first_banner_are_ignored(self) -> None:
        text = (
            "08:00:00.000 stray line from a previous, unreadable run\n"
            + _session_text(
                "real",
                "2026-08-19T08:00:00.000",
                ["08:00:01.000 app: tark 1.0.0+1 on android (14)"],
            )
        )
        sessions = dtl.split_sessions(text)
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0].session_id, "real")


class MidnightRolloverTest(unittest.TestCase):
    def test_a_clock_rollover_within_a_session_advances_the_date(self) -> None:
        text = _session_text(
            "overnight",
            "2026-08-19T23:59:00.000",
            [
                "23:59:59.000 app: tark 1.0.0+1 on android (14)",
                "00:00:05.000 lifecycle: resumed",
            ],
        )
        sessions = dtl.split_sessions(text)
        self.assertEqual(len(sessions), 1)
        block = sessions[0]

        timestamps = [at for at, _ in block.timestamped_lines if at is not None]
        self.assertEqual(len(timestamps), 2)
        # The second line's clock value is *smaller* than the first's, but
        # its absolute timestamp must still be *later* — a naive same-day
        # combine would make this negative.
        self.assertGreater(timestamps[1], timestamps[0])

        duration = block.duration
        self.assertIsNotNone(duration)
        self.assertGreater(duration.total_seconds(), 0)
        # Session opened 23:59:00, closed 00:00:05 the next day: 65s, not a
        # naive same-day combine's -86335s.
        self.assertLess(duration.total_seconds(), 120)


class MetricExtractionTest(unittest.TestCase):
    def _analyze(self, lines: list[str]) -> dict:
        text = _session_text("s", "2026-08-19T08:00:00.000", lines)
        sessions = dtl.split_sessions(text)
        return dtl.analyze_session(sessions[0])

    def test_audio_session_started_line(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 audio: session started — capture 48000Hz, "
                "playback 48000Hz, wire 16000Hz/320smp frames, "
                "effectsSession=1, raw=pcm16"
            ]
        )
        self.assertEqual(metrics["capture_hz"], "48000")
        self.assertEqual(metrics["playback_hz"], "48000")
        self.assertEqual(metrics["wire_hz"], "16000")
        self.assertEqual(metrics["wire_frame_samples"], "320")

    def test_recovery_event_markers_are_counted_independently(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 wifi: liveness timeout (gen 1) — forcing rebind",
                "08:00:02.000 wifi: liveness timeout (gen 1) — forcing rebind",
                "08:00:03.000 link: OS moved us back onto the AP — "
                "rebinding sockets",
            ]
        )
        self.assertEqual(metrics["recovery_events"]["liveness_timeout"], 2)
        self.assertEqual(metrics["recovery_events"]["os_moved_back_on_ap"], 1)
        self.assertEqual(metrics["recovery_events"]["rejoin_failed"], 0)

    def test_codec_transition_markers(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 codec: Opus initialized (voice, 16000Hz)",
                "08:00:02.000 codec: Opus encoder with in-band FEC "
                "(voice, 20kbps)",
            ]
        )
        self.assertEqual(metrics["codec_events"]["opus_initialized"], 1)
        self.assertEqual(metrics["codec_events"]["opus_fec_encoder"], 1)
        self.assertEqual(metrics["codec_events"]["opus_unavailable"], 0)

    def test_playback_per_sender_stats(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 playback: sender peer pkts=100 late=2 dup=1 "
                "resync=0 concealed=3 bigGaps=1",
                "08:00:02.000 playback: sender peer pkts=150 late=2 dup=1 "
                "resync=1 concealed=4 bigGaps=1",
            ]
        )
        # Last-seen wins — it's a running total since the last reset().
        self.assertEqual(metrics["playback_per_sender"]["peer"]["packets"], 150)
        self.assertEqual(metrics["playback_per_sender"]["peer"]["resyncs"], 1)

    def test_music_cast_queue_counters(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 music cast: started",
                "08:00:02.000 music cast: 4800 samples queued "
                "(cushion 200ms) | dropouts=1 trims=2 floods=0 capOverflows=0",
                "08:00:03.000 music cast: stopping (leavingChannel) | "
                "dropouts=1 trims=3 floods=0",
            ]
        )
        self.assertEqual(metrics["music_cast_started"], 1)
        self.assertEqual(metrics["music_cast_stopped"], 1)
        self.assertEqual(metrics["music_dropouts"], 1)
        self.assertEqual(metrics["music_trims"], 2)

    def test_lifecycle_and_channel_resume_counts(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 lifecycle: resumed after 4800ms away",
                "08:00:01.100 channel: resumed after 5s away — peers=1 "
                "local=10.0.0.2 health=live mic=true heard=true",
                "08:05:00.000 lifecycle: resumed after 33700ms away",
                "08:05:00.100 channel: resumed after 34s away — peers=1 "
                "local=10.0.0.2 health=live mic=true heard=true",
            ]
        )
        self.assertEqual(metrics["lifecycle_resumed_count"], 2)
        self.assertEqual(metrics["channel_resumed_count"], 2)
        self.assertEqual(metrics["longest_away_s"], 34)

    def test_terminal_failure_markers(self) -> None:
        metrics = self._analyze(
            [
                "08:00:01.000 mic: no frames for 6s while started — "
                "reporting a dead microphone",
                "08:00:02.000 wifi: no local address for 5s",
            ]
        )
        self.assertEqual(metrics["terminal_failures"]["mic_dead"], 1)
        self.assertEqual(metrics["terminal_failures"]["no_local_address"], 1)
        self.assertEqual(metrics["terminal_failures"]["send_path_one_way"], 0)


class BuildReportTest(unittest.TestCase):
    def _text(self) -> str:
        return _session_text(
            "first", "2026-08-19T08:00:00.000", ["08:00:01.000 app: hi"]
        ) + _session_text(
            "second", "2026-08-19T09:00:00.000", ["09:00:01.000 app: hi"]
        )

    def test_default_session_is_the_most_recent(self) -> None:
        report = dtl.build_report({"app": "tark", "version": "1.0"}, self._text(), None)
        self.assertIn("session   : second", report)

    def test_session_index_selects_an_earlier_run(self) -> None:
        report = dtl.build_report({"app": "tark", "version": "1.0"}, self._text(), 1)
        self.assertIn("session   : first", report)

    def test_out_of_range_session_raises(self) -> None:
        with self.assertRaises(ValueError):
            dtl.build_report({"app": "tark", "version": "1.0"}, self._text(), 5)

    def test_no_session_marker_raises(self) -> None:
        with self.assertRaises(ValueError):
            dtl.build_report({"app": "tark", "version": "1.0"}, "no markers here", None)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Read a .tarklog diagnostic export from a user's phone.

    python3 scripts/decode_tark_log.py tark-log-20260807-181500.tarklog
    python3 scripts/decode_tark_log.py somelog.tarklog -o session.txt

The container is defined in lib/core/diagnostics/tark_log_format.dart — keep
the two in step. It is gzip plus a keystream whose seed is a constant compiled
into the app, which makes the file opaque in a chat thread and nothing more:
this is NOT encryption and must never be described to a user as if it were.
What it does buy is that a log arrives whole, instead of being trimmed to "the
interesting part" by whoever forwarded it.

Layout (little-endian):
    0   8   magic "TARKLOG" + format version byte
    8   8   nonce (clear; seeds the keystream)
   16   4   header length H
   20   H   header:  keystream(JSON, UTF-8)
   ..   4   body length B
   ..   B   body:    keystream(gzip(UTF-8 log text))
   ..   4   CRC32 of the plaintext log text
"""

from __future__ import annotations

import argparse
import gzip
import json
import re
import struct
import sys
import zlib
from datetime import date, datetime, time, timedelta

from diagnostic_timeline import correlated_transitions, parse_build_provenance

MAGIC = b"TARKLOG"
SUPPORTED_VERSIONS = (1,)
SECRET = 0x5441524B4C4F4731  # "TARKLOG1"
MASK64 = (1 << 64) - 1


class Keystream:
    """xorshift64* seeded with SECRET mixed into the file's nonce.

    Mirrors _Keystream in tark_log_format.dart byte for byte. Dart ints are
    64-bit and wrap; Python's don't, so every step masks explicitly.
    """

    def __init__(self, secret: int, nonce: bytes) -> None:
        seed = secret
        for byte in nonce:
            seed = ((seed ^ byte) * 0x100000001B3) & MASK64
        self.state = seed if seed != 0 else 0x2545F4914F6CDD1D

    def _next(self) -> int:
        x = self.state
        x ^= x >> 12
        x = (x ^ (x << 25)) & MASK64
        x ^= x >> 27
        self.state = x
        return ((x * 0x2545F4914F6CDD1D) & MASK64) >> 24

    def apply(self, data: bytes) -> bytes:
        return bytes(b ^ (self._next() & 0xFF) for b in data)


def decode(raw: bytes) -> tuple[dict, str, bool]:
    """Returns (header, log text, whether the CRC matched)."""
    if len(raw) < 20 or raw[:7] != MAGIC:
        raise ValueError("not a .tarklog file (bad magic)")
    version = raw[7]
    if version not in SUPPORTED_VERSIONS:
        raise ValueError(
            f"format version {version} is newer than this script understands "
            f"(knows {SUPPORTED_VERSIONS}) — update decode_tark_log.py"
        )

    nonce = raw[8:16]
    stream = Keystream(SECRET, nonce)

    offset = 16
    (header_len,) = struct.unpack_from("<I", raw, offset)
    offset += 4
    header_bytes = stream.apply(raw[offset : offset + header_len])
    offset += header_len

    (body_len,) = struct.unpack_from("<I", raw, offset)
    offset += 4
    body = stream.apply(raw[offset : offset + body_len])
    offset += body_len

    header = json.loads(header_bytes.decode("utf-8"))
    text = gzip.decompress(body).decode("utf-8", errors="replace")

    intact = False
    if offset + 4 <= len(raw):
        (expected,) = struct.unpack_from("<I", raw, offset)
        intact = (zlib.crc32(text.encode("utf-8")) & 0xFFFFFFFF) == expected
    return header, text, intact


### --report: a session-scoped, privacy-safe field metrics summary #########
#
# Everything below reads the already-decoded plaintext `text` a session's
# lines are already public within the app (diagnostics, not secrets) — this
# just groups the ones that matter for the motorcycle field-test baseline
# (see docs/testing/motorcycle-field-test-runbook.md) into one summary
# instead of making a field engineer grep a multi-thousand-line export by
# hand. Keep the patterns below in step with the `Logger.diagnostic(...)`
# call sites they read from — grep the marker string in `lib/` if a report
# field goes missing after a refactor there.

_LINE_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) (.*)$")
_SESSION_OPEN_RE = re.compile(r"^--- session (\S+) opened (\S+)$")


class SessionBlock:
    """One `--- session <id> opened <iso>` run's worth of lines.

    A single `.tarklog` body can contain several of these back to back — the
    diagnostic ring log persists across app restarts — so every metric below
    is scoped to exactly one block, never the whole file.
    """

    def __init__(self, session_id: str, opened_at: datetime) -> None:
        self.session_id = session_id
        self.opened_at = opened_at
        self.timestamped_lines: list[tuple[datetime | None, str]] = []

    def add(self, at: datetime | None, text: str) -> None:
        self.timestamped_lines.append((at, text))

    @property
    def closed_at(self) -> datetime | None:
        for at, _ in reversed(self.timestamped_lines):
            if at is not None:
                return at
        return None

    @property
    def duration(self):
        closed = self.closed_at
        if closed is None:
            return None
        return closed - self.opened_at


def split_sessions(text: str) -> list[SessionBlock]:
    """Splits a decoded log body into its `--- session ... opened ...` runs.

    Lines that carry a per-line `HH:mm:ss.mmm` stamp (every ordinary
    diagnostic line does — see `DiagnosticLog._timestamp` in
    `lib/core/diagnostics/diagnostic_log.dart`) are converted to an absolute
    timestamp anchored on the block's own opening date, rolling over to the
    next day whenever the clock value goes backwards within the block — the
    date itself is only ever written once, in the opening banner.
    """
    blocks: list[SessionBlock] = []
    current: SessionBlock | None = None
    current_date: date | None = None
    prev_tod: time | None = None

    for raw in text.splitlines():
        # The banner goes through the same `_append` as every other line (see
        # `DiagnosticLog.initialize`), so it carries the same HH:mm:ss.mmm
        # stamp on disk — strip it before testing for the banner, not after,
        # or the banner never matches and every session gets silently dropped.
        m = _LINE_RE.match(raw)
        candidate = m.group(5) if m else raw
        opened = _SESSION_OPEN_RE.match(candidate)
        if opened:
            session_id, opened_at_raw = opened.groups()
            try:
                opened_at = datetime.fromisoformat(opened_at_raw)
            except ValueError:
                opened_at = datetime.min
            current = SessionBlock(session_id, opened_at)
            blocks.append(current)
            current_date = opened_at.date()
            prev_tod = opened_at.time()
            continue

        if current is None:
            continue  # lines before the first session banner: ignore

        if not m:
            current.add(None, raw)
            continue

        hh, mm, ss, ms, rest = m.groups()
        tod = time(int(hh), int(mm), int(ss), int(ms) * 1000)
        if prev_tod is not None and tod < prev_tod and current_date is not None:
            current_date += timedelta(days=1)
        prev_tod = tod
        at = (
            datetime.combine(current_date, tod)
            if current_date is not None
            else None
        )
        current.add(at, rest)

    return blocks


def _count_matching(lines: list[str], needle: str) -> int:
    return sum(1 for line in lines if needle in line)


def _field(pattern: str, line: str) -> str | None:
    m = re.search(pattern, line)
    return m.group(1) if m else None


def _tier_durations(
    events: list[tuple[datetime | None, str, str]],
    initial_state: str,
    start: datetime,
    end: datetime | None,
) -> dict[str, float]:
    """#32's "time-in-tier" ask: seconds spent in each state across
    `[start, end)`, given `events` — a chronological `(at, from, to)` list of
    every transition line found (e.g. #28's negotiated-profile line, #32's
    media-transmission line). `initial_state` is what held from `start` until
    the first event, since the app itself never logs "still on the tier it
    started on."

    Needs a real `end` to bound the final tier's span — an unclosed session
    (no further timestamped line after its last one, so `SessionBlock.closed_at`
    is `None`) has no defensible answer for "how long," so this returns `{}`
    rather than guess. A transition with no per-line timestamp (never happens
    in practice — only the opening banner lacks one, and banners are not
    transition lines) is skipped for the same reason.
    """
    if end is None:
        return {}
    durations: dict[str, float] = {}
    state = initial_state
    cursor = start
    for at, _from, to in events:
        if at is None or at < cursor:
            continue
        durations[state] = durations.get(state, 0.0) + (at - cursor).total_seconds()
        state = to
        cursor = at
    durations[state] = durations.get(state, 0.0) + (end - cursor).total_seconds()
    return durations


def analyze_session(block: SessionBlock) -> dict:
    """Extracts the privacy-safe field-test metrics from one [SessionBlock].

    Every field here is either a count, a rate, or a value already present in
    an existing `Logger.diagnostic(...)` line — nothing here reads or
    reproduces an IP, SSID, device id, or display name.
    """
    lines = [text for _at, text in block.timestamped_lines]

    metrics: dict = {
        "session_id": block.session_id,
        "opened_at": block.opened_at.isoformat(),
        "duration": str(block.duration) if block.duration else None,
        "build": parse_build_provenance(lines),
        "correlated_transitions": correlated_transitions(block.timestamped_lines),
    }

    # Negotiated capture/playback rates — first line wins, a mid-session route
    # change logs another and this deliberately keeps the session's opening
    # rate as the headline number.
    for line in lines:
        if line.startswith("audio: session started"):
            metrics["capture_hz"] = _field(r"capture (\d+)Hz", line)
            metrics["playback_hz"] = _field(r"playback (\d+)Hz", line)
            break

    # Wire format — a *different* line from "session started" (see
    # AudioEngineImpl's wire-format log), stamped once at session start and
    # again on every #28 capability renegotiation. First and last are both
    # kept: for a session that negotiates up to HD this shows the starting
    # (legacy) rate and where it ended up, which is the "actual vs negotiated"
    # evidence #28's acceptance criteria asks for.
    wire_re = re.compile(r"wire format (\S+) — (\d+)Hz/(\d+)smp")
    wire_matches = [m for line in lines if (m := wire_re.search(line))]
    if wire_matches:
        first, last = wire_matches[0], wire_matches[-1]
        metrics["wire_profile_initial"] = first.group(1)
        metrics["wire_hz_initial"] = int(first.group(2))
        metrics["wire_frame_samples_initial"] = int(first.group(3))
        metrics["wire_profile_final"] = last.group(1)
        metrics["wire_hz_final"] = int(last.group(2))
        metrics["wire_frame_samples_final"] = int(last.group(3))

    # Every negotiated-profile transition this session went through, e.g.
    # "16k -> 24k-HD" — the direct evidence of #28's capability negotiation
    # actually running against a real peer, not just unit tests.
    negotiation_re = re.compile(r"negotiated audio profile (\S+ -> \S+)")
    metrics["profile_negotiations"] = [
        m.group(1) for line in lines if (m := negotiation_re.search(line))
    ]

    # #32: the same transitions, with timestamp and reason, for time-in-tier
    # and upgrade/downgrade counts below — [_TIER_REASONS] mirrors
    # AdaptiveTierGate's exact reason strings (see that class's `advance`)
    # rather than a generic capture, the same "known marker, not a loose
    # pattern" style every other counter in this analyzer already uses.
    _TIER_REASONS = "sustained clean link|sustained poor link|capability ceiling dropped"
    voice_transition_re = re.compile(
        rf"negotiated audio profile (\S+) -> (\S+) \| reason=({_TIER_REASONS}) "
    )
    voice_events = [
        (at, m.group(1), m.group(2))
        for at, line in block.timestamped_lines
        if (m := voice_transition_re.search(line))
    ]
    metrics["voice_profile_seconds"] = _tier_durations(
        # "16k" — [AudioFormatProfile.legacy16k]'s wire *label*, the same
        # string every negotiation line and [wire_profile_initial] already
        # use, not the Dart constant's name.
        voice_events,
        "16k",
        block.opened_at,
        block.closed_at,
    )
    metrics["voice_upgrade_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if voice_transition_re.search(line)
        and "reason=sustained clean link" in line
    )
    metrics["voice_downgrade_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if voice_transition_re.search(line) and "reason=sustained poor link" in line
    )

    # #32: MediaQualityController's suspended/active transitions — same shape
    # as the voice ones above, kept separate since the two streams' tiers are
    # not comparable (legacy16k/hd24k vs suspended/active) and mixing them
    # into one time-in-tier map would silently conflate two different axes.
    # No time-in-tier duration for media, deliberately: unlike voice (whose
    # format applies for the whole session regardless of whether anyone is
    # talking), [MediaQualityController] keeps advancing even while nothing
    # is casting, so "seconds suspended" would misreport idle time between
    # casts as media being throttled — [media_suspended_drops] below is the
    # honest, cast-gated version of that same question (sendMedia only
    # increments it for a frame that was actually withheld).
    media_transition_re = re.compile(
        rf"media transmission (\S+) -> (\S+) \| reason=({_TIER_REASONS}) "
    )
    metrics["media_transmission_events"] = [
        f"{m.group(1)} -> {m.group(2)}"
        for _at, line in block.timestamped_lines
        if (m := media_transition_re.search(line))
    ]
    metrics["media_resume_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if media_transition_re.search(line)
        and "reason=sustained clean link" in line
    )
    metrics["media_suspend_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if media_transition_re.search(line) and "reason=sustained poor link" in line
    )

    # The periodic wifi summary line: last one wins for point-in-time values
    # (rtt, blocked/errs window), packets in/out are read from the last line
    # too since they are already-cumulative totals within the session.
    wifi_fields = {
        "packets_in": r"in=(\d+)\(",
        "packets_out": r"out=(\d+)\(",
        # #30: counted separately from packets_in/out (which already include
        # every packet type, media included) so a report can say how much of
        # the traffic was actually music rather than only that traffic
        # existed.
        "media_packets_in": r"mediaIn=(\d+)\(",
        "media_packets_out": r"mediaOut=(\d+)\(",
        # #32: media frames [_mediaQuality] withheld to protect voice/control
        # from a link that can't carry both — "media drops performed to
        # protect voice" from the roadmap's own diagnostics list, distinct
        # from ordinary transport loss.
        "media_suspended_drops": r"mediaSuspended=(\d+)\(",
        "recovery_peers": r"recovery=(\d+)",
        "dup_route": r"dupRoute=(\d+)",
        "stale_epoch": r"staleEpoch=(\d+)",
        "rtt_ms": r"rtt=(\d+|\?)ms",
        "blocked_window": r"blocked=(\d+)",
        "errs_window": r"errs=(\d+)",
        "quiet_for_s": r"quietFor=(\d+)s",
    }
    for line in lines:
        if line.startswith("wifi: in="):
            for key, pattern in wifi_fields.items():
                metrics[key] = _field(pattern, line)

    # Reconnect / rebind / recovery events — each counted independently so a
    # report can tell "rebound cleanly" from "kept renegotiating".
    recovery_markers = {
        "rebind_not_restored": "rebinds have not restored traffic",
        "liveness_timeout": "liveness timeout",
        "send_path_rebuilt": "rebuilding the send path",
        "sockets_rebound": "rebinding both sockets on the current network",
        "os_moved_back_on_ap": "OS moved us back onto the AP",
        "dropped_off_ap": "link: dropped off ",
        "back_on_ap": "link: back on ",
        "rejoin_failed": "rejoin failed",
        "ap_torn_down": "AP torn down mid-session",
        "re_hosted": "re-hosted as ",
        "re_host_failed": "re-host failed",
    }
    metrics["recovery_events"] = {
        key: _count_matching(lines, needle)
        for key, needle in recovery_markers.items()
    }

    # Codec profile transitions.
    codec_markers = {
        "opus_initialized": "codec: Opus initialized",
        "opus_unavailable": "codec: Opus UNAVAILABLE",
        "opus_tuning_rejected": "codec: Opus rejected",
        "opus_fec_encoder": "codec: Opus encoder with in-band FEC",
        "opus_failing": "codec: Opus failing",
    }
    metrics["codec_events"] = {
        key: _count_matching(lines, needle) for key, needle in codec_markers.items()
    }

    # Jitter buffer: resync events, plus the last-seen per-sender tally
    # (these lines report a running total since the buffer's last reset()).
    metrics["playback_resync_events"] = _count_matching(lines, "— resyncing (")
    per_sender_re = re.compile(
        r"^playback: sender (\S+) pkts=(\d+) late=(\d+) dup=(\d+) "
        r"resync=(\d+) concealed=(\d+) bigGaps=(\d+)"
    )
    per_sender: dict[str, dict[str, int]] = {}
    for line in lines:
        m = per_sender_re.match(line)
        if m:
            sender, pkts, late, dup, resync, concealed, big_gaps = m.groups()
            per_sender[sender] = {
                "packets": int(pkts),
                "late_drops": int(late),
                "duplicate_drops": int(dup),
                "resyncs": int(resync),
                "concealed_chunks": int(concealed),
                "big_gaps": int(big_gaps),
            }
    metrics["playback_per_sender"] = per_sender

    # MusicMixer or MediaFrameScheduler (#30) — whichever mode the cast ran
    # in this session; last-seen dropout/trim/flood/overflow tally, plus how
    # many start/stop cycles happened. Both sources log the identical line
    # shape (see WalkieTalkieCubit._logMusicHealth's own doc), so no mode
    # branch is needed here to parse it.
    metrics["music_cast_started"] = _count_matching(lines, "music cast: started")
    metrics["music_cast_stopped"] = _count_matching(lines, "music cast: stopping")
    metrics["music_capture_withheld_warnings"] = _count_matching(
        lines, "this device is withholding playback capture"
    )
    music_queue_re = re.compile(
        r"^music cast: \d+ samples queued .*\| dropouts=(\d+) trims=(\d+) "
        r"floods=(\d+) capOverflows=(\d+)"
    )
    for line in lines:
        m = music_queue_re.match(line)
        if m:
            dropouts, trims, floods, overflows = m.groups()
            metrics["music_dropouts"] = int(dropouts)
            metrics["music_trims"] = int(trims)
            metrics["music_floods"] = int(floods)
            metrics["music_cap_overflows"] = int(overflows)

    # #30: which mode each cast ran in this session — "independent (#30)"
    # once every currently-known peer negotiated a media profile, else
    # "mixed-into-voice" (the pre-#30 MusicMixer path). First and last are
    # both kept, same reasoning as wire_profile_initial/final above: decided
    # once per cast and held for its lifetime, so a session with several
    # casts can show whether the mode ever changed between them.
    media_mode_re = re.compile(r"music cast: capture started — mode=([^;]+);")
    media_modes = [
        m.group(1) for line in lines if (m := media_mode_re.search(line))
    ]
    if media_modes:
        metrics["media_mode_initial"] = media_modes[0]
        metrics["media_mode_final"] = media_modes[-1]

    # Background/resume — both the app-level lifecycle line and the
    # channel-level "resumed after Ns away" line, which is the one carrying
    # roster/health context.
    metrics["lifecycle_resumed_count"] = _count_matching(lines, "lifecycle: resumed")
    away_seconds = [
        int(s)
        for line in lines
        if (s := _field(r"channel: resumed after (\d+)s away", line)) is not None
    ]
    metrics["channel_resumed_count"] = _count_matching(lines, "channel: resumed")
    metrics["longest_away_s"] = max(away_seconds) if away_seconds else None

    # User-visible terminal failures.
    terminal_markers = {
        "mic_dead": "reporting a dead microphone",
        "send_path_one_way": "our send path is one-way",
        "no_local_address": "wifi: no local address for",
        "music_capture_error": "music cast: capture stream error",
        "diagnostics_export_failed": "diagnostics: export failed",
    }
    metrics["terminal_failures"] = {
        key: _count_matching(lines, needle)
        for key, needle in terminal_markers.items()
    }

    return metrics


def _report_build(header: dict, metrics: dict) -> dict:
    """Prefer the selected session's own build marker over export metadata.

    A ring export can contain several app launches/builds. The outer JSON
    header identifies the exporter, while the in-session `build:` line
    identifies the exact binary that generated the selected session. Old logs
    have no such line, so additive header fields remain the fallback.
    """
    return metrics.get("build") or {
        "version": header.get("version"),
        "commit": header.get("commit"),
        "dirty": header.get("dirty"),
        "channel": header.get("channel"),
        "built_at": header.get("builtAt"),
    }


def format_report(header: dict, metrics: dict) -> str:
    build = _report_build(header, metrics)
    lines = [
        "# tark field-test report",
        f"# app      : {header.get('app')} {header.get('version')}",
        f"# platform : {header.get('platform')} ({header.get('os')})",
        "",
        f"session   : {metrics['session_id']}",
        f"opened at : {metrics['opened_at']}",
        f"duration  : {metrics['duration']}",
        "",
        "-- build provenance --",
        f"version={build.get('version')} commit={build.get('commit')} "
        f"dirty={build.get('dirty')} channel={build.get('channel')} "
        f"builtAt={build.get('built_at')}",
        "",
        "-- correlated transitions --",
    ]
    transitions = metrics.get("correlated_transitions") or []
    if transitions:
        lines.extend(
            f"{event.get('at') or '?'} {event['event']}" for event in transitions
        )
    else:
        lines.append("none")
    lines.extend(
        [
        "",
        "-- audio format --",
        f"capture={metrics.get('capture_hz')}Hz playback={metrics.get('playback_hz')}Hz",
        f"wire start={metrics.get('wire_profile_initial')} "
        f"({metrics.get('wire_hz_initial')}Hz/{metrics.get('wire_frame_samples_initial')}smp) "
        f"-> end={metrics.get('wire_profile_final')} "
        f"({metrics.get('wire_hz_final')}Hz/{metrics.get('wire_frame_samples_final')}smp)",
        f"negotiations: {metrics.get('profile_negotiations') or 'none'}",
        # #32: time-in-tier + upgrade/downgrade counts, so a session that
        # spent 90% of its length in HD and flapped down once reads
        # differently from one that spent 90% on the legacy floor.
        f"voice time-in-tier(s): {metrics.get('voice_profile_seconds') or 'n/a'} "
        f"upgrades={metrics.get('voice_upgrade_count')} "
        f"downgrades={metrics.get('voice_downgrade_count')}",
        f"media transmission: {metrics.get('media_transmission_events') or 'none'} "
        f"resumes={metrics.get('media_resume_count')} "
        f"suspends={metrics.get('media_suspend_count')} "
        f"withheld(cumulative)={metrics.get('media_suspended_drops')}",
        "",
        "-- transport --",
        f"packets in={metrics.get('packets_in')} out={metrics.get('packets_out')} "
        f"(media in={metrics.get('media_packets_in')} out={metrics.get('media_packets_out')}) "
        f"rtt={metrics.get('rtt_ms')}ms quietFor={metrics.get('quiet_for_s')}s",
        f"recovery peers={metrics.get('recovery_peers')} "
        f"dupRoute={metrics.get('dup_route')} staleEpoch={metrics.get('stale_epoch')} "
        f"blocked(window)={metrics.get('blocked_window')} errs(window)={metrics.get('errs_window')}",
        f"recovery events: {metrics.get('recovery_events')}",
        "",
        "-- codec --",
        f"{metrics.get('codec_events')}",
        "",
        "-- jitter buffer --",
        f"resync events={metrics.get('playback_resync_events')}",
        f"per-sender: {metrics.get('playback_per_sender')}",
        "",
        "-- shared music --",
        f"mode start={metrics.get('media_mode_initial')} -> end={metrics.get('media_mode_final')}",
        f"started={metrics.get('music_cast_started')} stopped={metrics.get('music_cast_stopped')} "
        f"dropouts={metrics.get('music_dropouts')} trims={metrics.get('music_trims')} "
        f"floods={metrics.get('music_floods')} capOverflows={metrics.get('music_cap_overflows')} "
        f"captureWithheldWarnings={metrics.get('music_capture_withheld_warnings')}",
        "",
        "-- background/resume --",
        f"lifecycle resumed={metrics.get('lifecycle_resumed_count')} "
        f"channel resumed={metrics.get('channel_resumed_count')} "
        f"longest away={metrics.get('longest_away_s')}s",
        "",
        "-- terminal failures --",
        f"{metrics.get('terminal_failures')}",
        ]
    )
    return "\n".join(lines) + "\n"


def build_report(header: dict, text: str, session_index: int | None) -> str:
    """`session_index` is 1-based per `--session`; `None` means the last one."""
    sessions = split_sessions(text)
    if not sessions:
        raise ValueError("no '--- session ... opened' marker found in this log")
    index = len(sessions) - 1 if session_index is None else session_index - 1
    if index < 0 or index >= len(sessions):
        raise ValueError(
            f"--session {session_index} out of range: this log has {len(sessions)} "
            f"session(s)"
        )
    metrics = analyze_session(sessions[index])
    return format_report(header, metrics)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", help="the .tarklog export")
    parser.add_argument("-o", "--out", help="write the log here instead of stdout")
    parser.add_argument(
        "--json-header",
        action="store_true",
        help="print only the header, as JSON (for scripting)",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help=(
            "print a privacy-safe field-test metrics summary for one session "
            "in this log instead of the raw text (see --session)"
        ),
    )
    parser.add_argument(
        "--session",
        type=int,
        metavar="N",
        help=(
            "with --report: which '--- session ... opened' run to summarize "
            "(1-based; default is the most recent one in this log)"
        ),
    )
    args = parser.parse_args()

    with open(args.file, "rb") as handle:
        raw = handle.read()

    try:
        header, text, intact = decode(raw)
    except Exception as error:  # noqa: BLE001 — a CLI should explain, not traceback
        print(f"could not read {args.file}: {error}", file=sys.stderr)
        return 1

    if args.json_header:
        print(json.dumps(header, indent=2))
        return 0

    if args.report:
        try:
            output = build_report(header, text, args.session)
        except ValueError as error:
            print(f"could not build a report: {error}", file=sys.stderr)
            return 1
        if args.out:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(output)
            print(f"wrote {args.out}", file=sys.stderr)
        else:
            sys.stdout.write(output)
        if not intact:
            print("warning: checksum mismatch", file=sys.stderr)
            return 2
        return 0

    banner = [
        "# tark diagnostic log",
        f"# app      : {header.get('app')} {header.get('version')}",
        f"# build    : {header.get('commit')} channel={header.get('channel')} "
        f"dirty={header.get('dirty')} builtAt={header.get('builtAt')}",
        f"# platform : {header.get('platform')} ({header.get('os')})",
        f"# session  : {header.get('session')}",
        f"# exported : {header.get('exportedAt')}",
        f"# lines    : {header.get('lines')}",
        f"# checksum : {'ok' if intact else 'MISMATCH — file may be truncated'}",
        "",
    ]
    output = "\n".join(banner) + text

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(output)
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(output)

    if not intact:
        print("warning: checksum mismatch", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

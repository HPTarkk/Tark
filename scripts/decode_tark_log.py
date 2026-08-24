#!/usr/bin/env python3
"""Read a .tarklog export and optionally build a privacy-safe field report."""

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
SECRET = 0x5441524B4C4F4731
MASK64 = (1 << 64) - 1


class Keystream:
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


_LINE_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) (.*)$")
_SESSION_OPEN_RE = re.compile(r"^--- session (\S+) opened (\S+)$")


class SessionBlock:
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
        return None if closed is None else closed - self.opened_at


def split_sessions(text: str) -> list[SessionBlock]:
    blocks: list[SessionBlock] = []
    current: SessionBlock | None = None
    current_date: date | None = None
    prev_tod: time | None = None

    for raw in text.splitlines():
        match = _LINE_RE.match(raw)
        candidate = match.group(5) if match else raw
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
            continue
        if not match:
            current.add(None, raw)
            continue

        hh, mm, ss, ms, rest = match.groups()
        tod = time(int(hh), int(mm), int(ss), int(ms) * 1000)
        if prev_tod is not None and tod < prev_tod and current_date is not None:
            current_date += timedelta(days=1)
        prev_tod = tod
        at = datetime.combine(current_date, tod) if current_date is not None else None
        current.add(at, rest)
    return blocks


def _count_matching(lines: list[str], needle: str) -> int:
    return sum(1 for line in lines if needle in line)


def _field(pattern: str, line: str) -> str | None:
    match = re.search(pattern, line)
    return match.group(1) if match else None


def _tier_durations(
    events: list[tuple[datetime | None, str, str]],
    initial_state: str,
    start: datetime,
    end: datetime | None,
) -> dict[str, float]:
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
    lines = [text for _at, text in block.timestamped_lines]
    metrics: dict = {
        "session_id": block.session_id,
        "opened_at": block.opened_at.isoformat(),
        "duration": str(block.duration) if block.duration else None,
        "build": parse_build_provenance(lines),
        "correlated_transitions": correlated_transitions(block.timestamped_lines),
    }

    for line in lines:
        if line.startswith("audio: session started"):
            metrics["capture_hz"] = _field(r"capture (\d+)Hz", line)
            metrics["playback_hz"] = _field(r"playback (\d+)Hz", line)
            break

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

    negotiation_re = re.compile(r"negotiated audio profile (\S+ -> \S+)")
    metrics["profile_negotiations"] = [
        m.group(1) for line in lines if (m := negotiation_re.search(line))
    ]

    tier_reasons = "sustained clean link|sustained poor link|capability ceiling dropped"
    voice_transition_re = re.compile(
        rf"negotiated audio profile (\S+) -> (\S+) \| reason=({tier_reasons}) "
    )
    voice_events = [
        (at, m.group(1), m.group(2))
        for at, line in block.timestamped_lines
        if (m := voice_transition_re.search(line))
    ]
    metrics["voice_profile_seconds"] = _tier_durations(
        voice_events, "16k", block.opened_at, block.closed_at
    )
    metrics["voice_upgrade_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if voice_transition_re.search(line) and "reason=sustained clean link" in line
    )
    metrics["voice_downgrade_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if voice_transition_re.search(line) and "reason=sustained poor link" in line
    )

    media_transition_re = re.compile(
        rf"media transmission (\S+) -> (\S+) \| reason=({tier_reasons}) "
    )
    metrics["media_transmission_events"] = [
        f"{m.group(1)} -> {m.group(2)}"
        for _at, line in block.timestamped_lines
        if (m := media_transition_re.search(line))
    ]
    metrics["media_resume_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if media_transition_re.search(line) and "reason=sustained clean link" in line
    )
    metrics["media_suspend_count"] = sum(
        1
        for _at, line in block.timestamped_lines
        if media_transition_re.search(line) and "reason=sustained poor link" in line
    )

    wifi_fields = {
        "packets_in": r"in=(\d+)\(",
        "packets_out": r"out=(\d+)\(",
        "media_packets_in": r"mediaIn=(\d+)\(",
        "media_packets_out": r"mediaOut=(\d+)\(",
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
        key: _count_matching(lines, needle) for key, needle in recovery_markers.items()
    }

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

    metrics["playback_resync_events"] = _count_matching(lines, "— resyncing (")
    sender_re = re.compile(
        r"^playback: sender (\S+) pkts=(\d+) late=(\d+) dup=(\d+) "
        r"resync=(\d+) concealed=(\d+) bigGaps=(\d+)"
    )
    per_sender: dict[str, dict[str, int]] = {}
    for line in lines:
        match = sender_re.match(line)
        if not match:
            continue
        sender, pkts, late, dup, resync, concealed, big_gaps = match.groups()
        per_sender[sender] = {
            "packets": int(pkts),
            "late_drops": int(late),
            "duplicate_drops": int(dup),
            "resyncs": int(resync),
            "concealed_chunks": int(concealed),
            "big_gaps": int(big_gaps),
        }
    metrics["playback_per_sender"] = per_sender

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
        match = music_queue_re.match(line)
        if match:
            dropouts, trims, floods, overflows = match.groups()
            metrics["music_dropouts"] = int(dropouts)
            metrics["music_trims"] = int(trims)
            metrics["music_floods"] = int(floods)
            metrics["music_cap_overflows"] = int(overflows)

    media_mode_re = re.compile(r"music cast: capture started — mode=([^;]+);")
    media_modes = [m.group(1) for line in lines if (m := media_mode_re.search(line))]
    if media_modes:
        metrics["media_mode_initial"] = media_modes[0]
        metrics["media_mode_final"] = media_modes[-1]

    metrics["lifecycle_resumed_count"] = _count_matching(lines, "lifecycle: resumed")
    away_seconds = [
        int(seconds)
        for line in lines
        if (seconds := _field(r"channel: resumed after (\d+)s away", line)) is not None
    ]
    metrics["channel_resumed_count"] = _count_matching(lines, "channel: resumed")
    metrics["longest_away_s"] = max(away_seconds) if away_seconds else None

    terminal_markers = {
        "mic_dead": "reporting a dead microphone",
        "send_path_one_way": "our send path is one-way",
        "no_local_address": "wifi: no local address for",
        "music_capture_error": "music cast: capture stream error",
        "diagnostics_export_failed": "diagnostics: export failed",
    }
    metrics["terminal_failures"] = {
        key: _count_matching(lines, needle) for key, needle in terminal_markers.items()
    }
    return metrics


def _report_build(header: dict, metrics: dict) -> dict[str, str | None]:
    body = metrics.get("build")
    if body is not None:
        return body
    return {
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
        lines.extend(f"{event.get('at') or '?'} {event['event']}" for event in transitions)
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
    sessions = split_sessions(text)
    if not sessions:
        raise ValueError("no '--- session ... opened' marker found in this log")
    index = len(sessions) - 1 if session_index is None else session_index - 1
    if index < 0 or index >= len(sessions):
        raise ValueError(
            f"--session {session_index} out of range: this log has {len(sessions)} session(s)"
        )
    return format_report(header, analyze_session(sessions[index]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", help="the .tarklog export")
    parser.add_argument("-o", "--out", help="write output here instead of stdout")
    parser.add_argument("--json-header", action="store_true")
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--session", type=int, metavar="N")
    args = parser.parse_args()

    with open(args.file, "rb") as handle:
        raw = handle.read()
    try:
        header, text, intact = decode(raw)
    except Exception as error:  # noqa: BLE001
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
    else:
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

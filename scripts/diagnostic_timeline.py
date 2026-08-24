"""Privacy-safe provenance and transition extraction for Tark field reports.

Kept separate from the binary .tarklog decoder so this parser can be tested
with tiny synthetic sessions. Only explicitly allow-listed diagnostic markers
are surfaced; arbitrary network/native lines are never copied into a report.
"""

from __future__ import annotations

import re
from datetime import datetime

_BUILD_RE = re.compile(
    r"^build: version=(\S+) commit=(\S+) dirty=(clean|dirty|unknown) "
    r"channel=(\S+) builtAt=(\S+)$"
)

_SAFE_PREFIXES = (
    "hotspot: start requested",
    "hotspot: started ",
    "hotspot: start failed ",
    "hotspot: stop requested",
    "hotspot: stop completed",
    "hotspot: stop failed ",
    "hotspot: stopped ",
    "network: hotspot join ",
    "network: bind current wifi ",
    "network: selected wifi ",
    "lifecycle: ",
    "mediaProjection: ",
)


def parse_build_provenance(lines: list[str]) -> dict[str, str] | None:
    """Return the first exact build header in a session, if present.

    Old logs intentionally return None. A malformed/newer optional field does
    not make the rest of the report undecodable.
    """

    for line in lines:
        match = _BUILD_RE.match(line)
        if match is None:
            continue
        version, commit, dirty, channel, built_at = match.groups()
        return {
            "version": version,
            "commit": commit,
            "dirty": dirty,
            "channel": channel,
            "built_at": built_at,
        }
    return None


def correlated_transitions(
    timestamped_lines: list[tuple[datetime | None, str]],
) -> list[dict[str, str | None]]:
    """Return an ordered, bounded-to-known-markers native/product timeline."""

    events: list[dict[str, str | None]] = []
    for at, line in timestamped_lines:
        if not line.startswith(_SAFE_PREFIXES):
            continue
        events.append(
            {
                "at": at.isoformat() if at is not None else None,
                "event": line,
            }
        )
    return events

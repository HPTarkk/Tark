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
import struct
import sys
import zlib

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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", help="the .tarklog export")
    parser.add_argument("-o", "--out", help="write the log here instead of stdout")
    parser.add_argument(
        "--json-header",
        action="store_true",
        help="print only the header, as JSON (for scripting)",
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

    banner = [
        "# tark diagnostic log",
        f"# app      : {header.get('app')} {header.get('version')}",
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

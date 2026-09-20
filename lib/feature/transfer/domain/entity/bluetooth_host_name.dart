/// Bluetooth host naming helpers.
///
/// Room rendezvous no longer trusts the mutable remote adapter name: BLE
/// service-data is the primary selector. The adapter name remains a best-effort
/// compatibility/debug label while hosting, and is restored afterwards.
library;

import 'dart:convert';

/// Bare brand name, used when the host has no display name of its own.
const kTarkHostBrand = 'Tark';

/// Marker used by legacy/classic discovery paths.
const kTarkHostPrefix = '$kTarkHostBrand · ';

/// Longest adapter name we intentionally apply while hosting.
///
/// Kept small enough for older Bluetooth stacks and for legacy scan displays.
/// Room rendezvous itself is carried separately in BLE service-data.
const kMaxHostNameBytes = 29;

/// Stable human-readable rendezvous label used only inside Tark after a BLE
/// service-data match. It is NOT trusted as the discovery identity.
String rendezvousHostName(String token) {
  final clean = token.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{8,64}$').hasMatch(clean)) {
    throw const FormatException('invalid proximity rendezvous token');
  }
  return 'R-${clean.substring(0, 8)}';
}

/// The adapter name to broadcast while hosting as [myName], abbreviated on a
/// character boundary if it doesn't fit [kMaxHostNameBytes].
String encodeHostName(String myName) {
  final name = myName.trim();
  if (name.isEmpty || name == kTarkHostBrand) return kTarkHostBrand;
  final budget = kMaxHostNameBytes - utf8.encode(kTarkHostPrefix).length;
  return '$kTarkHostPrefix${_truncateUtf8(name, budget)}';
}

/// Cuts [value] to at most [maxBytes] of UTF-8 without splitting a character.
String _truncateUtf8(String value, int maxBytes) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true).trimRight();
}

/// Whether [advertisedName] belongs to a legacy/classic Tark host.
bool isTarkHostName(String advertisedName) {
  final name = advertisedName.trim();
  return name == kTarkHostBrand || name.startsWith(kTarkHostPrefix);
}

/// The display name to show for a legacy/classic peer.
String decodeHostName(String advertisedName) {
  final name = advertisedName.trim();
  if (!name.startsWith(kTarkHostPrefix)) return name;
  final stripped = name.substring(kTarkHostPrefix.length).trim();
  return stripped.isEmpty ? kTarkHostBrand : stripped;
}

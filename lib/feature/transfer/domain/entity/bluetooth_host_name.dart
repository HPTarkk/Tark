/// How a Bluetooth host names itself on the air, and how a joiner reads that
/// name back off it.
///
/// Classic Bluetooth inquiry only ever reports the remote *adapter* name — the
/// RFCOMM service-record name we register never reaches a scanning device, so
/// a host that did nothing would show up under its OEM name ("SM-A525F"). The
/// host therefore renames its adapter for the duration of the session (see
/// android/.../bluetooth/BluetoothServerHandler.kt) and tags that name with
/// [kTarkHostPrefix]. The tag is what lets a joiner tell Tark hosts apart from
/// the headphones, TVs and laptops in the same scan — it is plumbing, and is
/// stripped again before the name is ever shown to a user.
library;

import 'dart:convert';

/// Bare brand name, used when the host has no display name of its own.
const kTarkHostBrand = 'Tark';

/// Marker every hosting device carries in its broadcast name.
const kTarkHostPrefix = '$kTarkHostBrand · ';

/// Longest broadcast name that still reaches a scanning phone intact.
///
/// The BLE advertisement carries the Tark service UUID (18 of the packet's 31
/// bytes) and hands the name to the *scan response*, a second 31-byte packet
/// whose name field costs 2 bytes of header — leaving 29 for the name itself.
/// Android rejects the whole advertisement if either packet overflows, and the
/// host then falls back to advertising with no name at all, so a long name
/// used to make a host anonymous rather than simply abbreviated.
///
/// This is a *byte* budget, which is the part that bites non-Latin scripts:
/// Persian and Arabic letters cost two bytes each in UTF-8, so ~10 of them
/// fit where 21 Latin ones would.
const kMaxHostNameBytes = 29;

/// The adapter name to broadcast while hosting as [myName], abbreviated on a
/// character boundary if it doesn't fit [kMaxHostNameBytes].
String encodeHostName(String myName) {
  final name = myName.trim();
  if (name.isEmpty || name == kTarkHostBrand) return kTarkHostBrand;
  final budget = kMaxHostNameBytes - utf8.encode(kTarkHostPrefix).length;
  return '$kTarkHostPrefix${_truncateUtf8(name, budget)}';
}

/// Cuts [value] to at most [maxBytes] of UTF-8 without splitting a character —
/// half of a two-byte Persian letter would render as a replacement box.
String _truncateUtf8(String value, int maxBytes) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true).trimRight();
}

/// Whether [advertisedName] belongs to a device hosting from inside the app.
bool isTarkHostName(String advertisedName) {
  final name = advertisedName.trim();
  return name == kTarkHostBrand || name.startsWith(kTarkHostPrefix);
}

/// The name to show the user for a peer broadcasting [advertisedName].
String decodeHostName(String advertisedName) {
  final name = advertisedName.trim();
  if (!name.startsWith(kTarkHostPrefix)) return name;
  final stripped = name.substring(kTarkHostPrefix.length).trim();
  return stripped.isEmpty ? kTarkHostBrand : stripped;
}

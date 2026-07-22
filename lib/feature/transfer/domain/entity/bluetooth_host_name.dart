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

/// Bare brand name, used when the host has no display name of its own.
const kTarkHostBrand = 'Tark';

/// Marker every hosting device carries in its broadcast name.
const kTarkHostPrefix = '$kTarkHostBrand · ';

/// The adapter name to broadcast while hosting as [myName].
String encodeHostName(String myName) {
  final name = myName.trim();
  if (name.isEmpty || name == kTarkHostBrand) return kTarkHostBrand;
  return '$kTarkHostPrefix$name';
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

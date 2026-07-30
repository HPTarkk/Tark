import 'dart:ui' show Locale;

import '../l10n/app_localizations.dart';

/// [fallbackDisplayName] with the label read from the UI's own strings for
/// [localeCode] — the way code without a BuildContext (a cubit composing the
/// name it will broadcast) reaches the same words the screens use. An
/// unrecognised code falls back to the app's default language instead of
/// throwing.
String localizedFallbackDisplayName(String localeCode, String id) {
  final supported = AppLocalizations.supportedLocales.any(
    (locale) => locale.languageCode == localeCode,
  );
  final strings = lookupAppLocalizations(
    supported ? Locale(localeCode) : const Locale('fa'),
  );
  return fallbackDisplayName(strings.default_user_name, id);
}

/// A stand-in name for someone who never set one.
///
/// The old default was `User<last octet of the device's IP>`, which put a
/// piece of the network address on screen — and not only the owner's own
/// screen, since the display name travels with every packet and lands in
/// everyone else's roster. A person cannot do anything with an address, and
/// half of one reads like a serial number.
///
/// The two-digit tail stays, because it is what tells two unnamed people
/// apart in a channel, but it is now *derived* from [id] rather than lifted
/// out of it: stable for the same device (so a peer doesn't get renamed
/// between sessions) and meaningless as an address.
String fallbackDisplayName(String label, String id) {
  if (id.isEmpty) return label;
  var tail = 0;
  for (final unit in id.codeUnits) {
    tail = (tail * 31 + unit) % 90;
  }
  return '$label ${tail + 10}';
}

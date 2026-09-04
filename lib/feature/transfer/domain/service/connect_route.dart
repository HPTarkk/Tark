import 'dart:io';

import '../../../../core/router/routes.dart';
import '../entity/channel_intent.dart';
import '../entity/transfer_mode.dart';
import 'transport_advisor.dart';

/// Where somebody goes to get onto a link with the people they are trying to
/// reach.
///
/// The mirror of `QuickAccess.locationForMode`, which answers "where does this
/// transport put me on air fastest" for a device that is already set up. These
/// are asked when something is missing, so they carry the intent as well: the
/// hotspot bridge and the Bluetooth pairing screen both open by asking which
/// side you are, and a room already knows.
abstract final class ConnectRoute {
  /// For a device with **no link at all**, where the advisor's whole ladder
  /// applies: Bluetooth is a perfectly good answer on a phone that can neither
  /// host nor join an access point.
  ///
  /// Plain Wi-Fi is the odd rung and deliberately so. There is nothing to set
  /// up on a shared network — [ChannelPlan.blocked] is the advisor saying it
  /// picked Wi-Fi and there is no network to run it over — so the destination
  /// is the page that can still make a network rather than the channel that
  /// would have nothing to talk over.
  static String forPlan(ChannelPlan plan) => switch (plan.mode) {
    TransferMode.bluetooth =>
      '${AppRoutes.bluetoothConnectPath}?intent=${plan.intent.key}',
    TransferMode.guest => AppRoutes.guestLinkPath,
    // Both Wi-Fi rungs land on the same page: its Wi-Fi segment is "we are
    // already on one network, just go", and its hotspot segment is how one
    // gets made. Someone sent here without a network needs the second, so
    // that is the segment it opens on.
    TransferMode.wifi || TransferMode.hotspot =>
      '${AppRoutes.wifiHotspotPath}?mode=hotspot&intent=${plan.intent.key}',
  };

  /// For a **network code read somewhere that cannot act on it** — the Room's
  /// one-scan join scanner, pointed at the host's hotspot QR.
  ///
  /// There are two QR codes in this app and they are not interchangeable: the
  /// bridge shows Wi-Fi credentials, the People sheet shows a Room invite, and
  /// the two scanners are deliberately identical instruments. So the wrong
  /// pairing is an ordinary mistake rather than a rare one, and the right
  /// answer to it is not a better error message — it is to do what the code
  /// says. This is always the joining side: whoever is holding a camera up to
  /// somebody else's screen is not the one who made the network.
  static String forScannedNetwork() =>
      '${AppRoutes.wifiHotspotPath}?mode=hotspot'
      '&intent=${ChannelIntent.join.key}';

  /// For a device that **has a link and still cannot reach anybody** — the
  /// two phones are each on something, just not on the same thing.
  ///
  /// Deliberately not the advisor. The advisor answers "what should this phone
  /// prefer", weighing what the device can do; this answers "get these two
  /// onto one network", which is a different question with a narrower answer.
  /// Running the ladder here would let a phone sitting on a café Wi-Fi be told
  /// to use that same Wi-Fi again, which is the thing that just failed.
  ///
  /// A hand-pinned transport is still honoured, because a pin is the user
  /// saying they know something the app does not.
  static String forStrandedRoom({
    required ChannelIntent intent,
    TransferMode? pinned,
  }) => switch (pinned) {
    TransferMode.bluetooth =>
      '${AppRoutes.bluetoothConnectPath}?intent=${intent.key}',
    TransferMode.guest => AppRoutes.guestLinkPath,
    // Desktop and web can host neither an access point nor a Bluetooth link,
    // so the bridge has nothing to offer them; the shared-network segment is
    // the only page that can help, and it is where they already were.
    _ when !Platform.isAndroid && !Platform.isIOS => AppRoutes.wifiHotspotPath,
    _ => '${AppRoutes.wifiHotspotPath}?mode=hotspot&intent=${intent.key}',
  };
}

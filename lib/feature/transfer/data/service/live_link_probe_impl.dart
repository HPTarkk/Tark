import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/utils/local_network.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/live_link.dart';
import '../../domain/repository/bluetooth_transport.dart';
import '../../domain/service/hotspot_control.dart';
import '../../domain/service/live_link_probe.dart';
import '../android_network_binding.dart';
import '../hotspot/wifi_client_address.dart';

/// Reads the three radios that can be carrying a Room.
///
/// **Why Android does not use the interface list.** `LocalNetwork
/// .ipv4Address()` answers "is there a usable local address", and on a phone
/// with mobile data that is *always yes* — rmnet has a perfectly good
/// non-loopback IPv4 on it. A gate built on that would pass on a bus with no
/// Wi-Fi in sight, which is the exact case it exists to catch. Android is
/// asked about the Wi-Fi radio itself instead (see [_onWifi]). Everywhere
/// else there is no such API and no cellular either, so the interface list is
/// both the only answer available and a correct one.
///
/// **Every read fails towards "no link".** A radio that cannot be asked, a
/// channel with no handler behind it, a throw: all of them report down. The
/// two mistakes are not symmetrical — being told to connect when you already
/// are costs a screen you can walk straight back out of, while being told you
/// are connected when you are not is the bug this class exists to prevent,
/// and it is only discovered by nobody hearing you.
@LazySingleton(as: LiveLinkProbe)
class PlatformLiveLinkProbe implements LiveLinkProbe {
  PlatformLiveLinkProbe(this._hotspot, this._bluetooth);

  final HotspotHost _hotspot;
  final BluetoothTransport _bluetooth;

  @override
  Future<LiveLinkSnapshot> read() async {
    final links = LiveLinkSnapshot(
      wifi: await _onWifi(),
      hostingHotspot: _hotspot.isHosting,
      bluetooth:
          _bluetooth.currentConnectionState ==
          BluetoothConnectionState.connected,
    );
    // One line carrying all three, because the failure this gate can have is
    // claiming a link that is not there, and a screenshot of the claim says
    // nothing about which radio made it.
    Logger.diagnostic(
      'link: wifi=${links.wifi} hosting=${links.hostingHotspot} '
      'bt=${links.bluetooth}',
    );
    return links;
  }

  /// Wired on subscribe and torn down on cancel, rather than once for the
  /// process.
  ///
  /// Listening to the Android side registers a `ConnectivityManager` default
  /// network callback, and this object is a lazy singleton — a stream built
  /// when the getter is *read* would leave that callback registered for as
  /// long as the app runs, on behalf of a screen that has been closed for an
  /// hour. Single-subscription rather than broadcast for the same reason: a
  /// second listener should be a loud error, not a second silent set of
  /// platform callbacks.
  @override
  Stream<void> get changes {
    final subscriptions = <StreamSubscription<dynamic>>[];
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () => subscriptions.addAll([
        AndroidNetworkBinding.changes.listen(
          (_) => controller.add(null),
          // A radio that stops reporting is not a reason to take the screen
          // down with it; the next read answers from whatever can still be
          // asked.
          onError: (Object _) {},
        ),
        _bluetooth.connectionState.listen(
          (_) => controller.add(null),
          onError: (Object _) {},
        ),
      ]),
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  /// Whether this device is associated with a Wi-Fi network — someone else's
  /// hotspot included, which from here is the same thing.
  ///
  /// **The radio has a veto, and it needs one.** The first version of this
  /// asked `ConnectivityManager` alone and shipped a phone that said "On
  /// Wi-Fi — READY" with the Wi-Fi switch off. That API answers a *routing*
  /// question — which network would traffic take — and `selectedNetwork()`
  /// falls back to the active network when it finds no Wi-Fi, so the reply is
  /// about whatever is carrying packets rather than about the Wi-Fi radio. It
  /// is still consulted below, because it sees one thing `WifiManager` does
  /// not; it just no longer gets to decide on its own.
  Future<bool> _onWifi() async {
    if (!Platform.isAndroid) return await LocalNetwork.ipv4Address() != null;

    // `WifiManager.isWifiEnabled`, straight from the radio. Off means there is
    // no Wi-Fi link and no further question worth asking. (Read through the
    // hotspot channel's advice call, which is where this app already asks it.)
    final radioOn = (await _hotspot.wifiAdvice()).wifiEnabled;
    if (!radioOn) {
      Logger.diagnostic('link: wifi=no reason=radio_off');
      return false;
    }

    // Associated as a client: `WifiManager`'s own STA address, which is null
    // when this phone is not on a network. The authority for the question
    // actually being asked, and the one signal that cannot confuse our own
    // access point with a network we joined.
    if (await WifiClientAddress.current() != null) {
      Logger.diagnostic('link: wifi=yes reason=sta_address');
      return true;
    }

    // Second opinion, and the reason the routing view is kept at all: an
    // app-requested join (`WifiNetworkSpecifier`, which is how the hotspot
    // bridge's joiner attaches) is not always surfaced by `connectionInfo`,
    // and treating that as "no Wi-Fi" would gate the very people who had just
    // finished connecting. Only reachable with the radio on.
    try {
      final selection = await AndroidNetworkBinding.current();
      // A VPN's tunnel is not the local network the peers are on, and the
      // native side already refuses to bind the process to one.
      final routed =
          selection != null &&
          selection.available &&
          selection.isWifi &&
          !selection.isVpn;
      Logger.diagnostic('link: wifi=$routed reason=routed_network');
      return routed;
    } on MissingPluginException {
      // An engine without the handler registered — tests, a stripped build.
      // Reporting "no link" sends the user to a screen that can still get
      // them one; reporting a link they may not have does not.
      return false;
    }
  }
}

import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/logger.dart';
import '../../data/hotspot/wifi_hotspot_controller.dart';
import '../../data/repository/wifi_transfer_repository_impl.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';

enum HotspotPhase {
  /// Android: creating the local-only hotspot.
  starting,

  /// Android: hotspot is up — showing the QR/credentials and waiting for the
  /// iPhone to join and enter the channel.
  ready,

  /// Android: the hotspot could not be created.
  error,
}

class HotspotBridgeState extends Equatable {
  final WifiHotspotSegment segment;
  final HotspotPhase phase;

  /// The Android host's hotspot credentials (null until [HotspotPhase.ready]).
  final HotspotCredentials? credentials;

  /// True once we've heard a packet from the joined peer over Wi-Fi — the cue
  /// to auto-advance into the channel.
  final bool peerConnected;

  /// Native error code (`tethering_on`, `unsupported`, `failed`, …) so the UI
  /// can tailor the message.
  final String? errorCode;

  const HotspotBridgeState({
    required this.segment,
    required this.phase,
    required this.credentials,
    required this.peerConnected,
    required this.errorCode,
  });

  factory HotspotBridgeState.initial(WifiHotspotSegment segment) =>
      HotspotBridgeState(
        segment: segment,
        phase: HotspotPhase.starting,
        credentials: null,
        peerConnected: false,
        errorCode: null,
      );

  HotspotBridgeState copyWith({
    WifiHotspotSegment? segment,
    HotspotPhase? phase,
    HotspotCredentials? credentials,
    bool? peerConnected,
    String? errorCode,
  }) => HotspotBridgeState(
    segment: segment ?? this.segment,
    phase: phase ?? this.phase,
    credentials: credentials ?? this.credentials,
    peerConnected: peerConnected ?? this.peerConnected,
    errorCode: errorCode,
  );

  @override
  List<Object?> get props => [
    segment,
    phase,
    credentials,
    peerConnected,
    errorCode,
  ];
}

/// Drives the Wi-Fi Hotspot Bridge — the reliable iPhone↔Android path.
///
/// Android (host): create a local-only Wi-Fi hotspot, expose its credentials
/// as a Wi-Fi QR, and watch the Wi-Fi transport for the first packet from the
/// joined peer. iOS (join): parse a scanned Wi-Fi QR and try to join the
/// network programmatically ([tryJoin]).
@injectable
class WifiHotspotCubit extends Cubit<HotspotBridgeState> {
  final WifiTransferRepositoryImpl _wifi;
  final WifiHotspotController _hotspot = WifiHotspotController();
  final HotspotJoiner _joiner = HotspotJoiner();

  StreamSubscription<WakiPacket>? _peerSub;
  bool _hostStarted = false;

  WifiHotspotCubit(this._wifi)
    : super(HotspotBridgeState.initial(WifiHotspotSegment.wifi));

  /// Switches the visible segment, lazily starting the Android hotspot host
  /// the first time the user picks "Hotspot" (never on iOS — it joins by
  /// scanning instead) rather than unconditionally on page open.
  void switchSegment(WifiHotspotSegment segment) {
    emit(state.copyWith(segment: segment));
    if (segment == WifiHotspotSegment.hotspot &&
        Platform.isAndroid &&
        !_hostStarted) {
      _hostStarted = true;
      startHost();
    }
  }

  /// Android host flow: request the Wi-Fi/location permissions LocalOnlyHotspot
  /// needs, start the hotspot, then listen for the peer.
  Future<void> startHost() async {
    emit(state.copyWith(phase: HotspotPhase.starting, errorCode: null));

    // LocalOnlyHotspot needs fine location (API 26–32) or NEARBY_WIFI_DEVICES
    // (33+). The manifest declares each only for its own SDK range and
    // permission_handler silently resolves undeclared permissions as denied,
    // so only the API-appropriate one can actually prompt. Proceed regardless
    // — the native side surfaces a hard permission failure as a
    // PlatformException we handle below.
    try {
      final permission = await AndroidSdk.version() >= 33
          ? Permission.nearbyWifiDevices
          : Permission.locationWhenInUse;
      await permission.request();
    } catch (e) {
      Logger.log('Hotspot permission request failed: $e');
    }
    if (isClosed) return;

    try {
      final creds = await _hotspot.start();
      if (isClosed) return;
      emit(state.copyWith(phase: HotspotPhase.ready, credentials: creds));
      Sfx.play(SfxEvent.linkRestored);
      _listenForPeer();
    } on PlatformException catch (e) {
      Logger.log('Hotspot start failed: ${e.code} ${e.message}');
      if (!isClosed) {
        emit(state.copyWith(phase: HotspotPhase.error, errorCode: e.code));
        Sfx.play(SfxEvent.error);
      }
    } catch (e) {
      Logger.log('Hotspot start failed: $e');
      if (!isClosed) {
        emit(state.copyWith(phase: HotspotPhase.error, errorCode: 'failed'));
        Sfx.play(SfxEvent.error);
      }
    }
  }

  void _listenForPeer() {
    _peerSub?.cancel();
    // Any packet from the shared LAN means the iPhone joined and entered the
    // channel. The Wi-Fi repo's generation counter makes it safe for the
    // walkie screen to call startListening() again after we navigate.
    _peerSub = _wifi.startListening().listen((_) {
      if (!isClosed && !state.peerConnected) {
        emit(state.copyWith(peerConnected: true));
        Sfx.play(SfxEvent.peerJoin);
      }
    }, onError: (Object e) => Logger.log('Hotspot peer listen error: $e'));
  }

  /// iOS join flow: attempt to join the Android host's network via
  /// NEHotspotConfiguration. Returns whether the auto-join succeeded; on
  /// failure the UI falls back to showing the credentials for a manual join.
  Future<bool> tryJoin(HotspotCredentials creds) =>
      _joiner.join(ssid: creds.ssid, passphrase: creds.passphrase);

  /// Tears the hotspot down — call this only when the user backs out WITHOUT
  /// entering the channel. When entering the channel we deliberately leave the
  /// AP up (the session runs over it); the native side then closes it on
  /// activity destroy or the next start().
  Future<void> stopHost() async {
    await _peerSub?.cancel();
    _peerSub = null;
    await _hotspot.stop();
  }

  @override
  Future<void> close() async {
    // Intentionally does NOT stop the hotspot: navigating into the walkie
    // session disposes this cubit while the AP must stay alive.
    await _peerSub?.cancel();
    return super.close();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio/api/audio_api.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/hotspot_control.dart';

/// Which end of the bridge this device is. Android can be either; iOS can only
/// join (a local-only hotspot can't be hosted from iOS).
enum HotspotRole { host, join }

enum HotspotPhase {
  /// Creating the local-only hotspot.
  starting,

  /// Hotspot is up — showing the QR/credentials and waiting for the peer to
  /// join and enter the channel.
  ready,

  /// The hotspot could not be created.
  error,
}

enum JoinPhase {
  /// Nothing scanned yet.
  idle,

  /// The scanned payload wasn't a Wi-Fi QR.
  invalid,

  /// Asking the OS to associate with the host's network.
  joining,

  /// On the host's network, pinned to it.
  joined,

  /// The programmatic join didn't take — fall back to joining by hand.
  manual,

  /// We were on the network and it went away.
  lost,
}

class HotspotBridgeState extends Equatable {
  final WifiHotspotSegment segment;

  /// Null until the user picks a side (iOS skips straight to [HotspotRole
  /// .join] — it can't host).
  final HotspotRole? role;

  final HotspotPhase phase;
  final JoinPhase joinPhase;

  /// The host's hotspot credentials: created by us when hosting, scanned from
  /// the host's QR when joining. Null until either happens.
  final HotspotCredentials? credentials;

  /// True once we've heard a packet from the peer over Wi-Fi — the cue to
  /// auto-advance into the channel.
  final bool peerConnected;

  /// Native error code (`tethering_on`, `location_off`, `permission_denied`,
  /// `no_channel`, `failed`, …) so the UI can tailor the message and offer the
  /// matching fix.
  final String? errorCode;

  const HotspotBridgeState({
    required this.segment,
    required this.role,
    required this.phase,
    required this.joinPhase,
    required this.credentials,
    required this.peerConnected,
    required this.errorCode,
  });

  factory HotspotBridgeState.initial(WifiHotspotSegment segment) =>
      HotspotBridgeState(
        segment: segment,
        role: null,
        phase: HotspotPhase.starting,
        joinPhase: JoinPhase.idle,
        credentials: null,
        peerConnected: false,
        errorCode: null,
      );

  HotspotBridgeState copyWith({
    WifiHotspotSegment? segment,
    HotspotRole? role,
    bool clearRole = false,
    HotspotPhase? phase,
    JoinPhase? joinPhase,
    HotspotCredentials? credentials,
    bool? peerConnected,
    String? errorCode,
  }) => HotspotBridgeState(
    segment: segment ?? this.segment,
    role: clearRole ? null : (role ?? this.role),
    phase: phase ?? this.phase,
    joinPhase: joinPhase ?? this.joinPhase,
    credentials: credentials ?? this.credentials,
    peerConnected: peerConnected ?? this.peerConnected,
    errorCode: errorCode,
  );

  @override
  List<Object?> get props => [
    segment,
    role,
    phase,
    joinPhase,
    credentials,
    peerConnected,
    errorCode,
  ];
}

/// Drives the Wi-Fi Hotspot Bridge — the reliable cross-device path when there
/// is no shared network.
///
/// One side hosts (Android only: a local-only Wi-Fi hotspot, exposed as a Wi-Fi
/// QR), the other scans that QR in the app's own scanner and joins the network
/// programmatically. Both then watch the Wi-Fi transport for the first packet
/// from the peer and slide into the ordinary channel. No step leaves the app.
@injectable
class WifiHotspotCubit extends Cubit<HotspotBridgeState> {
  final WifiTransferRepository _wifi;
  final HotspotHost _hotspot;
  final HotspotJoiner _joiner;
  final SfxPlayer _sfx;
  final SessionWakeLock _keepAlive;

  StreamSubscription<WakiPacket>? _peerSub;
  StreamSubscription<void>? _stoppedSub;
  StreamSubscription<void>? _lostSub;

  /// Native error code for a start we cancelled ourselves (HotspotHandler
  /// .CANCELLED) — not a failure to report.
  static const _cancelledCode = 'cancelled';

  WifiHotspotCubit(
    this._wifi,
    this._hotspot,
    this._joiner,
    this._sfx,
    this._keepAlive,
  ) : super(HotspotBridgeState.initial(WifiHotspotSegment.wifi));

  /// Switches the visible segment. Picking "Hotspot" only offers the host/join
  /// choice — nothing touches the radio until the user commits to a side, so a
  /// device that can't host never shows a failure it didn't ask for. iOS has no
  /// choice to make and goes straight to joining.
  void switchSegment(WifiHotspotSegment segment) {
    emit(state.copyWith(segment: segment, errorCode: null));
    if (segment == WifiHotspotSegment.hotspot &&
        Platform.isIOS &&
        state.role == null) {
      chooseRole(HotspotRole.join);
    }
  }

  Future<void> chooseRole(HotspotRole role) async {
    emit(
      state.copyWith(
        role: role,
        joinPhase: JoinPhase.idle,
        errorCode: null,
      ),
    );
    if (role == HotspotRole.host) await startHost();
  }

  /// Back to the host/join choice, undoing whatever the abandoned side set up.
  ///
  /// The role is cleared *before* the teardown, not after. Back is a tap: it
  /// has to land on the frame it was pressed, and the teardown behind it is a
  /// pair of platform calls that can take their time — closing the peer socket
  /// while `startHost()` is still awaiting `startLocalOnlyHotspot` (which only
  /// answers from a callback, and on some devices doesn't) left the emit
  /// unreachable and back looking dead. Switching segment still worked, since
  /// that emits synchronously, which is exactly the shape of the bug.
  Future<void> backToRoleChoice() async {
    final wasHost = state.role == HotspotRole.host;
    emit(
      state.copyWith(
        clearRole: true,
        phase: HotspotPhase.starting,
        joinPhase: JoinPhase.idle,
        errorCode: null,
      ),
    );
    // An in-flight startHost() may still land after this; it copies from the
    // state as it finds it, so a late `ready` can't put the role back.
    await _teardownSubscriptions();
    if (wasHost) {
      await _hotspot.stop();
      unawaited(_keepAlive.stop());
    } else {
      await _joiner.leave();
    }
  }

  // ---------------------------------------------------------------- hosting

  /// Host flow: request the Wi-Fi/location permissions LocalOnlyHotspot needs,
  /// start the hotspot, then listen for the peer.
  Future<void> startHost() async {
    emit(state.copyWith(phase: HotspotPhase.starting, errorCode: null));

    // LocalOnlyHotspot needs fine location (API 26–32) or NEARBY_WIFI_DEVICES
    // (33+). On API 31–32 the fine-location request only works because COARSE
    // is declared alongside it — Android 12 ignores a fine-only request (see
    // AndroidManifest). Proceed regardless of the outcome: the native side
    // preflights the permission and reports `permission_denied`, which the UI
    // can explain better than a bare failure.
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
      _sfx.play(SfxEvent.linkRestored);
      // Guard the AP from the moment it's up — not only once the channel is
      // entered. Without a wake lock during the "waiting for the peer to scan
      // and join" window, the host can hit screen-off/Doze and the OS tears
      // the SoftAP down before anyone connects. usesMicrophone:false because
      // the mic isn't recording yet (see SessionKeepAlive.start).
      unawaited(_keepAlive.start(usesMicrophone: false));
      _watchForTeardown();
      _listenForPeer();
    } on PlatformException catch (e) {
      Logger.log('Hotspot start failed: ${e.code} ${e.message}');
      // `cancelled` means we tore this attempt down ourselves — the user backed
      // out to the role picker, or a retry superseded it. Showing an error card
      // for our own teardown would paint failure over a screen that has already
      // moved on, so it stays silent.
      if (isClosed || e.code == _cancelledCode) return;
      emit(state.copyWith(phase: HotspotPhase.error, errorCode: e.code));
      _sfx.play(SfxEvent.error);
    } catch (e) {
      Logger.log('Hotspot start failed: $e');
      if (!isClosed) {
        emit(state.copyWith(phase: HotspotPhase.error, errorCode: 'failed'));
        _sfx.play(SfxEvent.error);
      }
    }
  }

  /// Opens the system screen that fixes the current host error (Location for
  /// `location_off`, tethering for `tethering_on`).
  Future<void> openFixSettings() async {
    final code = state.errorCode;
    if (code != null) await _hotspot.openFixSettings(code);
  }

  /// Recovers from an OS-initiated hotspot teardown while we're still on this
  /// page waiting for the peer. The native side only fires this for a teardown
  /// it didn't initiate (radio conflict, Doze, an STA reconnect stealing the
  /// single radio) — re-hosting brings the AP back with fresh credentials so
  /// the QR/creds refresh and the peer can join again, instead of the page
  /// sitting dead on a network that no longer exists. Once the peer has joined
  /// we've navigated into the channel (cubit closing), so we don't re-host
  /// then — the live session's own health/reconnect path owns recovery.
  void _watchForTeardown() {
    _stoppedSub?.cancel();
    _stoppedSub = _hotspot.onStopped.listen((_) {
      if (isClosed || state.peerConnected) return;
      Logger.log('Hotspot torn down by OS — re-hosting');
      startHost();
    }, onError: (Object e) => Logger.log('Hotspot teardown listen error: $e'));
  }

  // ---------------------------------------------------------------- joining

  /// Handles a payload from the in-app scanner.
  Future<void> submitScannedCode(String raw) async {
    final creds = HotspotCredentials.fromWifiQr(raw);
    if (creds == null) {
      emit(state.copyWith(joinPhase: JoinPhase.invalid));
      _sfx.play(SfxEvent.error);
      return;
    }
    await joinNetwork(creds);
  }

  /// Join flow: hand the scanned credentials to the OS. On Android this is a
  /// [WifiNetworkSpecifier] request — one system dialog, no settings trip; on
  /// iOS, NEHotspotConfiguration. Either way the UI falls back to a manual join
  /// if the OS won't do it for us.
  Future<void> joinNetwork(HotspotCredentials creds) async {
    emit(
      state.copyWith(
        credentials: creds,
        joinPhase: JoinPhase.joining,
        errorCode: null,
      ),
    );
    final joined = await _joiner.join(creds);
    if (isClosed) return;
    if (!joined) {
      emit(state.copyWith(joinPhase: JoinPhase.manual));
      _sfx.play(SfxEvent.error);
      return;
    }
    _onJoined();
  }

  /// The manual fallback's "I've joined" — the association already exists, so
  /// all that's left is pinning this process to it.
  Future<void> confirmManualJoin() async {
    await _joiner.bindToCurrentWifi();
    if (isClosed) return;
    _onJoined();
  }

  void _onJoined() {
    emit(state.copyWith(joinPhase: JoinPhase.joined));
    _sfx.play(SfxEvent.linkRestored);
    // A socket keeps whatever network it was created on, and the process was
    // only just pinned to the hotspot — drop any socket from before the join
    // so the listener below binds on the right side of the bridge.
    _wifi.stopConnection();
    unawaited(_keepAlive.start(usesMicrophone: false));
    _watchForLinkLoss();
    _listenForPeer();
  }

  /// The host's AP went away while we were still on this page. Surface it
  /// instead of showing a "joined" screen for a network that no longer exists;
  /// the credentials are still on hand, so recovery is one tap.
  void _watchForLinkLoss() {
    _lostSub?.cancel();
    _lostSub = _joiner.onLost.listen((_) {
      if (isClosed || state.peerConnected) return;
      Logger.log('Hotspot link lost — offering rejoin');
      _peerSub?.cancel();
      _peerSub = null;
      emit(state.copyWith(joinPhase: JoinPhase.lost));
      _sfx.play(SfxEvent.error);
    }, onError: (Object e) => Logger.log('Hotspot lost listen error: $e'));
  }

  /// Back to the scanner after an invalid code or a lost link.
  void resetJoin() => emit(state.copyWith(joinPhase: JoinPhase.idle));

  // ----------------------------------------------------------------- shared

  void _listenForPeer() {
    _peerSub?.cancel();
    // Any packet on the shared LAN means the other side is in the channel. The
    // Wi-Fi repo's generation counter makes it safe for the walkie screen to
    // call startListening() again after we navigate.
    _peerSub = _wifi.startListening().listen((_) {
      if (!isClosed && !state.peerConnected) {
        emit(state.copyWith(peerConnected: true));
        _sfx.play(SfxEvent.peerJoin);
      }
    }, onError: (Object e) => Logger.log('Hotspot peer listen error: $e'));
  }

  /// Tears the bridge down — call this only when the user backs out WITHOUT
  /// entering the channel. When entering the channel we deliberately leave both
  /// the AP and the joined-network binding in place (the session runs over
  /// them); the native side then releases them on activity destroy or the next
  /// start().
  Future<void> leaveBridge() async {
    await _teardownSubscriptions();
    await _hotspot.stop();
    await _joiner.leave();
    // Backing out without entering the channel: the bridge duty is over, so
    // drop the keep-alive we took when the link came up. (When we instead enter
    // the channel, close() runs and deliberately leaves it — the session owns
    // it.)
    unawaited(_keepAlive.stop());
  }

  Future<void> _teardownSubscriptions() async {
    await _peerSub?.cancel();
    _peerSub = null;
    await _stoppedSub?.cancel();
    _stoppedSub = null;
    await _lostSub?.cancel();
    _lostSub = null;
  }

  @override
  Future<void> close() async {
    // Intentionally does NOT stop the hotspot, release the joined network OR
    // stop the keep-alive: navigating into the walkie session disposes this
    // cubit while the link — and the foreground service guarding it — must stay
    // alive.
    await _teardownSubscriptions();
    return super.close();
  }
}

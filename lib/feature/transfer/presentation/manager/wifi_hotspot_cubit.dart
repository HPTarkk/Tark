import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/analytics/analytics.dart';
import '../../../../core/analytics/analytics_event.dart';
import '../../../../core/analytics/pairing_attempt.dart';
import '../../../../core/recovery/bounded_retry.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/permission_queue.dart';
import '../../../audio/api/audio_api.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/hotspot_control.dart';
import '../../domain/service/hotspot_link_keeper.dart';
import '../../domain/service/session_role_store.dart';

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

  /// The Wi-Fi radio is off. Not a failure to work around like [manual]: the
  /// join can't even be attempted, and pointing the user at a Wi-Fi list that
  /// isn't scanning is worse than useless. One switch fixes it.
  wifiOff,

  /// The system Location toggle is off, which stops Wi-Fi scanning through
  /// Android 12 — same shape as [wifiOff], different switch.
  locationOff,

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

  /// How far the automatic host retries have got, so the waiting screen can
  /// admit it's been a while instead of showing the same label forever.
  final RetryPhase hostRetry;

  const HotspotBridgeState({
    required this.segment,
    required this.role,
    required this.phase,
    required this.joinPhase,
    required this.credentials,
    required this.peerConnected,
    required this.errorCode,
    required this.hostRetry,
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
        hostRetry: RetryPhase.idle,
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
    RetryPhase? hostRetry,
  }) => HotspotBridgeState(
    segment: segment ?? this.segment,
    role: clearRole ? null : (role ?? this.role),
    phase: phase ?? this.phase,
    joinPhase: joinPhase ?? this.joinPhase,
    credentials: credentials ?? this.credentials,
    peerConnected: peerConnected ?? this.peerConnected,
    errorCode: errorCode,
    hostRetry: hostRetry ?? this.hostRetry,
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
    hostRetry,
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
  final SessionRoleStore _roleStore;
  final HotspotLinkKeeper _linkKeeper;
  final Analytics _analytics;
  late final PairingAttempt _pairing;

  StreamSubscription<WakiPacket>? _peerSub;
  StreamSubscription<void>? _stoppedSub;
  StreamSubscription<void>? _lostSub;

  /// Native error code for a start we cancelled ourselves (HotspotHandler
  /// .CANCELLED) — not a failure to report.
  static const _cancelledCode = 'cancelled';

  /// Bringing a SoftAP up fails transiently more often than it fails for
  /// real: the radio is mid-handoff, the previous AP hasn't finished tearing
  /// down, the driver wants a moment. Before this, the first such failure
  /// went straight to a red error card — for a problem that would have
  /// cleared on its own a second later.
  late final BoundedRetry _hostRetry = BoundedRetry(name: 'hotspot-host');
  StreamSubscription<RetryPhase>? _hostRetrySub;

  /// Failures the user has to fix themselves. Retrying these just spends ten
  /// seconds not telling them the one thing they need to hear.
  static bool _isRetryable(String code) => switch (code) {
    'tethering_on' ||
    'location_off' ||
    'permission_denied' ||
    'unsupported' => false,
    // Everything else — a busy channel, an incompatible Wi-Fi mode mid-switch,
    // a bare `failed` — is the kind of thing that usually works second time.
    _ => true,
  };

  WifiHotspotCubit(
    this._wifi,
    this._hotspot,
    this._joiner,
    this._sfx,
    this._keepAlive,
    this._roleStore,
    this._linkKeeper,
    this._analytics,
  ) : super(HotspotBridgeState.initial(WifiHotspotSegment.wifi)) {
    _pairing = PairingAttempt(
      _analytics,
      transport: AnalyticsTransport.hotspot,
    );
    _hostRetrySub = _hostRetry.phases.listen((phase) {
      if (!isClosed) emit(state.copyWith(hostRetry: phase));
    });
  }

  /// Maps the native hotspot error codes onto the analytics failure
  /// vocabulary. The distinction that matters operationally is whether the
  /// framework refused us outright (fixable by the user: a permission, a
  /// setting) or the AP simply never came on the air (a device/driver
  /// problem we have to work around) — see HotspotHandler for where these
  /// codes originate.
  static PairFailure _hostFailure(String code) => switch (code) {
    'permission_denied' => PairFailure.permissionDenied,
    'location_off' || 'tethering_on' || 'unsupported' =>
      PairFailure.frameworkRefused,
    _ => PairFailure.apNeverUp,
  };

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
    _pairing.start(
      role == HotspotRole.host ? PairRole.host : PairRole.joiner,
    );
    emit(
      state.copyWith(
        role: role,
        joinPhase: JoinPhase.idle,
        errorCode: null,
      ),
    );
    // The session that follows runs over plain UDP, which carries no trace of
    // who brought the network up — this is the only moment that knows.
    _roleStore.setRole(
      role == HotspotRole.host ? SessionRole.host : SessionRole.joiner,
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
    // Before anything else: a retry cycle still counting down would otherwise
    // bring an AP up behind a screen the user has just left.
    _hostRetry.cancel();
    emit(
      state.copyWith(
        clearRole: true,
        phase: HotspotPhase.starting,
        joinPhase: JoinPhase.idle,
        errorCode: null,
        hostRetry: RetryPhase.idle,
      ),
    );
    _roleStore.clear();
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

  /// Gives up whichever side of the bridge this device is NOT playing.
  ///
  /// A phone can be a hotspot host and someone else's hotspot client at the
  /// same time. Android is perfectly happy to do it, the pairing screen never
  /// stopped it, and two people each tapping "host" and then scanning the
  /// other's QR is all it takes — which is exactly what a field session
  /// produced. Both phones ended up on both networks:
  ///
  ///   A: local={192.168.43.1, 10.122.230.134}
  ///   B: local={10.122.230.245, 192.168.43.181}
  ///
  /// Every packet then went out on both subnets and arrived several times by
  /// paths seconds apart. [SenderRoutePin] now discards the extra copies so
  /// the audio survives, but nothing downstream can give back the air time and
  /// battery already spent putting them there: the receiving phone counted
  /// 4.5x more datagrams in than the sender counted out, and the host's SoftAP
  /// queue jammed under the load.
  ///
  /// So the roles are made exclusive at the only place that knows: the moment
  /// this device commits to one. Called from [startHost] and [_onJoined]
  /// rather than from [chooseRole], because those two are the funnels every
  /// path arrives through — including the ones that never touch the role
  /// picker, which is how the state above was reached despite
  /// [backToRoleChoice] already tearing down the abandoned side.
  ///
  /// Idempotent and best-effort by design. Stopping a hotspot that was never
  /// started, or leaving a network we never joined, is a no-op on every
  /// platform; and a failure here must not block the side we are actually
  /// taking, so it is logged and swallowed.
  ///
  /// One case this cannot fix: a hotspot the user turned on from the system
  /// quick-settings panel rather than through the app. Android only lets an
  /// app release its own LocalOnlyHotspot reservation. The transport's SPLIT
  /// ROUTE warning is what catches that one.
  Future<void> _dropOtherSide({required bool nowHosting}) async {
    try {
      if (nowHosting) {
        await _joiner.leave();
      } else {
        await _hotspot.stop();
        unawaited(_keepAlive.stop());
      }
      Logger.diagnostic(
        nowHosting
            ? 'link: hosting now — left any hotspot we had joined, so we are '
                  'on one network rather than two'
            : 'link: joined now — dropped our own hotspot, so we are on one '
                  'network rather than two',
      );
    } catch (e) {
      // Not fatal: the worst case is the multi-homed state we were avoiding,
      // which the transport already detects and copes with.
      Logger.diagnostic('link: could not release the other side: $e');
    }
  }

  // ---------------------------------------------------------------- hosting

  /// Host flow: request the Wi-Fi/location permissions LocalOnlyHotspot needs,
  /// start the hotspot, then listen for the peer.
  Future<void> startHost() async {
    emit(state.copyWith(phase: HotspotPhase.starting, errorCode: null));

    // Taking one side of the bridge gives up the other. See [_dropOtherSide].
    await _dropOtherSide(nowHosting: true);
    if (isClosed) return;

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
      await PermissionQueue.run(() => permission.request());
    } catch (e) {
      Logger.log('Hotspot permission request failed: $e');
    }
    if (isClosed) return;

    // Up to four goes before anyone is shown a failure. The screen stays on
    // its ordinary "creating the hotspot" state throughout — a transient
    // radio hiccup that clears on attempt two should never have looked like
    // a problem in the first place.
    String? code;
    var succeeded = false;
    await _hostRetry.run((attempt) async {
      try {
        final creds = await _hotspot.start();
        if (isClosed) throw const RetryAbort();
        succeeded = true;
        _onHostReady(creds);
        return true;
      } on PlatformException catch (e) {
        code = e.code;
        Logger.log('Hotspot start failed: ${e.code} ${e.message}');
        // `cancelled` means we tore this attempt down ourselves — the user
        // backed out to the role picker, or a retry superseded it. Retrying
        // our own teardown would fight the user for control of the screen.
        if (e.code == _cancelledCode || !_isRetryable(e.code)) {
          throw const RetryAbort();
        }
        return false;
      } catch (e) {
        code = 'failed';
        Logger.log('Hotspot start failed: $e');
        return false;
      }
    });

    if (isClosed || succeeded) return;
    // Showing an error card for our own teardown would paint failure over a
    // screen that has already moved on, so it stays silent.
    if (code == _cancelledCode) return;
    // Reported only here, after the retry cycle is spent — the transient
    // failures it swallows are exactly the ones that would make the AP look
    // far less reliable than it is.
    _pairing.failed(PairStage.apSetup, _hostFailure(code ?? 'failed'));
    emit(state.copyWith(phase: HotspotPhase.error, errorCode: code ?? 'failed'));
    _sfx.play(SfxEvent.error);
  }

  void _onHostReady(HotspotCredentials creds) {
    emit(state.copyWith(phase: HotspotPhase.ready, credentials: creds));
    _sfx.play(SfxEvent.linkRestored);
    _linkKeeper.adopt(creds);
    // Guard the AP from the moment it's up — not only once the channel is
    // entered. Without a wake lock during the "waiting for the peer to scan
    // and join" window, the host can hit screen-off/Doze and the OS tears
    // the SoftAP down before anyone connects. usesMicrophone:false because
    // the mic isn't recording yet (see SessionKeepAlive.start).
    unawaited(_keepAlive.start(usesMicrophone: false));
    _watchForTeardown();
    _listenForPeer();
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
    _analytics.track(AnalyticsEvent.featureUsed(AppFeature.qrScan));
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
    final result = await _joiner.join(creds);
    if (isClosed) return;
    if (result != HotspotJoinResult.joined) {
      Logger.log('Hotspot join for "${creds.ssid}" ended as ${result.name}');
      emit(
        state.copyWith(
          joinPhase: switch (result) {
            HotspotJoinResult.wifiOff => JoinPhase.wifiOff,
            HotspotJoinResult.locationOff => JoinPhase.locationOff,
            _ => JoinPhase.manual,
          },
        ),
      );
      _sfx.play(SfxEvent.error);
      return;
    }
    _onJoined();
  }

  /// The Wi-Fi-off card's "turn it on". Where the OS lets us flip the radio
  /// ourselves (pre-API-29) the join resumes on the spot; from API 29 the user
  /// gets a system toggle instead, and the card keeps its "join again" button
  /// for once they've flipped it — there is no reliable signal for "the panel
  /// was dismissed" to retry off.
  Future<void> enableWifiAndRetry() async {
    final enabled = await _joiner.enableWifi();
    if (isClosed || !enabled) return;
    final creds = state.credentials;
    if (creds != null) await joinNetwork(creds);
  }

  /// The Location-off card's fix. Always a trip to Settings — no API level
  /// lets an app flip this one — so the card keeps its "join again" button for
  /// the way back.
  Future<void> openLocationSettings() => _joiner.openLocationSettings();

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
    // We are on someone else's AP now, so ours has no reason to exist — and
    // every reason not to. See [_dropOtherSide]. Not awaited: the join has
    // already succeeded and the link handoff below must not wait on a platform
    // teardown that can take its time (or, on some devices, never answer).
    unawaited(_dropOtherSide(nowHosting: false));
    // Hand the link to something that outlives this screen. From here the
    // session runs for as long as the user talks, and this cubit is disposed
    // the moment the channel opens — see [HotspotLinkKeeper].
    final creds = state.credentials;
    if (creds != null) _linkKeeper.adopt(creds);
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
      // The AP went away before anyone arrived. The earlier join phases
      // (wifiOff, locationOff, manual) deliberately report nothing: every one
      // of them is recoverable in place, and calling them failures would
      // count joins that went on to succeed as losses.
      _pairing.failed(PairStage.apSetup, PairFailure.apNeverUp);
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
        // The honest "connected" moment for this transport, for both sides:
        // an AP that is up (host) or joined (joiner) with nobody on the other
        // end is not a pairing anyone would call successful.
        _pairing.connected();
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
    _pairing.failed(PairStage.apSetup, PairFailure.userCancelled);
    _hostRetry.cancel();
    await _teardownSubscriptions();
    // Before the teardown below, so a recovery in flight cannot re-establish
    // the very link we are about to drop.
    await _linkKeeper.release();
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
    // alive. An attempt still open here is that same navigation, not a
    // failure, so it's abandoned rather than reported.
    _pairing.abandon();
    await _hostRetrySub?.cancel();
    _hostRetry.dispose();
    await _teardownSubscriptions();
    return super.close();
  }
}

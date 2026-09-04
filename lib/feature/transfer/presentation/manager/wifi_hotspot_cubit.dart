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
import '../../../../core/identity/channel_id.dart';
import '../../../../core/identity/channel_membership.dart';
import '../../../../core/recovery/bounded_retry.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/permission_queue.dart';
import '../../../audio/api/audio_api.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/entity/wifi_hotspot_segment.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/hotspot_control.dart';
import '../../domain/service/hotspot_link_keeper.dart';
import '../../domain/service/session_role_store.dart';
import '../../domain/service/transfer_mode_store.dart';

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

  /// Whether this device's Wi-Fi is on while its radio can't hold a client
  /// connection and the AP at once — see [HotspotWifiAdvice].
  final HotspotWifiAdvice wifiAdvice;

  /// The OS has already torn our AP down at least once this session. Doesn't
  /// change what the note advises, only how hard it presses: before a drop it
  /// is a suggestion, after one it is the likeliest explanation for what the
  /// user just watched happen.
  final bool hotspotDropped;

  /// The user dismissed the note. Held in session state rather than persisted —
  /// this is advice about the phone's state *right now*, and a phone whose
  /// Wi-Fi is off next time will never show it again anyway.
  final bool wifiNoteDismissed;

  /// The channel this device is in, mirrored here so the host screen can print
  /// the code beneath the QR without reaching into [ChannelMembership] from a
  /// widget. [ChannelId.open] until hosting creates one.
  final ChannelId channelId;

  const HotspotBridgeState({
    required this.segment,
    required this.role,
    required this.phase,
    required this.joinPhase,
    required this.credentials,
    required this.peerConnected,
    required this.errorCode,
    required this.hostRetry,
    required this.wifiAdvice,
    required this.hotspotDropped,
    required this.wifiNoteDismissed,
    required this.channelId,
  });

  /// Whether the host screen should show the "turn Wi-Fi off" note: there is
  /// something worth saying, the user hasn't waved it away, and we are actually
  /// hosting — the advice is meaningless to the joiner, whose Wi-Fi has to stay
  /// on to reach the host at all.
  bool get showWifiNote =>
      role == HotspotRole.host &&
      wifiAdvice.shouldSuggestWifiOff &&
      !wifiNoteDismissed;

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
        wifiAdvice: HotspotWifiAdvice.none,
        hotspotDropped: false,
        wifiNoteDismissed: false,
        channelId: ChannelId.open,
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
    HotspotWifiAdvice? wifiAdvice,
    bool? hotspotDropped,
    bool? wifiNoteDismissed,
    ChannelId? channelId,
  }) => HotspotBridgeState(
    segment: segment ?? this.segment,
    role: clearRole ? null : (role ?? this.role),
    phase: phase ?? this.phase,
    joinPhase: joinPhase ?? this.joinPhase,
    credentials: credentials ?? this.credentials,
    peerConnected: peerConnected ?? this.peerConnected,
    errorCode: errorCode,
    hostRetry: hostRetry ?? this.hostRetry,
    wifiAdvice: wifiAdvice ?? this.wifiAdvice,
    hotspotDropped: hotspotDropped ?? this.hotspotDropped,
    wifiNoteDismissed: wifiNoteDismissed ?? this.wifiNoteDismissed,
    channelId: channelId ?? this.channelId,
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
    wifiAdvice,
    hotspotDropped,
    wifiNoteDismissed,
    channelId.value,
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
  final ChannelMembership _membership;

  /// Written, never read for routing: this page is the only place that knows
  /// whether the network the phone ends up on is one a member of the Room
  /// built or one it merely walked into. See [_recordCarrier].
  final TransferModeStore _modeStore;
  late final PairingAttempt _pairing;

  StreamSubscription<WakiPacket>? _peerSub;
  StreamSubscription<void>? _stoppedSub;
  StreamSubscription<void>? _lostSub;

  /// Whether our own AP has already been dropped for the join now in progress.
  /// See [_dropOwnApBeforeJoining]; reset wherever an AP can come back up.
  bool _ownApDropped = false;

  /// How long the teardown of our own AP may hold up a join.
  ///
  /// `stop()` is a platform call that on some devices never answers, and the
  /// join is worth more than a clean teardown — proceeding multi-homed is the
  /// state the transport already detects and copes with.
  static const _ownApTeardownTimeout = Duration(seconds: 3);

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
    this._membership,
    this._modeStore,
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
    'location_off' ||
    'tethering_on' ||
    'unsupported' => PairFailure.frameworkRefused,
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
    _pairing.start(role == HotspotRole.host ? PairRole.host : PairRole.joiner);
    // Hosting means there is a channel to be in, and its code has to exist
    // before the QR is drawn. `createIfNone` rather than `create` because the
    // landing page's "start a channel" has usually made one already, and
    // renumbering here would change a code the other phone may be looking at.
    if (role == HotspotRole.host) {
      emit(state.copyWith(channelId: _membership.createIfNone()));
    }
    emit(
      state.copyWith(role: role, joinPhase: JoinPhase.idle, errorCode: null),
    );
    // The session that follows runs over plain UDP, which carries no trace of
    // who brought the network up — this is the only moment that knows.
    _roleStore.setRole(
      role == HotspotRole.host ? SessionRole.host : SessionRole.joiner,
    );
    if (role == HotspotRole.host) await startHost();
  }

  /// Writes down which kind of network this page just put the phone on.
  ///
  /// **Nothing was doing this**, and the consequence was not obvious. The mode
  /// is what `RoomCarrierPromotionPlanner.durabilityOf` reads to decide whether
  /// the Room is on a network it *owns* or one it has *borrowed*, and a bridge
  /// that never recorded itself left every phone reading `wifi` — so a pair
  /// sitting on one another's hotspot was classified as borrowed, and the
  /// carrier promotion set about arranging a move off a network the group had
  /// just built. The only writers were the failover runtime and a landing-page
  /// commit that has had no callers since the Room entry replaced it.
  ///
  /// Both directions are written, and the second matters as much as the first:
  /// a phone that used the bridge last week and is on a café router today must
  /// stop calling that router "ours", or the one moment the carrier handover
  /// exists for — the borrowed network vanishing at the end of the street —
  /// passes unnoticed.
  void _recordCarrier(TransferMode mode) {
    if (_modeStore.mode == mode) return;
    Logger.diagnostic('hotspot: carrier recorded as ${mode.key}');
    unawaited(_modeStore.setMode(mode));
  }

  /// The shared-network exit from this page: both phones were already on one
  /// network and nobody here owns it.
  void recordSharedNetwork() => _recordCarrier(TransferMode.wifi);

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
    _ownApDropped = false;
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
        // The keep-alive deliberately survives this. It is one process-wide
        // foreground service, not a thing each role owns a copy of, and
        // [_onJoined] — the only caller that gets here — starts it again with
        // the same arguments the host used, two statements later.
        //
        // Stopping it here therefore bought nothing and cost the app: this
        // method is not awaited, so the start lands first and the stop arrives
        // in the window between `startForegroundService()` and the service's
        // own `startForeground()`. Android answers that with a fatal
        // RemoteServiceException — "did not then call Service.startForeground()"
        // — which is not an ANR but a kill, and reads on the phone as the app
        // vanishing to the launcher a moment after the join. Caught on a Galaxy
        // S8+ 52ms after the join line:
        //
        //   07:27:30.179  link: joined now — dropped our own hotspot
        //   07:27:30.196  Bringing down service while still waiting for start
        //                 foreground: SessionKeepAliveService
        //   07:27:30.230  FATAL EXCEPTION: main
        //
        // [backToRoleChoice] still stops it, and should: nothing restarts it
        // there.
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

  /// Drops our own AP *before* the process is pinned to the host's, rather
  /// than after.
  ///
  /// Two live Wi-Fi networks is exactly the ambiguity the native bind refuses
  /// to guess between (see `WifiJoinHandler.findExpectedWifiNetwork`), and the
  /// bind is what makes a join real. Doing this from [_onJoined] meant the one
  /// moment it mattered — while `bindCurrent` was choosing — was the one
  /// moment it had not run yet: caught on a Galaxy S8+, where the bind was
  /// refused 3ms before the AP came down.
  ///
  /// This also puts the teardown safely ahead of [_onJoined]'s
  /// `_keepAlive.start()` rather than racing it, which is the ordering the
  /// unawaited call in [_dropOtherSide]'s comment was there to protect.
  Future<void> _dropOwnApBeforeJoining() async {
    if (_ownApDropped) return;
    _ownApDropped = true;
    await _dropOtherSide(nowHosting: false).timeout(
      _ownApTeardownTimeout,
      onTimeout: () => Logger.diagnostic(
        'link: our own AP did not answer a stop in time — joining anyway',
      ),
    );
  }

  // ---------------------------------------------------------------- hosting

  /// Host flow: request the Wi-Fi/location permissions LocalOnlyHotspot needs,
  /// start the hotspot, then listen for the peer.
  Future<void> startHost() async {
    emit(state.copyWith(phase: HotspotPhase.starting, errorCode: null));

    // Asked before the AP goes up, not after. On a single-radio phone the
    // framework may drop the STA connection as the hotspot starts, so reading
    // afterwards can report Wi-Fi already off and stay quiet about a radio
    // that will reconnect and take the AP with it minutes later.
    unawaited(refreshWifiAdvice());

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
    emit(
      state.copyWith(phase: HotspotPhase.error, errorCode: code ?? 'failed'),
    );
    _sfx.play(SfxEvent.error);
  }

  void _onHostReady(HotspotCredentials creds) {
    // There is an AP of ours to drop again, so a later join has to.
    _ownApDropped = false;
    _recordCarrier(TransferMode.hotspot);
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

  /// Re-reads whether Wi-Fi is putting this host's AP at risk.
  ///
  /// Called on entering the host flow and again every time the app comes back
  /// to the foreground, which is what makes the note disappear by itself once
  /// the user has acted on it — the alternative is a card still asking for
  /// something they have already done, which is how advice stops being read.
  Future<void> refreshWifiAdvice() async {
    final advice = await _hotspot.wifiAdvice();
    if (isClosed) return;
    emit(state.copyWith(wifiAdvice: advice));
  }

  /// Hands the user the Wi-Fi toggle. We cannot flip it ourselves —
  /// `setWifiEnabled` is a no-op for non-system apps since Android 10 — so the
  /// most this can do is put the switch one tap away without losing the screen
  /// the other phone is scanning.
  Future<void> openWifiPanel() async {
    _sfx.play(SfxEvent.toggle);
    final floated = await _hotspot.openWifiPanel();
    if (isClosed) return;
    // The floating panel sits *over* us without backgrounding the app, so the
    // page's resume hook never fires and the note would sit there contradicted
    // by a radio the user just switched off. Re-read on a short leash instead.
    // A handful of cheap reads over a few seconds, not a standing timer: the
    // answer only changes because of something happening on screen right now.
    if (floated) {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (isClosed) return;
        await refreshWifiAdvice();
        if (isClosed || !state.wifiAdvice.wifiEnabled) return;
      }
    }
  }

  /// Waves the note away for the rest of this session. Never persisted — it is
  /// advice about the radio's state right now, and a phone that arrives with
  /// Wi-Fi already off never shows it in the first place.
  void dismissWifiNote() => emit(state.copyWith(wifiNoteDismissed: true));

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
      // Remembered, and un-dismissible from here on: with Wi-Fi on and no
      // STA+AP concurrency, an STA reconnect stealing the radio is the single
      // likeliest cause of what just happened. Having waved the note away
      // before the drop is not a reason to stay quiet after it — that is the
      // moment the advice stopped being hypothetical.
      emit(state.copyWith(hotspotDropped: true, wifiNoteDismissed: false));
      startHost();
    }, onError: (Object e) => Logger.log('Hotspot teardown listen error: $e'));
  }

  // ---------------------------------------------------------------- joining

  /// Handles a payload from the in-app scanner.
  ///
  /// The channel is adopted *before* the network is joined, and stays adopted
  /// even where the code carried no network at all. Both halves of a scanned
  /// code are independent — see [ScannedCode] — and the ordering matters:
  /// joining the network is what starts traffic flowing, so a channel adopted
  /// afterwards would leave a window in which we transmit into the open and
  /// hear a neighbouring group.
  Future<void> submitScannedCode(String raw) async {
    _analytics.track(AnalyticsEvent.featureUsed(AppFeature.qrScan));
    final scanned = ScannedCode.parse(raw);
    if (scanned == null) {
      emit(state.copyWith(joinPhase: JoinPhase.invalid));
      _sfx.play(SfxEvent.error);
      return;
    }
    if (!scanned.channel.isOpen) _membership.join(scanned.channel);
    final creds = scanned.credentials;
    if (creds == null) {
      // A channel-only code: we are already on the right network, so there is
      // nothing to associate with and the bridge's job is done the moment the
      // channel is adopted.
      emit(state.copyWith(joinPhase: JoinPhase.joined));
      _sfx.play(SfxEvent.linkRestored);
      _listenForPeer();
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
    // Ours goes down before theirs comes up — see [_dropOwnApBeforeJoining].
    await _dropOwnApBeforeJoining();
    if (isClosed) return;
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
  ///
  /// The pin is the whole of it, so its result is the whole answer. Calling
  /// [_onJoined] regardless is the worst outcome available: sockets bind to an
  /// address that looks right while the process still routes through the
  /// default network, so the channel is silent in both directions, the screen
  /// says "joined", and nothing anywhere says why.
  Future<void> confirmManualJoin() async {
    await _dropOwnApBeforeJoining();
    if (isClosed) return;
    final pinned = await _joiner.bindToCurrentWifi();
    if (isClosed) return;
    if (!pinned) {
      Logger.log('Manual join could not pin the process to the current Wi-Fi');
      // Back to the same card, now saying what went wrong. The AP is already
      // down, so the retry this invites is the one with the best odds of
      // working — one Wi-Fi network for the bind to find.
      emit(state.copyWith(joinPhase: JoinPhase.manual, errorCode: _notPinned));
      _sfx.play(SfxEvent.error);
      return;
    }
    _onJoined();
  }

  /// The manual join found no network it could pin the process to.
  static const _notPinned = 'not_pinned';

  void _onJoined() {
    _recordCarrier(TransferMode.hotspot);
    emit(state.copyWith(joinPhase: JoinPhase.joined));
    _sfx.play(SfxEvent.linkRestored);
    // We are on someone else's AP now, so ours has no reason to exist — and
    // every reason not to. Ordinarily already done before the join (see
    // [_dropOwnApBeforeJoining]); kept here, idempotent and unawaited, for any
    // path that reaches this without passing through one of the two funnels.
    unawaited(_dropOwnApBeforeJoining());
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
    // Backing out without connecting gives up the channel too. Keeping it
    // would leave the phone filtering against a code nobody else is using —
    // silence, with a screen reporting a perfectly healthy link, which is the
    // exact failure the channel id exists to make diagnosable rather than to
    // cause. (Entering the channel takes the other path, `close()`, which
    // deliberately keeps it: the session runs on it.)
    _membership.leave();
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

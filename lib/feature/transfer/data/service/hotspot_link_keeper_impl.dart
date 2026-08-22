import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/hotspot_control.dart';
import '../../domain/service/hotspot_link_keeper.dart';
import '../../domain/service/session_role_store.dart';

@LazySingleton(as: HotspotLinkKeeper)
class HotspotLinkKeeperImpl implements HotspotLinkKeeper {
  final HotspotHost _hotspot;
  final HotspotJoiner _joiner;
  final SessionRoleStore _roleStore;
  final WifiTransferRepository _wifi;

  HotspotLinkKeeperImpl(
    this._hotspot,
    this._joiner,
    this._roleStore,
    this._wifi, {
    this.recoveryTimeout = const Duration(minutes: 10),
    this.backoffFactory = ExponentialBackoff.new,
  });

  /// How long a joiner keeps rejoining before giving up and reporting
  /// [HotspotLinkState.lost].
  ///
  /// A permanent separation — a rider peeling off for the day, not a truck
  /// passing overhead — looks identical to this loop for the first several
  /// attempts: every result is the same "didn't join". Ten minutes is long
  /// enough that a real gap (a tunnel, a phone left locked in a bag) has
  /// almost always closed by then, and short enough that a genuine goodbye
  /// stops draining the radio and silently retrying forever.
  final Duration recoveryTimeout;

  /// Builds the backoff schedule for one recovery cycle. A factory rather
  /// than a shared instance because each `_recoverJoin` run needs its own,
  /// starting fresh from [ExponentialBackoff.initial] — and injectable so
  /// tests can run the whole timeout on a millisecond schedule instead of
  /// waiting out real minutes.
  final ExponentialBackoff Function() backoffFactory;

  HotspotCredentials? _credentials;

  /// When the current (or most recent) `_recoverJoin` run started, so the
  /// loop can measure how long it has been trying against [recoveryTimeout].
  DateTime? _recoveryStartedAt;
  StreamSubscription<void>? _lostSub;
  StreamSubscription<void>? _stoppedSub;
  StreamSubscription<void>? _reboundSub;

  /// Guards against a second recovery starting while one is in flight, and is
  /// the flag [release] flips to make an in-flight one give up — a join
  /// attempt can sit for the framework's full timeout, long enough for the
  /// user to have left the channel meanwhile.
  bool _recovering = false;

  final _states = StreamController<HotspotLinkState>.broadcast();
  HotspotLinkState _state = HotspotLinkState.idle;

  @override
  Stream<HotspotLinkState> get states => _states.stream;

  @override
  HotspotLinkState get state => _state;

  @override
  void adopt(HotspotCredentials credentials) {
    _credentials = credentials;
    _watch();
    _emit(HotspotLinkState.up);
    Logger.diagnostic(
      'link: keeping ${credentials.ssid} as ${_roleStore.role?.name ?? "peer"}',
    );
  }

  /// Watches the side this device is actually playing. A host never gets an
  /// `onLost` (it is not on anyone's network) and a joiner never gets an
  /// `onStopped` (it owns no AP), so listening to the wrong one is silence.
  void _watch() {
    _lostSub?.cancel();
    _lostSub = null;
    _stoppedSub?.cancel();
    _stoppedSub = null;
    _reboundSub?.cancel();
    _reboundSub = null;
    switch (_roleStore.role) {
      case SessionRole.joiner:
        _lostSub = _joiner.onLost.listen(
          (_) => unawaited(_recoverJoin()),
          onError: (Object e) => Logger.log('Link keeper lost-listen: $e'),
        );
        _reboundSub = _joiner.onRebound.listen(
          (_) => _onRebound(),
          onError: (Object e) => Logger.log('Link keeper rebound-listen: $e'),
        );
      case SessionRole.host:
        _stoppedSub = _hotspot.onStopped.listen(
          (_) => unawaited(_recoverHost()),
          onError: (Object e) => Logger.log('Link keeper stop-listen: $e'),
        );
      case SessionRole.peer || SessionRole.unknown || null:
        // Nobody is holding a link up, so there is nothing to keep.
        break;
    }
  }

  /// The OS took the link away and gave it back before we had to do anything —
  /// a screen-off cycle, where an app-scoped connection is released and a
  /// system-owned one replaces it (see WifiJoinHandler).
  ///
  /// Nothing needs rejoining, and any rejoin already in flight must stop: it
  /// would drop a link that is now fine and ask the framework for a fresh one,
  /// which off the foreground it cannot grant. What DOES need doing is the
  /// sockets — the process is pinned to a new network handle, and the ones
  /// built on the old handle are sending into a route that is gone.
  void _onRebound() {
    if (_credentials == null) return;
    _recovering = false;
    Logger.diagnostic('link: OS moved us back onto the AP — rebinding sockets');
    _wifi.rebindSockets();
    _emit(HotspotLinkState.up);
  }

  /// Climbs back onto the host's AP. The credentials have not changed — the
  /// AP is still up, this phone was simply moved off it — so the same join
  /// that worked the first time works again, and the OS remembers the user
  /// already approved this network so it goes through without a prompt.
  Future<void> _recoverJoin() async {
    if (_recovering) return;
    final creds = _credentials;
    if (creds == null) return;

    _recovering = true;
    _recoveryStartedAt = DateTime.now();
    _emit(HotspotLinkState.recovering);
    Logger.diagnostic('link: dropped off ${creds.ssid} — rejoining');

    final backoff = backoffFactory();
    while (_recovering) {
      final result = await _joiner.join(creds);
      // release() while the join was in flight: the session is over and this
      // must not put the phone back on a network nobody is using.
      if (!_recovering) return;
      if (result == HotspotJoinResult.joined) {
        _recovering = false;
        Logger.diagnostic('link: back on ${creds.ssid}');
        // We are on a new network handle, so both sockets have to be rebuilt.
        // Note what this is NOT: stopConnection() would look right and be
        // badly wrong — it advances the repository's generation, which ends
        // the listening stream the live session is subscribed to, permanently.
        // rebindSockets() rebuilds underneath that same stream.
        _wifi.rebindSockets();
        _emit(HotspotLinkState.up);
        return;
      }
      // Every attempt so far has looked identical to a truck passing
      // overhead. Past the timeout it no longer does — the same "didn't
      // join" result, this many times, is what a permanent separation
      // looks like from here — so the diagnosis changes rather than the
      // wording: give up and ask the human, same as a re-host under a name
      // the peer cannot guess (see [_recoverHost]).
      final startedAt = _recoveryStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) > recoveryTimeout) {
        _recovering = false;
        Logger.diagnostic(
          'link: gave up rejoining ${creds.ssid} after '
          '${recoveryTimeout.inMinutes}m — peer likely out of range',
        );
        _emit(HotspotLinkState.lost);
        return;
      }
      final delay = backoff.next();
      Logger.diagnostic(
        'link: rejoin failed (${result.name}) — retrying in ${delay.inSeconds}s',
      );
      await Future<void>.delayed(delay);
    }
  }

  /// Brings the AP back after the OS tore it down.
  ///
  /// Only half a recovery, and deliberately so: `startLocalOnlyHotspot` hands
  /// out a fresh random SSID every time and gives no way to ask for the old
  /// one, so the peer is left looking for a network name that no longer
  /// exists. Re-hosting at least puts this phone back in a state where a
  /// rescan can succeed; [HotspotLinkState.lost] says the peer's end needs a
  /// human.
  Future<void> _recoverHost() async {
    if (_recovering) return;
    _recovering = true;
    _emit(HotspotLinkState.recovering);
    Logger.diagnostic('link: AP torn down mid-session — re-hosting');
    try {
      final fresh = await _hotspot.start();
      _credentials = fresh;
      _recovering = false;
      // Up for us, but under a new name the peer cannot guess.
      _emit(HotspotLinkState.lost);
      Logger.diagnostic(
        'link: re-hosted as ${fresh.ssid} — peer must rescan to find it',
      );
    } catch (e) {
      _recovering = false;
      _emit(HotspotLinkState.lost);
      Logger.diagnostic('link: re-host failed: $e');
    }
  }

  @override
  Future<void> release() async {
    _recovering = false;
    _credentials = null;
    _recoveryStartedAt = null;
    await _lostSub?.cancel();
    _lostSub = null;
    await _stoppedSub?.cancel();
    _stoppedSub = null;
    await _reboundSub?.cancel();
    _reboundSub = null;
    _emit(HotspotLinkState.idle);
  }

  @override
  void retryNow() {
    // A host's "lost" means the AP came back under a name the peer cannot
    // guess — see [_recoverHost]. Resending the same join there would fix
    // nothing, so only the joiner side, and only once recovery has actually
    // given up, restarts anything.
    if (_state != HotspotLinkState.lost) return;
    if (_roleStore.role != SessionRole.joiner) return;
    if (_credentials == null) return;
    unawaited(_recoverJoin());
  }

  void _emit(HotspotLinkState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @disposeMethod
  @override
  void dispose() {
    _lostSub?.cancel();
    _stoppedSub?.cancel();
    _reboundSub?.cancel();
    _states.close();
  }
}

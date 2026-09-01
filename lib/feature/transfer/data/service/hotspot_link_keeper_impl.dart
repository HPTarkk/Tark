import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/host_hotspot_recovery.dart';
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
    // All three are test seams with production defaults, and every one of them
    // has to say so: injectable injects any named parameter whose type it can
    // name, so an un-ignored `Duration` becomes `gh<Duration>()` — a lookup
    // nothing registers — and a bare function type it cannot name at all makes
    // it abandon the file, taking this class's registration with it. That
    // second failure is how a stale di_config.config.dart shipped with
    // RoomRepository missing from it: the build errored, and an errored build
    // leaves the generated config exactly as it was.
    @ignoreParam this.recoveryTimeout = const Duration(minutes: 10),
    @ignoreParam this.hostEvidenceInterval = const Duration(milliseconds: 500),
    @ignoreParam this.backoffFactory = ExponentialBackoff.new,
  });

  /// How long either side keeps automatic recovery alive before surfacing a
  /// user-visible lost state. It bounds both retry work and host peer waiting.
  final Duration recoveryTimeout;

  /// Poll cadence while a newly re-hosted AP waits for bidirectional peer
  /// evidence. TransportStats is session-cumulative and cheap to sample.
  final Duration hostEvidenceInterval;

  /// Each recovery cycle gets a fresh bounded exponential backoff.
  final ExponentialBackoff Function() backoffFactory;

  HotspotCredentials? _credentials;
  int _credentialRevision = 0;
  int _expectedHostPeers = 0;
  bool _hostApAvailable = false;
  HostHotspotRecoveryMachine _hostRecovery = HostHotspotRecoveryMachine();

  @override
  HotspotCredentials? get credentials => _credentials;

  final _credentialChanges = StreamController<HotspotCredentials>.broadcast();

  @override
  Stream<HotspotCredentials> get credentialChanges => _credentialChanges.stream;

  /// When the current recovery run started, shared by the bounded join and host
  /// evidence loops.
  DateTime? _recoveryStartedAt;
  StreamSubscription<void>? _lostSub;
  StreamSubscription<void>? _stoppedSub;
  StreamSubscription<void>? _reboundSub;
  Timer? _hostEvidenceTimer;

  /// Guards against duplicate native callbacks starting concurrent recovery.
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
    _credentialRevision++;
    _hostRecovery = HostHotspotRecoveryMachine();
    _hostApAvailable = _roleStore.role == SessionRole.host;
    _watch();
    _emit(HotspotLinkState.up);
    Logger.diagnostic(
      'link: adopted hotspot attachment as '
      '${_roleStore.role?.name ?? "peer"} credentialRevision=$_credentialRevision',
    );
  }

  /// Watches only the temporary network role this device currently owns.
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
        break;
    }
  }

  /// The OS moved a joiner back onto the same AP. Rebuild transport sockets
  /// underneath the still-live logical session; do not leave/rejoin the Room.
  void _onRebound() {
    if (_credentials == null) return;
    _recovering = false;
    Logger.diagnostic('link: OS rebound hotspot attachment; rebinding sockets');
    _wifi.rebindSockets();
    _emit(HotspotLinkState.up);
  }

  Future<void> _recoverJoin() async {
    if (_recovering) return;
    final creds = _credentials;
    if (creds == null) return;

    _recovering = true;
    _recoveryStartedAt = DateTime.now();
    _emit(HotspotLinkState.recovering);
    Logger.diagnostic('link: joiner attachment lost; bounded rejoin started');

    final backoff = backoffFactory();
    while (_recovering) {
      final result = await _joiner.join(creds);
      if (!_recovering) return;
      if (result == HotspotJoinResult.joined) {
        _recovering = false;
        Logger.diagnostic(
          'link: joiner attachment restored; rebinding sockets',
        );
        _wifi.rebindSockets();
        _emit(HotspotLinkState.up);
        return;
      }
      final startedAt = _recoveryStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) > recoveryTimeout) {
        _recovering = false;
        Logger.diagnostic('link: join recovery timeout; user action required');
        _emit(HotspotLinkState.lost);
        return;
      }
      final delay = backoff.next();
      Logger.diagnostic(
        'link: rejoin failed reason=${result.name}; '
        'retryInMs=${delay.inMilliseconds}',
      );
      await Future<void>.delayed(delay);
    }
  }

  /// Re-creates a LocalOnlyHotspot without pretending that re-host success is
  /// equivalent to a restored group. Android mints fresh credentials, which
  /// are published atomically through [credentialChanges] for #39's in-room
  /// invite/rejoin surface. The state remains recovering until every peer that
  /// was present before loss is again both heard and ping-confirmed.
  Future<void> _recoverHost() async {
    if (_recovering) return;

    _hostEvidenceTimer?.cancel();
    _hostEvidenceTimer = null;
    _hostApAvailable = false;
    _expectedHostPeers = _wifi.stats.peerCount;
    _recovering = true;
    _recoveryStartedAt = DateTime.now();
    _hostRecovery = HostHotspotRecoveryMachine();
    _hostRecovery.hotspotLost(
      generation: 0,
      membersExpected: _expectedHostPeers,
    );
    _emit(HotspotLinkState.recovering);
    Logger.diagnostic(
      'link: host hotspot lost; expectedPeers=$_expectedHostPeers bounded rehost started',
    );

    final backoff = backoffFactory();
    while (_recovering) {
      final rehosting = _hostRecovery.beginRehost();
      if (rehosting.phase == HostHotspotRecoveryPhase.failed) {
        _recovering = false;
        _emit(HotspotLinkState.lost);
        return;
      }

      try {
        final fresh = await _hotspot.start();
        if (!_recovering) return;

        _credentialRevision++;
        final changed = _hostRecovery.rehosted(
          generation: rehosting.generation,
          credentialRevision: _credentialRevision,
        );
        if (changed.phase == HostHotspotRecoveryPhase.failed) {
          _recovering = false;
          _emit(HotspotLinkState.lost);
          return;
        }

        _credentials = fresh;
        _hostApAvailable = true;
        if (!_credentialChanges.isClosed) _credentialChanges.add(fresh);
        Logger.diagnostic(
          'link: host rehosted generation=${rehosting.generation} '
          'credentialRevision=$_credentialRevision; publishing fresh invite attachment',
        );

        // Both directions were built on the old Android Network. Rebuild them
        // while preserving the repository/listening session generation.
        _wifi.rebindSockets();

        final published = _hostRecovery.credentialsPublished(
          generation: rehosting.generation,
        );
        if (published.isLive) {
          _recovering = false;
          _emit(HotspotLinkState.up);
          return;
        }

        _startHostEvidenceWatch(rehosting.generation);
        return;
      } catch (error) {
        final failed = _hostRecovery.rehostFailed(
          generation: rehosting.generation,
          reason: 'rehost_failed',
        );
        Logger.diagnostic(
          'link: host rehost attempt=${rehosting.attempt} failed '
          'reason=${error.runtimeType}',
        );
        if (failed.phase == HostHotspotRecoveryPhase.failed) {
          _recovering = false;
          _emit(HotspotLinkState.lost);
          return;
        }
        final delay = backoff.next();
        await Future<void>.delayed(delay);
      }
    }
  }

  void _startHostEvidenceWatch(int generation) {
    _hostEvidenceTimer?.cancel();
    _hostEvidenceTimer = Timer.periodic(hostEvidenceInterval, (_) {
      if (!_recovering || _roleStore.role != SessionRole.host) {
        _hostEvidenceTimer?.cancel();
        _hostEvidenceTimer = null;
        return;
      }

      final startedAt = _recoveryStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) > recoveryTimeout) {
        _hostEvidenceTimer?.cancel();
        _hostEvidenceTimer = null;
        _recovering = false;
        Logger.diagnostic(
          'link: host peers did not restore before timeout; user action required',
        );
        _emit(HotspotLinkState.lost);
        return;
      }

      final stats = _wifi.stats;
      final bidirectional =
          stats.peerCount >= _expectedHostPeers &&
          !stats.sendFailing &&
          !stats.unicastUnconfirmed &&
          (_expectedHostPeers == 0 || stats.rtt != null);
      if (!bidirectional) return;

      final restored = _hostRecovery.peerEvidence(
        generation: generation,
        bidirectionallyReachable: _expectedHostPeers,
      );
      if (!restored.isLive) return;

      _hostEvidenceTimer?.cancel();
      _hostEvidenceTimer = null;
      _recovering = false;
      Logger.diagnostic(
        'link: host recovery restored by bidirectional peer evidence '
        'generation=$generation peers=$_expectedHostPeers',
      );
      _emit(HotspotLinkState.up);
    });
  }

  @override
  Future<void> release() async {
    _recovering = false;
    _hostEvidenceTimer?.cancel();
    _hostEvidenceTimer = null;
    _hostRecovery.cancel();
    _credentials = null;
    _recoveryStartedAt = null;
    _expectedHostPeers = 0;
    _hostApAvailable = false;
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
    if (_state != HotspotLinkState.lost || _credentials == null) return;

    switch (_roleStore.role) {
      case SessionRole.joiner:
        unawaited(_recoverJoin());
      case SessionRole.host:
        if (_hostApAvailable) {
          _recovering = true;
          _recoveryStartedAt = DateTime.now();
          _emit(HotspotLinkState.recovering);
          final creds = _credentials;
          if (creds != null && !_credentialChanges.isClosed) {
            _credentialChanges.add(creds);
          }
          _wifi.rebindSockets();
          _startHostEvidenceWatch(_hostRecovery.state.generation);
        } else {
          unawaited(_recoverHost());
        }
      case SessionRole.peer || SessionRole.unknown || null:
        break;
    }
  }

  void _emit(HotspotLinkState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @disposeMethod
  @override
  void dispose() {
    _recovering = false;
    _hostEvidenceTimer?.cancel();
    _lostSub?.cancel();
    _stoppedSub?.cancel();
    _reboundSub?.cancel();
    _states.close();
    _credentialChanges.close();
  }
}

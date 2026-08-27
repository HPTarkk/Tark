import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:injectable/injectable.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/identity/channel_membership.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../../core/identity/session_epoch.dart';
import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/lan_ipv4.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/audio_profile.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/control_packet.dart';
import '../../domain/entity/opus_tuning.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/transport_capability_observation.dart';
import '../../domain/entity/transport_stats.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/transport_capability_observation_source.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/audio_capability_negotiator.dart';
import '../../domain/service/host_subnet_filter.dart';
import '../../domain/service/media_opus_tuner.dart';
import '../../domain/service/media_quality_controller.dart';
import '../../domain/service/recovery_ladder.dart';
import '../../domain/service/opus_tuner.dart';
import '../../domain/service/peer_loss_tracker.dart';
import '../../domain/service/peer_ping_tracker.dart';
import '../../domain/service/channel_gate.dart';
import '../../domain/service/sender_route_pin.dart';
import '../../domain/service/session_epoch_gate.dart';
import '../../domain/service/session_role_store.dart';
import '../../domain/service/transport_drop_counters.dart';
import '../../domain/service/voice_quality_controller.dart';
import '../codec/opus_audio_codec.dart';
import '../codec/transport_capability_control_codec.dart';
import '../codec/transport_capability_heartbeat_runtime.dart';
import '../codec/waki_packet_codec.dart';
import '../hotspot/wifi_client_address.dart';
import 'broadcast_policy.dart';
import 'discovery_sweep.dart';

const kBroadcastPort = 4000;

@LazySingleton(as: WifiTransferRepository)
class WifiTransferRepositoryImpl
    implements WifiTransferRepository, TransportCapabilityObservationSource {
  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _receiveSocket;
  final _connectionController = StreamController<ConnectionHealth>.broadcast();

  bool _autoReconnectEnabled = true;
  Completer<void>? _manualRetryCompleter;

  Timer? _livenessTimer;
  DateTime _lastPacketAt = DateTime.now();
  static const _livenessCheckInterval = Duration(seconds: 5);
  static const _livenessTimeout = Duration(seconds: 15);
  DateTime? _lastPeerAt;
  static const _watchdogGrace = Duration(minutes: 2);
  bool _rebindRequested = false;

  List<InternetAddress> _broadcastTargets = const [];
  DateTime _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _targetsMaxAge = Duration(seconds: 10);
  List<String> _sweepSubnets = const [];
  Set<String> _localAddresses = const {};
  final Map<String, DateTime> _peers = {};
  static const _peerMaxAge = Duration(seconds: 10);
  final Map<String, DateTime> _recoveryPeers = {};
  static const _peerRecoveryWindow = _watchdogGrace;
  final DiscoverySweep _sweep = DiscoverySweep();
  final Set<String> _failingTargets = {};
  final Map<String, DateTime> _heardSenders = {};
  static const _heardSenderMaxAge = Duration(seconds: 8);
  DateTime? _sendFailingSince;
  static const _sendFailureGrace = Duration(seconds: 2);
  DateTime _lastSendRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _sendRebuildInterval = Duration(seconds: 5);
  int _packetsIn = 0;
  int _packetsOut = 0;
  int _mediaPacketsIn = 0;
  int _mediaPacketsOut = 0;
  int _mediaSuspendedDrops = 0;
  final Set<String> _heardSubnets = {};
  List<InternetAddress> _heardSubnetBroadcasts = const [];
  final Set<String> _seenSenderRoutes = {};
  final Map<String, Map<String, _RouteStats>> _senderRoutes = {};
  static const _routeMaxAge = Duration(seconds: 12);
  DateTime _lastSplitRouteLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _splitRouteLogInterval = Duration(seconds: 15);
  int _sendErrorWindow = 0;
  final _drops = TransportDropCounters();

  @override
  TransportStats get stats => TransportStats(
    sendFailing: _sendFailingSince != null,
    unicastUnconfirmed: _unicastUnconfirmed,
    rtt: _lastRtt,
    staleEpochDrops: _drops.staleEpochTotal,
    duplicateRouteDrops: _drops.duplicateRouteTotal,
    blockedSends: _drops.blockedTotal,
    peerCount: _peers.length,
  );

  late final _codec = WakiPacketCodec(_identity.id, _epoch, _membership);
  late final _transportCapabilityHeartbeat = TransportCapabilityHeartbeatRuntime(
    codec: TransportCapabilityControlCodec(_codec),
  );

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      _transportCapabilityHeartbeat.transportCapabilityObservations;

  final SessionEpochGate _epochGate = SessionEpochGate();
  final AudioCapabilityNegotiator _capabilities = AudioCapabilityNegotiator();
  final VoiceQualityController _quality = VoiceQualityController();
  DateTime? _lastQualityAdvanceAt;
  AudioFormatProfile _negotiatedFormat = AudioFormatProfile.legacy16k;

  @override
  AudioFormatProfile get negotiatedFormat => _negotiatedFormat;

  void _syncFormatProfile() {
    final now = DateTime.now();
    final elapsedMs = _lastQualityAdvanceAt == null
        ? 0
        : now.difference(_lastQualityAdvanceAt!).inMilliseconds;
    _lastQualityAdvanceAt = now;
    final transition = _quality.advance(
      conditions: AudioLinkConditions(
        lossFraction: _loss.worstLossFraction,
        rtt: _lastRtt,
      ),
      ceiling: _capabilities.resolve(),
      elapsedMs: elapsedMs,
    );
    if (transition == null) return;
    _negotiatedFormat = transition.to;
    _codec.setFormatProfile(transition.to);
    Logger.diagnostic(
      'wifi: negotiated audio profile ${transition.from.label} -> '
      '${transition.to.label} | reason=${transition.reason} '
      '${_opusSummary()} rtt=${_lastRtt?.inMilliseconds ?? '?'}ms',
    );
  }

  final AudioCapabilityNegotiator _mediaCapabilities =
      AudioCapabilityNegotiator.media();
  AudioFormatProfile? _negotiatedMediaFormat;

  @override
  AudioFormatProfile? get negotiatedMediaFormat => _negotiatedMediaFormat;

  void _syncMediaFormatProfile() {
    final resolved = _mediaCapabilities.resolveOptional();
    if (resolved == _negotiatedMediaFormat) return;
    final previous = _negotiatedMediaFormat;
    _negotiatedMediaFormat = resolved;
    if (resolved != null) _codec.setMediaFormatProfile(resolved);
    Logger.diagnostic(
      'wifi: negotiated media profile ${previous?.label ?? 'none'} -> '
      '${resolved?.label ?? 'none'}',
    );
  }

  final MediaQualityController _mediaQuality = MediaQualityController();
  DateTime? _lastMediaQualityAdvanceAt;

  void _syncMediaQuality() {
    final now = DateTime.now();
    final elapsedMs = _lastMediaQualityAdvanceAt == null
        ? 0
        : now.difference(_lastMediaQualityAdvanceAt!).inMilliseconds;
    _lastMediaQualityAdvanceAt = now;
    final transition = _mediaQuality.advance(
      conditions: AudioLinkConditions(
        lossFraction: _loss.worstLossFraction,
        rtt: _lastRtt,
      ),
      elapsedMs: elapsedMs,
    );
    if (transition == null) return;
    Logger.diagnostic(
      'wifi: media transmission ${transition.from.name} -> '
      '${transition.to.name} | reason=${transition.reason} '
      '${_mediaOpusSummary()} rtt=${_lastRtt?.inMilliseconds ?? '?'}ms',
    );
  }

  OpusTuning? _mediaTuning;

  void _updateMediaTuning() {
    final profile = _negotiatedMediaFormat;
    if (profile == null) {
      _mediaTuning = null;
      return;
    }
    final tuning = MediaOpusTuner.forProfile(profile).tune(
      AudioLinkConditions(lossFraction: _loss.worstLossFraction, rtt: _lastRtt),
    );
    _mediaTuning = tuning;
    _codec.applyMediaTuning(tuning);
  }

  String _mediaOpusSummary() {
    final format = _negotiatedMediaFormat;
    final tuning = _mediaTuning;
    if (format == null || tuning == null) return 'media=none';
    return 'media=${format.label}/${tuning.bitrate ~/ 1000}kbps/'
        'fec${_codec.hasMediaFec ? 'on' : 'off'}/'
        '${_mediaQuality.shouldSend ? 'active' : 'SUSPENDED'}';
  }

  int _otherChannelWindow = 0;
  final Set<int> _otherChannelsHeard = {};
  int _generation = 0;
  int _audioSeq = 0;
  int _mediaSeq = 0;

  final DeviceIdentity _identity;
  final SessionEpoch _epoch;
  final SessionRoleStore _roleStore;
  final ChannelMembership _membership;

  WifiTransferRepositoryImpl(
    this._identity,
    this._epoch,
    this._roleStore,
    this._membership,
  );

  @override
  SessionRole get sessionRole => _roleStore.role ?? SessionRole.peer;

  @disposeMethod
  @override
  void dispose() {
    _generation++;
    _livenessTimer?.cancel();
    _pingTimer?.cancel();
    _sendSocket?.close();
    _sendSocket = null;
    _receiveSocket?.close();
    _receiveSocket = null;
    _connectionController.close();
    unawaited(_transportCapabilityHeartbeat.dispose());
    _codec.release();
  }

  @override
  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  ) async {
    try {
      await _ensureSendSocket();
      final packet = _codec.encodeAudio(samples, senderName, _audioSeq++);
      _sendToAllTargets(packet, isAudio: true);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendMedia(
    List<double> samples,
    String senderName,
  ) async {
    if (!_mediaQuality.shouldSend) {
      _mediaSuspendedDrops++;
      return const Right(null);
    }
    try {
      await _ensureSendSocket();
      final packet = _codec.encodeMediaAudio(samples, senderName, _mediaSeq++);
      _sendToAllTargets(packet, isAudio: true);
      _mediaPacketsOut++;
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) {
    if (_sendSocket != null &&
        _broadcastTargets.isNotEmpty &&
        DateTime.now().difference(_targetsResolvedAt) <= _targetsMaxAge) {
      return Future.value(
        _sendPresenceNow(senderName, isTalking, isLeaving: isLeaving),
      );
    }
    return _sendPresenceAfterEnsuringSocket(
      senderName,
      isTalking,
      isLeaving: isLeaving,
    );
  }

  Future<Either<Failure, void>> _sendPresenceAfterEnsuringSocket(
    String senderName,
    bool isTalking, {
    required bool isLeaving,
  }) async {
    try {
      await _ensureSendSocket();
      return _sendPresenceNow(senderName, isTalking, isLeaving: isLeaving);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  Either<Failure, void> _sendPresenceNow(
    String senderName,
    bool isTalking, {
    required bool isLeaving,
  }) {
    try {
      final packet = _codec.encodePresence(
        senderName,
        isTalking,
        role: sessionRole,
        heardIds: _currentlyHeardSenders(),
        isLeaving: isLeaving,
      );
      _sendToAllTargets(packet, isAudio: false);
      _sweepIfUndiscovered(packet);
      _logSessionState();
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Stream<WakiPacket> startListening() async* {
    final myGen = ++_generation;
    final epoch = _epoch.renew();
    Logger.diagnostic('wifi: session epoch $epoch (gen $myGen)');
    final backoff = ExponentialBackoff();

    while (_generation == myGen) {
      try {
        _receiveSocket?.close();
        _receiveSocket = null;
        _sendSocket?.close();
        _sendSocket = null;
        _sendFailingSince = null;
        if (_ladder.shouldRenegotiate) _renegotiate();
        await _resolveNetwork();
        _targetsResolvedAt = DateTime.now();
        _receiveSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          kBroadcastPort,
        );
        _receiveSocket!.broadcastEnabled = true;
        _seenSenderRoutes.clear();
        _failingTargets.clear();
        _setHealth(const ConnectionHealth.healthy());
        _lastPacketAt = DateTime.now();
        _rebindRequested = false;
        _startLivenessWatch(myGen);
        _startPingLoop(myGen);
        Logger.diagnostic(
          'wifi: UDP bound on $kBroadcastPort (gen $myGen), '
          'local $_localAddresses, broadcasting to '
          '${_broadcastTargets.map((a) => a.address).toList()}',
        );

        await for (final event in _receiveSocket!) {
          if (_generation != myGen) break;
          if (event == RawSocketEvent.read) {
            Datagram? dg;
            while ((dg = _receiveSocket?.receive()) != null) {
              if (_localAddresses.contains(dg!.address.address)) continue;
              backoff.reset();
              _ladder.reset();
              _lastPacketAt = DateTime.now();

              if (WakiPacketCodec.isControl(dg.data[0])) {
                final control = _transportCapabilityHeartbeat.decodeControl(
                  dg.data,
                  dg.address.address,
                );
                if (control != null) {
                  _rememberPeer(dg.address.address);
                  await _handleControl(control, dg.address.address, myGen);
                }
                continue;
              }

              final packet = _codec.decode(dg.data, dg.address.address);
              if (packet != null) {
                _packetsIn++;
                if (!_acceptChannel(packet)) continue;
                if (!_acceptEpoch(packet)) continue;
                _noteSenderRoute(dg.address.address, packet.senderId);
                if (!_acceptRoute(packet.senderId, dg.address.address)) {
                  continue;
                }
                _rememberPeer(dg.address.address);
                _rememberHeardSubnet(dg.address.address);
                _heardSenders[packet.senderId] = _lastPacketAt;
                _senderAtAddress[dg.address.address] = packet.senderId;
                if (packet is AudioPacket) {
                  (_rxBySender[packet.senderId] ??= _PeerAudioStats()).record(
                    packet.seq,
                  );
                } else if (packet is MediaAudioPacket) {
                  _mediaPacketsIn++;
                } else if (packet is PresencePacket) {
                  _capabilities.observePeer(
                    packet.senderId,
                    packet.capabilityBitmask,
                  );
                  _syncFormatProfile();
                  _mediaCapabilities.observePeer(
                    packet.senderId,
                    packet.capabilityBitmask,
                  );
                  _syncMediaFormatProfile();
                  _syncMediaQuality();
                }
                yield packet;
              }
            }
          } else if (event == RawSocketEvent.closed) {
            break;
          }
        }

        _livenessTimer?.cancel();
        if (!_autoReconnectEnabled) _setHealth(const ConnectionHealth.down());
      } catch (error) {
        Logger.log('Socket error (gen $myGen): $error');
        _livenessTimer?.cancel();
        if (!_autoReconnectEnabled) _setHealth(const ConnectionHealth.down());
        _receiveSocket?.close();
        _receiveSocket = null;
      }

      if (_generation != myGen) break;
      if (_rebindRequested) {
        _rebindRequested = false;
        backoff.reset();
        _ladder.reset();
        _setHealth(const ConnectionHealth.reconnecting());
        continue;
      }

      if (_autoReconnectEnabled) {
        final delay = backoff.next();
        _ladder.escalate();
        _setHealth(_ladder.rung(delay));
        final completer = Completer<void>();
        _manualRetryCompleter = completer;
        final slices = delay.inMilliseconds ~/ 250;
        for (
          var i = 0;
          i < slices && _generation == myGen && !completer.isCompleted;
          i++
        ) {
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 250)),
            completer.future,
          ]);
        }
        _manualRetryCompleter = null;
        if (_generation == myGen) _setHealth(_ladder.rung(null));
      } else {
        final completer = Completer<void>();
        _manualRetryCompleter = completer;
        await completer.future;
        _manualRetryCompleter = null;
      }
    }
  }

  void _logSessionState() {
    final now = DateTime.now();
    _logSplitRoutes(now);
    if (now.difference(_lastSessionLogAt) < _sessionLogInterval) return;
    final window = now.difference(_lastSessionLogAt);
    _lastSessionLogAt = now;
    final silentFor = now.difference(_lastPacketAt).inSeconds;
    final inDelta = _packetsIn - _lastPacketsIn;
    final outDelta = _packetsOut - _lastPacketsOut;
    _lastPacketsIn = _packetsIn;
    _lastPacketsOut = _packetsOut;
    final mediaInDelta = _mediaPacketsIn - _lastMediaPacketsIn;
    final mediaOutDelta = _mediaPacketsOut - _lastMediaPacketsOut;
    _lastMediaPacketsIn = _mediaPacketsIn;
    _lastMediaPacketsOut = _mediaPacketsOut;
    final mediaSuspendedDelta = _mediaSuspendedDrops - _lastMediaSuspendedDrops;
    _lastMediaSuspendedDrops = _mediaSuspendedDrops;
    final dropWindow = _drops.takeWindow();
    final blocked = dropWindow.blocked;
    final errored = _sendErrorWindow;
    final dupRoute = dropWindow.duplicateRoute;
    final staleEpoch = dropWindow.staleEpoch;
    final otherChannels = _otherChannelWindow;
    final otherChannelCount = _otherChannelsHeard.length;
    _sendErrorWindow = 0;
    _otherChannelWindow = 0;
    _otherChannelsHeard.clear();
    Logger.diagnostic(
      'wifi: in=$_packetsIn(+$inDelta) out=$_packetsOut(+$outDelta) '
      'mediaIn=$_mediaPacketsIn(+$mediaInDelta) '
      'mediaOut=$_mediaPacketsOut(+$mediaOutDelta) '
      'mediaSuspended=$_mediaSuspendedDrops(+$mediaSuspendedDelta) '
      'over ${window.inSeconds}s '
      'peers=${_peers.keys.toList()} recovery=${_recoveryPeers.length} '
      'heard=${_heardSenders.keys.toList()} '
      'routes=${_routeSummary()} pinned=${_routePin.pinnedAddresses} '
      'dupRoute=$dupRoute staleEpoch=$staleEpoch epoch=${_epoch.value} '
      'channel=${_membership.current.code ?? 'open'} '
      '${otherChannels == 0 ? '' : 'otherChannels=$otherChannelCount($otherChannels pkts) '}'
      'rtt=${_lastRtt?.inMilliseconds ?? '?'}ms '
      'txLoss=${_lossSummary()} opus=${_opusSummary()} ${_mediaOpusSummary()} '
      '${_unicastUnconfirmed ? 'UNICAST-UNCONFIRMED ' : ''}'
      'local=$_localAddresses '
      'bcast=${_broadcastTargets.map((a) => a.address).toList()}'
      '${_heardSubnetBroadcasts.isEmpty ? '' : '+${_heardSubnetBroadcasts.map((a) => a.address).toList()}'} '
      'sendSocket=${_sendSocket == null ? 'none' : 'up'} '
      'rxSocket=${_receiveSocket == null ? 'none' : 'up'} '
      'blocked=$blocked errs=$errored '
      'quietFor=${silentFor}s'
      '${_sendFailingSince == null ? '' : ' SEND-FAILING'}',
    );
  }

  String _opusSummary() {
    final tuning = _codec.tuning;
    return '${_negotiatedFormat.label}/${tuning.bitrate ~/ 1000}kbps/'
        'loss${tuning.packetLossPerc}%/fec${_codec.hasFec ? 'on' : 'off'}';
  }

  String _lossSummary() {
    final worstId = _loss.worstPeerId;
    if (worstId == null) return '?';
    final percent = (_loss.worstLossFraction * 100).toStringAsFixed(1);
    return '$percent%@$worstId';
  }

  String _routeSummary() => _senderRoutes.isEmpty
      ? '{}'
      : '{${_senderRoutes.entries.map((e) => '${e.key}:${e.value.length}').join(', ')}}';

  int _lastPacketsIn = 0;
  int _lastPacketsOut = 0;
  int _lastMediaPacketsIn = 0;
  int _lastMediaPacketsOut = 0;
  int _lastMediaSuspendedDrops = 0;
  DateTime _lastSessionLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _sessionLogInterval = Duration(seconds: 15);
  final RecoveryLadder _ladder = RecoveryLadder();

  void _renegotiate() {
    Logger.diagnostic(
      'wifi: ${_ladder.attempts} rebinds have not restored traffic — '
      'renegotiating (re-resolving addresses, widening discovery)',
    );
    _peers.clear();
    _narrowedTo = const {};
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _broadcastTargets = const [];
    _sweep.retarget(const []);
  }

  void _startLivenessWatch(int myGen) {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(_livenessCheckInterval, (_) {
      if (_generation != myGen) {
        _livenessTimer?.cancel();
        return;
      }
      final lastPeer = _lastPeerAt;
      if (lastPeer == null) return;
      final now = DateTime.now();
      if (now.difference(lastPeer) > _watchdogGrace) return;
      if (now.difference(_lastPacketAt) > _livenessTimeout) {
        Logger.diagnostic(
          'wifi: liveness timeout (gen $myGen) — forcing rebind',
        );
        _receiveSocket?.close();
      }
    });
  }

  @override
  Stream<ConnectionHealth> connect() => _connectionController.stream;

  @override
  void setAutoReconnectEnabled(bool enabled) {
    _autoReconnectEnabled = enabled;
    if (enabled) retryNow();
  }

  @override
  void retryNow() {
    final completer = _manualRetryCompleter;
    _manualRetryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void setAudioProfile(AudioProfile profile) => _codec.setAudioProfile(
    profile == AudioProfile.music
        ? OpusEncodeProfile.music
        : OpusEncodeProfile.voice,
  );

  @override
  void resetCodecState() {
    _codec.resetDecoders();
    _codec.resetMediaDecoders();
  }

  @override
  void repairSendPath() {
    final now = DateTime.now();
    if (now.difference(_lastSendRebuildAt) < _sendRebuildInterval) return;
    _lastSendRebuildAt = now;
    Logger.diagnostic(
      'wifi: a peer we can hear reports it cannot hear us — '
      'rebuilding the send path',
    );
    _sendSocket?.close();
    _sendSocket = null;
    _sendFailingSince = null;
    _broadcastTargets = const [];
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  void rebindSockets() {
    Logger.diagnostic('wifi: rebinding both sockets on the current network');
    _rebindRequested = true;
    _sendSocket?.close();
    _sendSocket = null;
    _broadcastTargets = const [];
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _peers.clear();
    _receiveSocket?.close();
    _receiveSocket = null;
    final completer = _manualRetryCompleter;
    _manualRetryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void stopConnection() {
    _generation++;
    _livenessTimer?.cancel();
    _pingTimer?.cancel();
    _manualRetryCompleter?.complete();
    _manualRetryCompleter = null;
    _rebindRequested = false;
    _lastPeerAt = null;
    _ladder.reset();
    _receiveSocket?.close();
    _receiveSocket = null;
    _sendSocket?.close();
    _sendSocket = null;
    _broadcastTargets = const [];
    _sweepSubnets = const [];
    _localAddresses = const {};
    _peers.clear();
    _recoveryPeers.clear();
    _seenSenderRoutes.clear();
    _heardSubnets.clear();
    _heardSubnetBroadcasts = const [];
    _heardSenders.clear();
    _sendFailingSince = null;
    _packetsIn = 0;
    _packetsOut = 0;
    _lastPacketsIn = 0;
    _lastPacketsOut = 0;
    _senderRoutes.clear();
    _lastSplitRouteLogAt = DateTime.fromMillisecondsSinceEpoch(0);
    _targetLoggedAt.clear();
    _routePin.clear();
    _epochGate.clear();
    _pings.clear();
    _unicastUnconfirmed = false;
    _lastRtt = null;
    _loss.clear();
    _capabilities.clear();
    _quality.reset();
    _lastQualityAdvanceAt = null;
    _negotiatedFormat = AudioFormatProfile.legacy16k;
    _codec.setFormatProfile(AudioFormatProfile.legacy16k);
    _mediaCapabilities.clear();
    _negotiatedMediaFormat = null;
    _mediaTuning = null;
    _mediaQuality.reset();
    _lastMediaQualityAdvanceAt = null;
    _codec.resetMediaDecoders();
    _mediaSeq = 0;
    _mediaPacketsIn = 0;
    _mediaPacketsOut = 0;
    _lastMediaPacketsIn = 0;
    _lastMediaPacketsOut = 0;
    _mediaSuspendedDrops = 0;
    _lastMediaSuspendedDrops = 0;
    _rxBySender.clear();
    _senderAtAddress.clear();
    _narrowedTo = const {};
    _sendErrorWindow = 0;
    _drops.reset();
    _otherChannelWindow = 0;
    _otherChannelsHeard.clear();
    _sweep.retarget(const []);
    _setHealth(const ConnectionHealth.down());
  }

  Future<void> _ensureSendSocket() async {
    final now = DateTime.now();
    if (_broadcastTargets.isEmpty ||
        now.difference(_targetsResolvedAt) > _targetsMaxAge) {
      await _resolveNetwork();
      _targetsResolvedAt = now;
    }
    if (_sendSocket == null) {
      _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sendSocket!.broadcastEnabled = true;
    }
  }

  List<String> _currentlyHeardSenders() {
    final now = DateTime.now();
    _heardSenders.removeWhere(
      (_, seen) => now.difference(seen) > _heardSenderMaxAge,
    );
    return _heardSenders.keys.toList(growable: false);
  }

  void _sendToAllTargets(List<int> packet, {required bool isAudio}) {
    final now = DateTime.now();
    _peers.removeWhere((addr, seen) {
      if (now.difference(seen) <= _peerMaxAge) return false;
      Logger.diagnostic(
        'wifi: peer $addr aged out — still unicasting to it for recovery',
      );
      return true;
    });
    _recoveryPeers.removeWhere((addr, seen) {
      if (now.difference(seen) <= _peerRecoveryWindow) return false;
      Logger.diagnostic(
        'wifi: peer $addr gave up — no longer unicasting to it',
      );
      return true;
    });
    final unicastTargets = _peers.isNotEmpty
        ? _peers.keys
        : _recoveryPeers.keys;
    final unicast = unicastTargets.toList(growable: false);
    if (needsBroadcastLeg(
      isAudio: isAudio,
      hasLivePeers: _peers.isNotEmpty,
      unicastFailing: _sendFailingSince != null,
      unicastUnconfirmed: _unicastUnconfirmed,
    )) {
      for (final target in _broadcastsFor(unicast)) {
        _trySend(packet, target);
      }
    }
    var failed = 0;
    for (final addr in unicast) {
      if (!_trySend(packet, InternetAddress(addr))) failed++;
    }
    _packetsOut++;
    _gradeSendPath(attempted: unicast.length, failed: failed, now: now);
  }

  List<InternetAddress> _broadcastsFor(List<String> peerAddresses) {
    if (peerAddresses.isEmpty) return _wideSpray();
    final directed = <String>{};
    for (final addr in peerAddresses) {
      final parts = addr.split('.');
      if (parts.length != 4) continue;
      directed.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
    }
    if (directed.isEmpty) return _wideSpray();
    if (!setEquals(directed, _narrowedTo)) {
      _narrowedTo = directed;
      Logger.diagnostic(
        'wifi: broadcasting only to $directed — the subnet(s) our peers are '
        'actually on; other interfaces are no longer sprayed',
      );
    }
    return directed.map(InternetAddress.new).toList(growable: false);
  }

  List<InternetAddress> _wideSpray() {
    if (_narrowedTo.isNotEmpty) {
      _narrowedTo = const {};
      Logger.diagnostic(
        'wifi: no peers to aim at — broadcasting to every interface again '
        'until one answers',
      );
    }
    return [..._broadcastTargets, ..._heardSubnetBroadcasts];
  }

  Set<String> _narrowedTo = const {};

  void _gradeSendPath({
    required int attempted,
    required int failed,
    required DateTime now,
  }) {
    if (attempted == 0 || failed < attempted) {
      if (_sendFailingSince != null) {
        if (_mayLogTarget('<send-path>', now)) {
          Logger.diagnostic('wifi: send path recovered');
        }
        _sendFailingSince = null;
      }
      return;
    }
    final since = _sendFailingSince ??= now;
    if (now.difference(since) < _sendFailureGrace) return;
    if (now.difference(_lastSendRebuildAt) < _sendRebuildInterval) return;
    _lastSendRebuildAt = now;
    Logger.diagnostic(
      'wifi: every send has failed for ${now.difference(since).inSeconds}s '
      '($attempted targets) — rebuilding the send socket',
    );
    _sendSocket?.close();
    _sendSocket = null;
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _rememberHeardSubnet(String address) {
    if (!LanIpv4.isPrivate(address)) return;
    final parts = address.split('.');
    if (parts.length != 4) return;
    final directed = '${parts[0]}.${parts[1]}.${parts[2]}.255';
    if (!_heardSubnets.add(directed)) return;
    final known = _broadcastTargets.map((a) => a.address).toSet();
    _heardSubnetBroadcasts = _heardSubnets
        .where((a) => !known.contains(a))
        .map(InternetAddress.new)
        .toList();
    _retargetSweep();
    Logger.diagnostic('wifi: also broadcasting to $directed (heard traffic)');
  }

  void _sweepIfUndiscovered(List<int> packet) {
    if (_peers.isNotEmpty) {
      _sweep.reset();
      return;
    }
    for (final addr in _sweep.nextSlice()) {
      _trySend(packet, InternetAddress(addr));
    }
  }

  void _retargetSweep() {
    final heardPrefixes = <String>{};
    for (final directed in _heardSubnets) {
      final parts = directed.split('.');
      if (parts.length != 4) continue;
      heardPrefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
    final heardFirst = <String>[];
    final rest = <String>[];
    for (final prefix in {...heardPrefixes, ..._sweepSubnets}) {
      final bucket = heardPrefixes.contains(prefix) ? heardFirst : rest;
      for (var host = 1; host < 255; host++) {
        final addr = '$prefix.$host';
        if (_localAddresses.contains(addr)) continue;
        bucket.add(addr);
      }
    }
    _sweep.retarget([...heardFirst, ...rest]);
  }

  void _noteSenderRoute(String address, String senderId) {
    final routes = _senderRoutes.putIfAbsent(senderId, () => {});
    (routes[address] ??= _RouteStats()).hit();
    if (!_seenSenderRoutes.add('$senderId@$address')) return;
    Logger.diagnostic('wifi: sender $senderId first heard from $address');
  }

  void _logSplitRoutes(DateTime now) {
    for (final routes in _senderRoutes.values) {
      routes.removeWhere((_, s) => now.difference(s.lastAt) > _routeMaxAge);
    }
    _senderRoutes.removeWhere((_, routes) => routes.isEmpty);
    final split = _senderRoutes.entries.where((e) => e.value.length > 1);
    if (split.isEmpty) return;
    if (now.difference(_lastSplitRouteLogAt) < _splitRouteLogInterval) return;
    _lastSplitRouteLogAt = now;
    for (final entry in split) {
      final routes = entry.value.entries
          .map((r) => '${r.key}(${r.value.packets})')
          .join(' + ');
      Logger.diagnostic(
        'wifi: SPLIT ROUTE — sender ${entry.key} is arriving on '
        '${entry.value.length} paths: $routes. Only the pinned one is used '
        '(pinned=${_routePin.pinnedFor(entry.key) ?? 'none'}); the rest are dropped. '
        'Both devices are probably on two shared networks at once.',
      );
    }
  }

  bool _acceptRoute(String senderId, String address) {
    final verdict = _routePin.offer(senderId, address, DateTime.now());
    switch (verdict.decision) {
      case RouteDecision.pinned:
        Logger.diagnostic('wifi: pinned sender $senderId to $address');
      case RouteDecision.accepted:
        break;
      case RouteDecision.rejected:
        _drops.duplicateRouteDropped();
      case RouteDecision.repinned:
        Logger.diagnostic(
          'wifi: sender $senderId moved from ${verdict.previous} to $address '
          '(old route silent for '
          '${verdict.previousSilence?.inSeconds ?? '?'}s) — repinning',
        );
        _peers.remove(verdict.previous);
        _recoveryPeers.remove(verdict.previous);
    }
    return verdict.isAccepted;
  }

  bool _acceptChannel(WakiPacket packet) {
    final gate = ChannelGate(_membership.current);
    if (gate.admits(packet.channelId)) return true;
    _otherChannelWindow++;
    _otherChannelsHeard.add(packet.channelId.value);
    return false;
  }

  bool _acceptEpoch(WakiPacket packet) {
    if (!packet.hasSessionEpoch) return true;
    final verdict = _epochGate.offer(packet.senderId, packet.sessionEpoch);
    switch (verdict.decision) {
      case EpochDecision.adopted:
        Logger.diagnostic(
          'wifi: sender ${packet.senderId} on epoch ${packet.sessionEpoch}',
        );
      case EpochDecision.accepted:
        break;
      case EpochDecision.stale:
        _drops.staleEpochDropped();
      case EpochDecision.renewed:
        Logger.diagnostic(
          'wifi: sender ${packet.senderId} rejoined — epoch '
          '${verdict.previous} → ${verdict.offered}',
        );
        _routePin.forget(packet.senderId);
        _senderRoutes.remove(packet.senderId);
        _seenSenderRoutes.removeWhere(
          (r) => r.startsWith('${packet.senderId}@'),
        );
        _codec.resetDecoders();
        _codec.resetMediaDecoders();
    }
    return verdict.isAccepted;
  }

  bool _unicastUnconfirmed = false;
  final PeerPingTracker _pings = PeerPingTracker();
  Timer? _pingTimer;
  int _pingToken = 0;
  bool _pingInFlight = false;
  static const _pingInterval = Duration(seconds: 1);
  final Map<String, _PeerAudioStats> _rxBySender = {};
  final Map<String, String> _senderAtAddress = {};

  void _startPingLoop(int myGen) {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_generation != myGen) {
        _pingTimer?.cancel();
        return;
      }
      if (!_pingInFlight) unawaited(_pingPeers(myGen));
    });
  }

  Future<void> _pingPeers(int myGen) async {
    if (_pingInFlight) return;
    _pingInFlight = true;
    try {
      final targets = _peers.keys.toList(growable: false);
      for (final address in targets) {
        if (_generation != myGen) return;
        final senderId = _senderAtAddress[address];
        final rx = senderId == null ? null : _rxBySender[senderId];
        final token = ++_pingToken;
        final packet = await _transportCapabilityHeartbeat.encodePing(
          token: token,
          lastTxSeq: _audioSeq,
          lastRxSeq: rx?.lastSeq ?? 0,
          audioRxPackets: rx?.count ?? 0,
        );
        if (_generation != myGen) return;
        final sentAt = DateTime.now();
        if (_trySend(packet, InternetAddress(address))) {
          _pings.sent(address, token, sentAt);
        }
      }

      if (_generation != myGen) return;
      final now = DateTime.now();
      _loss.retain(_currentlyHeardSenders());
      _capabilities.retain(_currentlyHeardSenders());
      _syncFormatProfile();
      _mediaCapabilities.retain(_currentlyHeardSenders());
      _syncMediaFormatProfile();
      _syncMediaQuality();
      _codec.applyTuning(
        OpusTuner.forProfile(_negotiatedFormat).tune(
          AudioLinkConditions(
            lossFraction: _loss.worstLossFraction,
            rtt: _lastRtt,
          ),
        ),
      );
      _updateMediaTuning();

      final unconfirmed = _pings.unconfirmedAmong(targets, now);
      final wasUnconfirmed = _unicastUnconfirmed;
      _unicastUnconfirmed = unconfirmed.isNotEmpty;
      if (_unicastUnconfirmed != wasUnconfirmed) {
        Logger.diagnostic(
          _unicastUnconfirmed
              ? 'wifi: $unconfirmed heard but not answering unicast pings — '
                    'audio is going back on the broadcast leg for them'
              : 'wifi: every heard peer is answering unicast again — '
                    'audio back to unicast only',
        );
      }
    } finally {
      _pingInFlight = false;
    }
  }

  Future<void> _handleControl(
    DecodedTransportCapabilityControl decoded,
    String fromAddress,
    int myGen,
  ) async {
    final packet = decoded.packet;
    switch (packet) {
      case PingPacket():
        final rx = _rxBySender[packet.senderId];
        final response = await _transportCapabilityHeartbeat.encodePong(
          token: packet.token,
          lastTxSeq: _audioSeq,
          lastRxSeq: rx?.lastSeq ?? 0,
          audioRxPackets: rx?.count ?? 0,
        );
        if (_generation != myGen) return;
        _trySend(response, InternetAddress(fromAddress));
      case PongPacket():
        final observedAt = DateTime.now();
        final rtt = _pings.pong(fromAddress, packet.token, observedAt);
        if (rtt != null) {
          _lastRtt = rtt;
          _transportCapabilityHeartbeat.observeMatchedPong(
            decoded: decoded,
            peerKey: packet.senderId,
            observedAt: observedAt,
          );
        }
        _loss.sample(
          packet.senderId,
          ourSentCount: _audioSeq,
          theirReceivedCount: packet.audioRxPackets,
        );
    }
  }

  final PeerLossTracker _loss = PeerLossTracker();
  Duration? _lastRtt;
  final SenderRoutePin _routePin = SenderRoutePin();

  void _rememberPeer(String address) {
    if (_localAddresses.contains(address)) return;
    final now = DateTime.now();
    _peers[address] = now;
    _recoveryPeers[address] = now;
    _lastPeerAt = now;
  }

  static const _targetLogInterval = Duration(seconds: 30);
  final Map<String, DateTime> _targetLoggedAt = {};

  bool _mayLogTarget(String target, DateTime now) {
    final last = _targetLoggedAt[target];
    if (last != null && now.difference(last) < _targetLogInterval) return false;
    _targetLoggedAt[target] = now;
    return true;
  }

  bool _trySend(List<int> packet, InternetAddress target) {
    final socket = _sendSocket;
    if (socket == null) return false;
    try {
      final sent = socket.send(packet, target, kBroadcastPort);
      if (sent == 0) {
        _drops.blocked();
        if (_failingTargets.add(target.address) &&
            _mayLogTarget(target.address, DateTime.now())) {
          Logger.diagnostic(
            'wifi: send to ${target.address} dropped (socket would block)',
          );
        }
        return false;
      }
      if (_failingTargets.remove(target.address) &&
          _mayLogTarget(target.address, DateTime.now())) {
        Logger.diagnostic('wifi: send to ${target.address} recovered');
      }
      return true;
    } catch (e) {
      _sendErrorWindow++;
      if (_failingTargets.add(target.address) &&
          _mayLogTarget(target.address, DateTime.now())) {
        Logger.diagnostic('wifi: send to ${target.address} failed: $e');
      }
      return false;
    }
  }

  Future<void> _resolveNetwork() async {
    final subnets = <String>{};
    final locals = <String>{};
    try {
      for (final entry in await LanIpv4.addresses()) {
        locals.add(entry.address);
        if (!LanIpv4.isPrivate(entry.address)) continue;
        final parts = entry.address.split('.');
        subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
      }
    } catch (e) {
      Logger.log('Could not enumerate network interfaces: $e');
    }

    final isHost = sessionRole == SessionRole.host;
    final kept = HostSubnetFilter.apply(
      subnets: subnets.toList(),
      clientIp: isHost ? await WifiClientAddress.current() : null,
      isHost: isHost,
    );
    if (kept.length != subnets.length) {
      Logger.diagnostic(
        'wifi: hosting — not announcing on ${subnets.difference(kept.toSet())}, '
        'the network this phone is only a client of. Peers are on our AP.',
      );
    }

    final targets = <String>{
      '255.255.255.255',
      for (final prefix in kept) '$prefix.255',
    };
    _broadcastTargets = targets.map(InternetAddress.new).toList();
    _sweepSubnets = kept;
    if (!setEquals(locals, _localAddresses)) {
      Logger.diagnostic(
        'wifi: local addresses $locals, broadcasting to $targets',
      );
      if (_localAddresses.isNotEmpty && _sendSocket != null) {
        Logger.diagnostic('wifi: network changed — rebuilding the send socket');
        _sendSocket?.close();
        _sendSocket = null;
      }
      _peers.clear();
      _heardSubnets.clear();
      _heardSubnetBroadcasts = const [];
    }
    _localAddresses = locals;
    _retargetSweep();
  }

  void _setHealth(ConnectionHealth health) {
    if (_connectionController.isClosed) return;
    _connectionController.add(health);
  }
}

class _RouteStats {
  int packets = 0;
  DateTime lastAt = DateTime.now();

  void hit() {
    packets++;
    lastAt = DateTime.now();
  }
}

class _PeerAudioStats {
  int lastSeq = 0;
  int count = 0;

  void record(int seq) {
    count++;
    if (seq > lastSeq) lastSeq = seq;
  }
}

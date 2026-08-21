import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../../core/identity/session_epoch.dart';
import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/audio_profile.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/guest_link_state.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/transport_stats.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/guest_link_controller.dart';
import '../../domain/repository/transfer_repository.dart';
import '../../domain/service/audio_capability_negotiator.dart';
import '../codec/opus_audio_codec.dart';
import '../codec/waki_packet_codec.dart';
import '../webrtc/ice_config.dart';
import '../webrtc/sdp_codec.dart';

/// Placeholder sender id for the web guest — a WebRTC link is 1-to-1 and
/// never echoes our own packets back, so any stable non-IP id works.
const kGuestPeerId = 'guest';

/// WebRTC transport for hosting a browser guest — no server, ever, but not
/// LAN-only: [kIceServers] adds public STUN so a genuinely remote guest (not
/// on the host's network) can connect too, provided NAT allows it.
///
/// Signaling is a QR code or a copyable link (see [GuestLinkController]);
/// after that a single unordered data channel carries the exact same
/// [WakiPacketCodec] bytes as WiFi UDP and Bluetooth. The channel allows up
/// to 2 retransmits: enough to survive a stray WiFi drop without turning
/// packet loss into unbounded latency (the jitter buffer conceals what still
/// goes missing).
@lazySingleton
class WebRtcTransferRepository
    implements TransferRepository, GuestLinkController {
  final DeviceIdentity _identity;

  /// Stamped but not enforced, for the same reason as Bluetooth — see the
  /// note on [BluetoothTransferRepository]. A closed data channel takes its
  /// buffered frames with it, so no packet can outlive the session it was
  /// sent in.
  final SessionEpoch _epoch;

  WebRtcTransferRepository(this._identity, this._epoch);

  late final _codec = WakiPacketCodec(_identity.id, _epoch);

  /// One peer at a time on this transport — see [AudioCapabilityNegotiator]'s
  /// class doc for why a point-to-point transport still uses the same
  /// negotiator as WiFi's whole-roster case.
  final AudioCapabilityNegotiator _capabilities = AudioCapabilityNegotiator();

  AudioFormatProfile _negotiatedFormat = AudioFormatProfile.legacy16k;

  @override
  AudioFormatProfile get negotiatedFormat => _negotiatedFormat;

  void _syncFormatProfile() {
    final resolved = _capabilities.resolve();
    if (resolved == _negotiatedFormat) return;
    final previous = _negotiatedFormat;
    _negotiatedFormat = resolved;
    _codec.setFormatProfile(resolved);
    Logger.diagnostic(
      'webrtc: negotiated audio profile ${previous.label} -> ${resolved.label}',
    );
  }

  /// #29's media analog — same one-peer-at-a-time reasoning as
  /// [_capabilities], same wire byte, different bits (see
  /// [AudioCapabilityNegotiator.media]).
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
      'webrtc: negotiated media profile ${previous?.label ?? 'none'} -> '
      '${resolved?.label ?? 'none'}',
    );
  }

  final _packetController = StreamController<WakiPacket>.broadcast();
  final _connectionController = StreamController<ConnectionHealth>.broadcast();
  final _linkStateController = StreamController<GuestLinkState>.broadcast();

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  GuestLinkState _linkState = GuestLinkState.idle;
  int _audioSeq = 0;

  /// #30's independent counter for the media stream — its own sequence
  /// space, separate from [_audioSeq].
  int _mediaSeq = 0;

  bool _autoReconnectEnabled = true;
  int _retryGen = 0;
  static const _kMaxRetryAttempts = 3;

  /// This side always hosts: the app creates the invite and the browser
  /// answers it, never the other way round.
  @override
  SessionRole get sessionRole => SessionRole.host;

  void _setHealth(ConnectionHealthStatus status) {
    // Guest/WebRTC has no exposed backoff schedule, so no countdown — the
    // banner shows the indeterminate "reconnecting…" for this transport.
    if (!_connectionController.isClosed) {
      _connectionController.add(ConnectionHealth(status));
    }
  }

  void _setLink(GuestLinkState state) {
    _linkState = state;
    if (!_linkStateController.isClosed) _linkStateController.add(state);
  }

  // ── GuestLinkController ─────────────────────────────────────────────────

  @override
  Stream<GuestLinkState> get linkState => _linkStateController.stream;

  @override
  Future<String> createInvite() async {
    await _teardownPeer();
    _setLink(GuestLinkState.preparing);
    try {
      final pc = await createPeerConnection({'iceServers': kIceServers});
      _pc = pc;

      final dc = await pc.createDataChannel(
        'tark',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmits = 2
          ..binaryType = 'binary',
      );
      _wireChannel(dc);

      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);
      // Non-trickle: wait for candidates to land inside the SDP so the
      // QR/link contains everything (there is no signaling channel for late
      // candidates).
      await waitIceGathering(pc);
      final local = await pc.getLocalDescription();
      if (local == null) throw StateError('no local description');
      _setLink(GuestLinkState.awaitingPeer);
      return encodeSessionDescription(local);
    } catch (e) {
      Logger.log('Guest invite failed: $e');
      _setLink(GuestLinkState.failed);
      rethrow;
    }
  }

  @override
  Future<void> acceptAnswer(String payload) async {
    final pc = _pc;
    if (pc == null) {
      _setLink(GuestLinkState.failed);
      throw StateError('No pending invite');
    }
    try {
      await pc.setRemoteDescription(decodeSessionDescription(payload));
      // connected fires from the data channel open callback.
    } catch (e) {
      Logger.log('Guest answer rejected: $e');
      _setLink(GuestLinkState.failed);
      rethrow;
    }
  }

  @override
  void endSession() {
    _retryGen++; // abort any in-flight reconnect attempt
    unawaited(_teardownPeer());
    _setLink(GuestLinkState.idle);
    _setHealth(ConnectionHealthStatus.down);
  }

  void _wireChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _retryGen++; // any in-flight retry loop is now moot
        _setLink(GuestLinkState.connected);
        _setHealth(ConnectionHealthStatus.healthy);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        final wasConnected = _linkState == GuestLinkState.connected;
        if (wasConnected) _setLink(GuestLinkState.failed);
        if (wasConnected && _autoReconnectEnabled) {
          unawaited(_attemptReconnect());
        } else {
          _setHealth(ConnectionHealthStatus.down);
        }
      }
    };
    dc.onMessage = (message) {
      if (!message.isBinary) return;
      final packet = _codec.decode(message.binary, kGuestPeerId);
      if (packet == null) return;
      if (packet is PresencePacket) {
        _capabilities.observePeer(kGuestPeerId, packet.capabilityBitmask);
        _syncFormatProfile();
        _mediaCapabilities.observePeer(kGuestPeerId, packet.capabilityBitmask);
        _syncMediaFormatProfile();
      }
      _packetController.add(packet);
    };
  }

  /// Best-effort recovery on the SAME already-negotiated peer connection.
  /// There is no ongoing signaling channel after the initial QR/link
  /// exchange (non-trickle, one-shot SDP), so this cannot renegotiate with
  /// the remote peer — it can only help a transient ICE-level hiccup that
  /// resolves against candidates already known to both sides. A fully
  /// torn-down connection needs a brand-new invite, which is why this is
  /// bounded and falls back to a manual "Reconnect" (= new invite) instead
  /// of retrying forever.
  Future<void> _attemptReconnect() async {
    final gen = ++_retryGen;
    _setHealth(ConnectionHealthStatus.reconnecting);
    final backoff = ExponentialBackoff();
    for (var attempt = 0; attempt < _kMaxRetryAttempts; attempt++) {
      if (_retryGen != gen) return; // superseded by a fresh connect/retry
      final pc = _pc;
      if (pc == null) break;
      try {
        final offer = await pc.createOffer({'iceRestart': true});
        await pc.setLocalDescription(offer);
      } catch (e) {
        Logger.log('WebRTC ICE restart attempt failed: $e');
      }
      await Future.delayed(backoff.next());
      if (_retryGen != gen) return;
      if (_linkState == GuestLinkState.connected) return; // healed
    }
    if (_retryGen == gen) _setHealth(ConnectionHealthStatus.down);
  }

  Future<void> _teardownPeer() async {
    final dc = _dc;
    final pc = _pc;
    _dc = null;
    _pc = null;
    // What the departed guest advertised says nothing about whoever connects
    // next — clear rather than carry a stale mutual profile into a session
    // that hasn't confirmed anything yet.
    _capabilities.clear();
    _negotiatedFormat = AudioFormatProfile.legacy16k;
    _codec.setFormatProfile(AudioFormatProfile.legacy16k);
    _mediaCapabilities.clear();
    _negotiatedMediaFormat = null;
    // Independent of voice's reset — a media-only event never resets voice
    // and vice versa (see [WakiPacketCodec.resetMediaDecoders]).
    _codec.resetMediaDecoders();
    _mediaSeq = 0;
    try {
      await dc?.close();
      await pc?.close();
    } catch (e) {
      Logger.log('WebRTC teardown: $e');
    }
  }

  // ── TransferRepository ──────────────────────────────────────────────────

  @override
  Stream<WakiPacket> startListening() => _packetController.stream;

  /// Point-to-point: no routes to duplicate across, no broadcast queue to back
  /// up, and a send path that either works or has already reported the link
  /// down. Nothing here to measure that the health status does not say.
  @override
  TransportStats get stats => TransportStats.none;

  @override
  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  ) async {
    try {
      final dc = _dc;
      if (dc == null || _linkState != GuestLinkState.connected) {
        return const Left(DataTransferFailure());
      }
      final payload = _codec.encodeAudio(samples, senderName, _audioSeq++);
      await dc.send(RTCDataChannelMessage.fromBinary(payload));
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
    try {
      final dc = _dc;
      if (dc == null || _linkState != GuestLinkState.connected) {
        return const Left(DataTransferFailure());
      }
      final payload = _codec.encodeMediaAudio(
        samples,
        senderName,
        _mediaSeq++,
      );
      await dc.send(RTCDataChannelMessage.fromBinary(payload));
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking,
  ) async {
    try {
      final dc = _dc;
      if (dc == null || _linkState != GuestLinkState.connected) {
        return const Right(null); // not linked yet — nothing to send
      }
      final payload = _codec.encodePresence(
        senderName,
        isTalking,
        role: sessionRole,
      );
      await dc.send(RTCDataChannelMessage.fromBinary(payload));
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Stream<ConnectionHealth> connect() => _connectionController.stream;

  @override
  void setAutoReconnectEnabled(bool enabled) {
    _autoReconnectEnabled = enabled;
    if (!enabled) _retryGen++; // abort any in-flight reconnect attempt
  }

  @override
  void retryNow() {
    if (_linkState == GuestLinkState.connected) return;
    unawaited(_attemptReconnect());
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

  /// A WebRTC data channel is point-to-point and reports its own state, so
  /// there is no send path that can silently stop working while the receive
  /// side carries on — the failure this exists for is a Wi-Fi/UDP one.
  @override
  void repairSendPath() {}

  @override
  void stopConnection() => endSession();

  @override
  @disposeMethod
  void dispose() {
    unawaited(_teardownPeer());
    unawaited(_packetController.close());
    unawaited(_connectionController.close());
    unawaited(_linkStateController.close());
    _codec.release();
  }
}

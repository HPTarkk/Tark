import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/guest_link_state.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/guest_link_controller.dart';
import '../../domain/repository/transfer_repository.dart';
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
  final _codec = WakiPacketCodec();

  final _packetController = StreamController<WakiPacket>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _linkStateController = StreamController<GuestLinkState>.broadcast();

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  GuestLinkState _linkState = GuestLinkState.idle;
  int _audioSeq = 0;

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
    unawaited(_teardownPeer());
    _setLink(GuestLinkState.idle);
    if (!_connectionController.isClosed) _connectionController.add(false);
  }

  void _wireChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _setLink(GuestLinkState.connected);
        if (!_connectionController.isClosed) _connectionController.add(true);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (!_connectionController.isClosed) _connectionController.add(false);
        if (_linkState == GuestLinkState.connected) {
          _setLink(GuestLinkState.failed);
        }
      }
    };
    dc.onMessage = (message) {
      if (!message.isBinary) return;
      final packet = _codec.decode(message.binary, kGuestPeerId);
      if (packet != null) _packetController.add(packet);
    };
  }

  Future<void> _teardownPeer() async {
    final dc = _dc;
    final pc = _pc;
    _dc = null;
    _pc = null;
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

  @override
  Future<Either<Failure, void>> sendAudio(
      List<double> samples, String senderName) async {
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
  Future<Either<Failure, void>> sendPresence(
      String senderName, bool isTalking) async {
    try {
      final dc = _dc;
      if (dc == null || _linkState != GuestLinkState.connected) {
        return const Right(null); // not linked yet — nothing to send
      }
      final payload = _codec.encodePresence(senderName, isTalking);
      await dc.send(RTCDataChannelMessage.fromBinary(payload));
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Stream<bool> connect() => _connectionController.stream;

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

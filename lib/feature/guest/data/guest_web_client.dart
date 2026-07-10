import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/utils/exponential_backoff.dart';
import '../../../core/utils/logger.dart';
// Direct file imports (not the transfer barrel): the barrel exports pages
// that import dart:io, which would break the web build this client exists
// for.
import '../../transfer/data/webrtc/ice_config.dart';
import '../../transfer/data/webrtc/sdp_codec.dart';
import '../../transfer/domain/entity/guest_link_state.dart';

/// Browser side of the serverless guest link: answers the offer embedded in
/// the invite URL and exposes the raw packet channel.
class GuestWebClient {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;

  final _messages = StreamController<Uint8List>.broadcast();
  final _linkController = StreamController<GuestLinkState>.broadcast();
  GuestLinkState _link = GuestLinkState.idle;

  bool autoReconnectEnabled = true;
  int _retryGen = 0;
  static const _kMaxRetryAttempts = 3;

  Stream<Uint8List> get messages => _messages.stream;
  Stream<GuestLinkState> get linkState => _linkController.stream;
  GuestLinkState get currentLink => _link;

  bool get isOpen => _link == GuestLinkState.connected;

  void _setLink(GuestLinkState state) {
    _link = state;
    if (!_linkController.isClosed) _linkController.add(state);
  }

  /// Builds the reply for the host's offer payload; returns the encoded
  /// answer to render as the reply QR.
  Future<String> answerOffer(String offerPayload) async {
    _setLink(GuestLinkState.preparing);
    try {
      final offer = decodeSessionDescription(offerPayload);
      final pc = await createPeerConnection({'iceServers': kIceServers});
      _pc = pc;
      pc.onDataChannel = _wireChannel;

      await pc.setRemoteDescription(offer);
      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      await waitIceGathering(pc);
      final local = await pc.getLocalDescription();
      if (local == null) throw StateError('no local description');
      _setLink(GuestLinkState.awaitingPeer);
      return encodeSessionDescription(local);
    } catch (e) {
      Logger.log('Guest answer failed: $e');
      _setLink(GuestLinkState.failed);
      rethrow;
    }
  }

  void _wireChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _retryGen++; // any in-flight retry loop is now moot
        _setLink(GuestLinkState.connected);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed &&
          _link == GuestLinkState.connected) {
        _setLink(GuestLinkState.failed);
        if (autoReconnectEnabled) unawaited(_attemptReconnect());
      }
    };
    dc.onMessage = (message) {
      if (!message.isBinary || _messages.isClosed) return;
      _messages.add(message.binary);
    };
  }

  /// Best-effort recovery on the same already-negotiated peer connection —
  /// see WebRtcTransferRepository's identical method for why this can only
  /// help a transient hiccup, not a fully torn-down link (no signaling
  /// channel survives past the initial QR/link exchange).
  Future<void> _attemptReconnect() async {
    final gen = ++_retryGen;
    final backoff = ExponentialBackoff();
    for (var attempt = 0; attempt < _kMaxRetryAttempts; attempt++) {
      if (_retryGen != gen) return;
      final pc = _pc;
      if (pc == null) break;
      try {
        final offer = await pc.createOffer({'iceRestart': true});
        await pc.setLocalDescription(offer);
      } catch (e) {
        Logger.log('Guest ICE restart attempt failed: $e');
      }
      await Future.delayed(backoff.next());
      if (_retryGen != gen || _link == GuestLinkState.connected) return;
    }
    if (_retryGen == gen) _setLink(GuestLinkState.failed);
  }

  /// Manual retry — the only recovery path when [autoReconnectEnabled] is
  /// off, and also usable to retry immediately after the bounded auto-retry
  /// gives up.
  void retryNow() {
    if (_link == GuestLinkState.connected) return;
    unawaited(_attemptReconnect());
  }

  void send(Uint8List bytes) {
    final dc = _dc;
    if (dc == null || !isOpen) return;
    dc.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Future<void> dispose() async {
    _retryGen++;
    try {
      await _dc?.close();
      await _pc?.close();
    } catch (e) {
      Logger.log('Guest client teardown: $e');
    }
    await _messages.close();
    await _linkController.close();
  }
}

import 'dart:async';
import 'dart:typed_data';

import '../../domain/entity/transport_capability_advertisement.dart';
import '../../domain/entity/transport_capability_observation.dart';
import '../../domain/repository/transport_capability_observation_source.dart';
import '../capability/transport_capability_reader.dart';
import 'transport_capability_control_codec.dart';

typedef TransportCapabilitySnapshotReader =
    Future<TransportCapabilityAdvertisement?> Function();

/// Session-scoped bridge between truthful local capability evidence and the
/// existing mixed-version-safe control heartbeat.
///
/// It owns no timer: callers sample it only on their existing heartbeat cadence.
/// Remote capability is exposed only through [observeMatchedPong], which is
/// deliberately separate from decode so an arbitrary inbound ping/forged tail
/// cannot become Room planning evidence. The Wi-Fi caller invokes that method
/// only after its existing ping tracker has matched the pong token/route.
final class TransportCapabilityHeartbeatRuntime
    implements TransportCapabilityObservationSource {
  TransportCapabilityHeartbeatRuntime({
    required this.codec,
    TransportCapabilitySnapshotReader? readLocalCapability,
  }) : _readLocalCapability =
           readLocalCapability ?? TransportCapabilityReader.current;

  final TransportCapabilityControlCodec codec;
  final TransportCapabilitySnapshotReader _readLocalCapability;
  final _observations =
      StreamController<TransportCapabilityObservation>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      _observations.stream;

  Future<Uint8List> encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) async => codec.encodePing(
    token: token,
    lastTxSeq: lastTxSeq,
    lastRxSeq: lastRxSeq,
    audioRxPackets: audioRxPackets,
    capability: await _safeReadLocalCapability(),
  );

  Future<Uint8List> encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) async => codec.encodePong(
    token: token,
    lastTxSeq: lastTxSeq,
    lastRxSeq: lastRxSeq,
    audioRxPackets: audioRxPackets,
    capability: await _safeReadLocalCapability(),
  );

  DecodedTransportCapabilityControl? decodeControl(
    Uint8List bytes,
    String fallbackSenderId,
  ) => codec.decodeControl(bytes, fallbackSenderId);

  /// Admits capability evidence only after the caller has independently proven
  /// that this decoded packet is the expected pong for [peerKey].
  void observeMatchedPong({
    required DecodedTransportCapabilityControl decoded,
    required String peerKey,
    required DateTime observedAt,
  }) {
    if (_disposed || peerKey.isEmpty) return;
    final capability = decoded.capability;
    if (capability == null) return;
    _observations.add(
      TransportCapabilityObservation(
        peerKey: peerKey,
        capability: capability,
        observedAt: observedAt.toUtc(),
      ),
    );
  }

  Future<TransportCapabilityAdvertisement?> _safeReadLocalCapability() async {
    if (_disposed) return null;
    try {
      return await _readLocalCapability();
    } catch (_) {
      // Capability evidence is optional. A platform/read failure remains
      // unknown instead of blocking the heartbeat or fabricating defaults.
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _observations.close();
  }
}

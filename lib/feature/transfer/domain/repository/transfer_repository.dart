import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../entity/connection_health.dart';
import '../entity/waki_packet.dart';

abstract interface class TransferRepository {
  Stream<WakiPacket> startListening();

  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  );

  Future<Either<Failure, void>> sendPresence(String senderName, bool isTalking);

  Stream<ConnectionHealth> connect();

  void stopConnection();

  /// Whether a dropped link retries by itself. When false, a drop is
  /// reported as [ConnectionHealthStatus.down] and stays there until
  /// [retryNow] is called instead of auto-retrying with backoff.
  void setAutoReconnectEnabled(bool enabled);

  /// Manually trigger a reconnect attempt right now, bypassing any backoff
  /// wait (and, if auto-reconnect is off, the only way to retry at all).
  void retryNow();

  /// Clears stateful per-sender codec state (Opus decoders). Call after a
  /// detected reconnect so stale prediction state from before the drop
  /// doesn't garble audio once a sender resumes.
  void resetCodecState();

  void dispose();
}

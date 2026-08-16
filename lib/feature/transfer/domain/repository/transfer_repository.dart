import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../entity/audio_profile.dart';
import '../entity/connection_health.dart';
import '../entity/session_role.dart';
import '../entity/transport_stats.dart';
import '../entity/waki_packet.dart';

abstract interface class TransferRepository {
  Stream<WakiPacket> startListening();

  /// The part this device plays in the current link, stamped on every
  /// presence packet so the other end can name it too. Each transport
  /// answers from what it knows: which side of the Bluetooth connection it
  /// is, whether it hosts the guest link, which end of the hotspot bridge
  /// the user picked. [SessionRole.unknown] until a session exists.
  SessionRole get sessionRole;

  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  );

  Future<Either<Failure, void>> sendPresence(String senderName, bool isTalking);

  /// Declares what [sendAudio] is about to carry, so the transport can encode
  /// it appropriately. Idempotent — callers set it whenever the channel's
  /// state changes rather than tracking transitions themselves.
  void setAudioProfile(AudioProfile profile);

  Stream<ConnectionHealth> connect();

  /// Cumulative counters for grading the link, sampled by the caller on
  /// whatever cadence it likes. [TransportStats.none] on transports that
  /// measure none of it — a point-to-point link either carries traffic or is
  /// disconnected, and has no route duplicates or broadcast queue to report.
  TransportStats get stats;

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

  /// Rebuilds whatever this transport uses to transmit, because a peer we can
  /// hear has told us it cannot hear us.
  ///
  /// Separate from [retryNow], which is about a link that has announced itself
  /// as down. This is the opposite case: every local signal says the session is
  /// healthy — packets arriving, socket bound, roster populated — and the only
  /// evidence to the contrary came from the other end. See
  /// [PresencePacket.heardIds].
  ///
  /// A no-op on point-to-point transports, where a one-way data channel isn't
  /// a state the link can be in.
  void repairSendPath();

  void dispose();
}

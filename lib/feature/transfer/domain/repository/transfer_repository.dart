import 'package:dartz/dartz.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/error/failure.dart';
import '../entity/audio_profile.dart';
import '../entity/connection_health.dart';
import '../entity/session_role.dart';
import '../entity/transport_stats.dart';
import '../entity/waki_packet.dart';

abstract interface class TransferRepository {
  Stream<WakiPacket> startListening();

  /// The audio wire format every peer this transport currently knows about
  /// has confirmed it can run — see `AudioCapabilityNegotiator`.
  /// [AudioFormatProfile.legacy16k] until at least one peer has been heard
  /// from, and always again once none has. Read after each [PresencePacket]
  /// to notice a change (the transport applies its own encoder to the new
  /// profile automatically; a caller driving playback — see
  /// `AudioEngine.setWireFormat` — has to notice separately).
  AudioFormatProfile get negotiatedFormat;

  /// The HD Shared Music profile every peer this transport currently knows
  /// about has confirmed it can run — the media analog of [negotiatedFormat],
  /// resolved the same way (see `AudioCapabilityNegotiator.media`) but with
  /// no floor to fall back to: null means no currently-known peer supports
  /// any media profile (including "no peer known yet"), which is a normal
  /// state rather than a degraded one — sharing music is optional, unlike
  /// voice. Nothing sends HD media over the wire from this negotiated value
  /// yet (#29 checkpoint 2 is negotiation only; issue #30 owns the send
  /// path) — this exists so the capability itself is discoverable, tested,
  /// and loggable ahead of that.
  AudioFormatProfile? get negotiatedMediaFormat;

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

  /// Sends one Shared Music frame as an independent stream — see #30 and
  /// [negotiatedMediaFormat]. Callers must only call this once
  /// [negotiatedMediaFormat] is non-null (every currently-known peer has
  /// negotiated a media profile); a transport is free to assume it and skip
  /// re-checking per frame. Carries its own sequence space, separate from
  /// [sendAudio]'s, so one stream's loss/reorder never affects the other's
  /// jitter buffer or Opus decoder state.
  Future<Either<Failure, void>> sendMedia(
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

  /// Clears stateful per-sender codec state (Opus decoders), both voice and
  /// media. Call after a detected reconnect so stale prediction state from
  /// before the drop doesn't garble audio once a sender resumes.
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

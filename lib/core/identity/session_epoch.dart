import 'package:injectable/injectable.dart';

/// Which *join* of this device's current run a packet belongs to.
///
/// [DeviceIdentity] answers "who sent this" and is stable for the life of the
/// process. That leaves one gap it cannot cover: the same device leaving a
/// channel and rejoining. Its id is unchanged, so datagrams still in flight
/// from the previous join — sitting in a driver queue, a SoftAP buffer, or a
/// retransmitting Bluetooth stack — arrive after the new one has started and
/// are indistinguishable from live traffic.
///
/// What the receiver does with them is the damage. The jitter buffer keys its
/// sequence on the sender, so a ghost packet carrying the *old* join's [seq]
/// reads as the stream jumping backwards by however far the counter had got,
/// and the buffer resyncs — which the user hears as speech repeating or
/// breaking up. A field session that reconnected repeatedly measured 2737 of
/// those resyncs.
///
/// This is the discriminator. A monotonic counter rather than a random id or a
/// timestamp, because the only comparison anyone needs is between two epochs
/// *from the same device* — "is this packet from an older join than the one I
/// am listening to". A counter answers that with `<`, needs no clock, and can
/// never collide with itself. Two devices' epochs are never compared, so they
/// are free to be identical.
///
/// Not persisted, and deliberately not seeded from the wall clock: a process
/// restart already produces a fresh [DeviceIdentity], so packets from a
/// previous run are attributed to a different sender entirely and never reach
/// this comparison. Within one process the counter only ever climbs.
@lazySingleton
class SessionEpoch {
  SessionEpoch();

  /// Starts at a known epoch, for tests that need to predict what lands on
  /// the wire.
  SessionEpoch.startingAt(this._value);

  int _value = 0;

  /// The epoch stamped on everything currently going out.
  int get value => _value;

  /// Starts a new session. Called when a transport begins listening — the one
  /// point that means "this device has joined a channel" — and never on a
  /// socket rebind, which is the *same* session recovering and must keep its
  /// epoch or every peer would treat the recovery as a rejoin.
  int renew() => ++_value;
}

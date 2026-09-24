import 'dart:async';

import '../../../../core/identity/channel_id.dart';
import '../../../../core/utils/logger.dart';
import '../../../transfer/api/transfer_api.dart';
import '../entity/room.dart';

/// Makes this phone findable on a Wi-Fi/hotspot link while a Room waits for
/// its signed peer proof.
///
/// The readiness gate only lets a Room go live once another member has
/// answered a signed route challenge. That challenge rides the Wi-Fi
/// transport's unicast pings, and the transport only pings addresses it has
/// already heard a datagram from. Before this existed, the only things that
/// bound the UDP socket and broadcast a presence packet were the live Walkie
/// screen and the manual hotspot bridge — and the live screen is exactly what
/// the gate withholds. On the one-scan path neither phone ever did either, so
/// both sat in "connecting" until the gate timed out: the Room was joined, the
/// hotspot was up, the joiner was on it, and nobody could be heard.
///
/// Presence here carries nothing the live session would not send a second
/// later. It stops the moment the Room goes live ([handOff]) so the live
/// screen's own presence is the only one peers hear during a call, and it
/// releases the socket when the attempt fails or is abandoned ([stop]) so a
/// phone left on the lobby is not pinging an empty network.
final class RoomPreLiveAnnouncer {
  RoomPreLiveAnnouncer({
    required TransferRepository transport,
    required String name,
    Duration interval = const Duration(seconds: 1),
  }) : _transport = transport,
       _name = name,
       _interval = interval;

  final TransferRepository _transport;
  final String _name;
  final Duration _interval;

  StreamSubscription<WakiPacket>? _packets;
  Timer? _presence;
  bool _started = false;
  bool _finished = false;

  /// Binds the socket and starts announcing. Idempotent.
  void start() {
    if (_started || _finished) return;
    _started = true;
    Logger.diagnostic('room: pre-live announce start');
    _packets = _transport.startListening().listen(
      (_) {},
      onError: (Object _) {},
    );
    _announce();
    _presence = Timer.periodic(_interval, (_) => _announce());
  }

  void _announce() {
    if (_finished) return;
    unawaited(
      _transport
          .sendPresence(_name, false)
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  /// The Room went live. The live screen takes the socket over by listening
  /// again (the transport's generation counter retires this listener), so
  /// only the announcing stops here — tearing the socket down would race the
  /// session that is about to use it.
  void handOff() {
    if (_finished) return;
    _finished = true;
    _presence?.cancel();
    _presence = null;
    Logger.diagnostic('room: pre-live announce handed off');
  }

  /// The attempt failed or was abandoned: stop announcing and release the
  /// socket this started.
  void stop() {
    if (_finished) return;
    _finished = true;
    _presence?.cancel();
    _presence = null;
    if (!_started) return;
    // Not awaited: an async* listener only honours a cancel at its next
    // yield, and nothing may be arriving. stopConnection() below is what
    // actually closes the socket and ends that listener.
    unawaited(_packets?.cancel());
    _packets = null;
    _transport.stopConnection();
    Logger.diagnostic('room: pre-live announce stopped');
  }

  /// Whether this attempt should announce on [mode]. Bluetooth and the guest
  /// link are point-to-point links that already exist before the Room gate
  /// runs; only the IP transports need to be found first.
  static bool appliesTo(TransferMode mode) =>
      mode == TransferMode.wifi || mode == TransferMode.hotspot;

  /// The wire channel every member of [roomId] uses.
  ///
  /// Wi-Fi packets are filtered by a six-character channel code so two groups
  /// on one network do not hear each other. A Room never set one: the phone
  /// that raised the hotspot drew a fresh random code, and the phone that
  /// scanned kept whatever the last session left behind. Two different codes
  /// drop each other's presence, so neither phone learns the other's address
  /// and no proof is ever exchanged. Deriving the code from the Room gives
  /// every member the same one with nothing to hand over. FNV-1a with a
  /// domain prefix, so it is unrelated to the log correlation id.
  static ChannelId channelFor(RoomId roomId) {
    var hash = 0x811c9dc5;
    for (final unit in 'tark-room-channel:${roomId.value}'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final value = hash & ChannelId.maxValue;
    return ChannelId(value == 0 ? 1 : value);
  }
}

import 'dart:async';

import '../entity/room_session.dart';
import '../entity/transport_attachment.dart';

/// Application-facing seam around [RoomSession].
///
/// Presentation code consumes one room stream and does not need to know which
/// concrete Wi-Fi/Bluetooth/WebRTC repository is attached. Concrete transport
/// adapters translate their own callbacks into these typed transitions.
class RoomSessionController {
  RoomSessionController(this._state);

  RoomSession _state;
  final StreamController<RoomSession> _changes =
      StreamController<RoomSession>.broadcast(sync: true);
  bool _closed = false;

  RoomSession get state => _state;
  Stream<RoomSession> get changes => _changes.stream;

  void attach({
    required TransportKind kind,
    String? role,
    String? reason,
  }) {
    _emit(_state.startAttachment(kind: kind, role: role, reason: reason));
  }

  void attachmentReady({required int generation, String? role}) {
    _emit(_state.attachmentReady(generation: generation, role: role));
  }

  void attachmentDegraded({required int generation, String? reason}) {
    _emit(
      _state.attachmentDegraded(generation: generation, reason: reason),
    );
  }

  void recover({required int generation, String? reason}) {
    _emit(
      _state.beginTransportRecovery(generation: generation, reason: reason),
    );
  }

  void replaceTransport({
    required TransportKind kind,
    String? role,
    String? reason,
  }) {
    _emit(_state.replaceTransport(kind: kind, role: role, reason: reason));
  }

  void attachmentFailed({required int generation, String? reason}) {
    _emit(_state.attachmentFailed(generation: generation, reason: reason));
  }

  void setMuted(bool muted) => _emit(_state.setMuted(muted));

  void updateMembers(Iterable<String> memberIds) =>
      _emit(_state.updateMembers(memberIds));

  void leave() => _emit(_state.leave());

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }

  void _emit(RoomSession next) {
    if (_closed) return;
    if (identical(next, _state) || next == _state) return;
    _state = next;
    _changes.add(next);
  }
}

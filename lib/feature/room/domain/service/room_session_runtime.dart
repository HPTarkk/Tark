import 'dart:async';

import '../entity/room_session.dart';
import '../entity/transport_attachment.dart';
import 'room_session_controller.dart';
import 'room_session_resource_owner.dart';

/// Runtime ownership seam for one logical live RoomSession.
///
/// This class deliberately knows no Wi-Fi/Bluetooth/WebRTC implementation.
/// Adapters register their generation-scoped resources here and translate
/// transport callbacks into typed state transitions. Room-level resources
/// (AudioEngine ownership, room subscriptions, user intent) survive attachment
/// replacement and are disposed only on explicit [leave].
class RoomSessionRuntime {
  RoomSessionRuntime({
    required RoomSession initialState,
    RoomSessionController? controller,
    RoomSessionResourceOwner? resources,
  }) : controller = controller ?? RoomSessionController(initialState),
       resources = resources ?? RoomSessionResourceOwner();

  final RoomSessionController controller;
  final RoomSessionResourceOwner resources;
  bool _left = false;

  RoomSession get state => controller.state;
  Stream<RoomSession> get changes => controller.changes;
  int get attachmentGeneration => state.attachment.generation;
  bool get hasLeft => _left || state.hasLeft;

  void ownRoomResource(String key, FutureOr<void> Function() dispose) {
    _ensurePresent();
    resources.ownRoomResource(key, dispose);
  }

  /// Registers a resource only for the current attachment generation.
  /// A delayed callback from an older generation cannot resurrect ownership.
  bool ownCurrentAttachmentResource(
    int generation,
    String key,
    FutureOr<void> Function() dispose,
  ) {
    _ensurePresent();
    if (generation != attachmentGeneration) return false;
    resources.ownAttachmentResource(generation, key, dispose);
    return true;
  }

  Future<int> attach({
    required TransportKind kind,
    String? role,
    String? reason,
  }) async {
    _ensurePresent();
    final oldGeneration = attachmentGeneration;
    controller.attach(kind: kind, role: role, reason: reason);
    final nextGeneration = attachmentGeneration;
    if (oldGeneration != nextGeneration) {
      await resources.disposeAttachment(oldGeneration);
    }
    return nextGeneration;
  }

  Future<int> replaceTransport({
    required TransportKind kind,
    String? role,
    String? reason,
  }) async {
    _ensurePresent();
    final oldGeneration = attachmentGeneration;
    controller.replaceTransport(kind: kind, role: role, reason: reason);
    final nextGeneration = attachmentGeneration;
    if (oldGeneration != nextGeneration) {
      await resources.disposeAttachment(oldGeneration);
    }
    return nextGeneration;
  }

  void ready({required int generation, String? role}) {
    _ensurePresent();
    controller.attachmentReady(generation: generation, role: role);
  }

  void degraded({required int generation, String? reason}) {
    _ensurePresent();
    controller.attachmentDegraded(generation: generation, reason: reason);
  }

  void recover({required int generation, String? reason}) {
    _ensurePresent();
    controller.recover(generation: generation, reason: reason);
  }

  void failed({required int generation, String? reason}) {
    _ensurePresent();
    controller.attachmentFailed(generation: generation, reason: reason);
  }

  void setMuted(bool muted) {
    _ensurePresent();
    controller.setMuted(muted);
  }

  void updateMembers(Iterable<String> memberIds) {
    _ensurePresent();
    controller.updateMembers(memberIds);
  }

  /// Explicit logical leave: terminal and idempotent. All attachment resources
  /// are released first by the owner, followed by room-level resources; no
  /// transport replacement path calls this.
  Future<void> leave() async {
    if (_left) return;
    _left = true;
    controller.leave();
    await resources.disposeAll();
    await controller.close();
  }

  void _ensurePresent() {
    if (hasLeft) {
      throw StateError('A left RoomSessionRuntime cannot accept transitions.');
    }
  }
}

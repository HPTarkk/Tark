import 'dart:async';

/// Owns every disposable resource that belongs to one logical live room.
///
/// The important distinction from transport recovery is lifetime: replacing a
/// TransportAttachment disposes/replaces only resources registered under that
/// attachment generation. Deliberately leaving the room disposes everything,
/// including the AudioEngine owner and room-level subscriptions.
///
/// The class stays platform-free so leak semantics can be tested without
/// sockets, Android reservations, Flutter bindings, or timers actually running.
class RoomSessionResourceOwner {
  final Map<String, FutureOr<void> Function()> _roomResources = {};
  final Map<int, Map<String, FutureOr<void> Function()>> _attachmentResources =
      {};
  bool _disposed = false;

  bool get isDisposed => _disposed;

  int get roomResourceCount => _roomResources.length;

  int attachmentResourceCount(int generation) =>
      _attachmentResources[generation]?.length ?? 0;

  void ownRoomResource(
    String key,
    FutureOr<void> Function() dispose,
  ) {
    _ensureAlive();
    if (_roomResources.containsKey(key)) {
      throw StateError('Room resource "$key" is already owned.');
    }
    _roomResources[key] = dispose;
  }

  void ownAttachmentResource(
    int generation,
    String key,
    FutureOr<void> Function() dispose,
  ) {
    _ensureAlive();
    final resources = _attachmentResources.putIfAbsent(generation, () => {});
    if (resources.containsKey(key)) {
      throw StateError(
        'Attachment $generation resource "$key" is already owned.',
      );
    }
    resources[key] = dispose;
  }

  /// Disposes exactly one attachment generation. Repeating the same call is a
  /// no-op, which makes stale/repeated native recovery callbacks harmless.
  Future<void> disposeAttachment(int generation) async {
    final resources = _attachmentResources.remove(generation);
    if (resources == null) return;
    for (final dispose in resources.values.toList().reversed) {
      await dispose();
    }
  }

  /// Explicit room leave. Idempotent and terminal.
  Future<void> disposeAll() async {
    if (_disposed) return;
    _disposed = true;

    final generations = _attachmentResources.keys.toList()..sort();
    for (final generation in generations.reversed) {
      await disposeAttachment(generation);
    }

    final roomDisposers = _roomResources.values.toList().reversed;
    _roomResources.clear();
    for (final dispose in roomDisposers) {
      await dispose();
    }
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('RoomSessionResourceOwner is already disposed.');
    }
  }
}

import '../../../transfer/api/transfer_api.dart';
import '../entity/transport_attachment.dart';
import '../repository/room_repository.dart';
import 'room_session_factory.dart';
import 'room_session_runtime.dart';
import 'room_transport_health_runtime_adapter.dart';

/// Application-facing binding used only when the user actually enters a live
/// channel. Merely viewing/selecting a saved Room never calls this class and
/// therefore cannot start or attach transport state as a side effect.
///
/// The selected durable Room remains the logical identity while the current
/// transport's existing health stream drives only [TransportAttachment]
/// lifecycle. `TransferRepository.connect()` is a broadcast health stream for
/// the active transport; this binding does not start a second connection.
final class SelectedRoomLiveSessionBinding {
  SelectedRoomLiveSessionBinding({
    required this.rooms,
    required this.transfer,
    required this.modeStore,
  });

  final RoomRepository rooms;
  final TransferRepository transfer;
  final TransferModeStore modeStore;

  RoomSessionRuntime? _runtime;

  RoomSessionRuntime? get runtime => _runtime;

  Future<RoomSessionRuntime?> open({required String sessionId}) async {
    await close();

    final selectedId = await rooms.selectedRoomId();
    if (selectedId == null) return null;
    final saved = await rooms.get(selectedId);
    if (saved == null) return null;

    final runtime = RoomSessionFactory.open(saved, sessionId: sessionId);
    if (runtime == null) return null;

    final adapter = RoomTransportHealthRuntimeAdapter(runtime);
    await adapter.attach(
      kind: transportKindFor(modeStore.mode),
      health: transfer.connect(),
      role: transfer.sessionRole == SessionRole.unknown
          ? null
          : transfer.sessionRole.name,
      reason: 'live_entry',
    );
    _runtime = runtime;
    return runtime;
  }

  Future<void> close() async {
    final current = _runtime;
    _runtime = null;
    if (current != null && !current.hasLeft) await current.leave();
  }

  static TransportKind transportKindFor(TransferMode mode) => switch (mode) {
    TransferMode.wifi => TransportKind.wifi,
    TransferMode.hotspot => TransportKind.hotspot,
    TransferMode.bluetooth => TransportKind.bluetooth,
    TransferMode.guest => TransportKind.webrtc,
  };
}

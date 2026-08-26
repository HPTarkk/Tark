import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../domain/entity/room.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_join_importer.dart';
import '../../domain/service/room_invite_join_orchestrator.dart';
import '../../domain/service/room_session_factory.dart';
import '../../domain/service/room_session_runtime.dart';

final class RoomListState extends Equatable {
  const RoomListState({
    this.rooms = const [],
    this.selectedRoomId,
    this.loading = false,
    this.error,
  });

  final List<SavedRoom> rooms;
  final RoomId? selectedRoomId;
  final bool loading;
  final Object? error;

  SavedRoom? get selectedRoom {
    final selected = selectedRoomId;
    if (selected == null) return null;
    for (final saved in rooms) {
      if (saved.room.id == selected) return saved;
    }
    return null;
  }

  RoomListState copyWith({
    List<SavedRoom>? rooms,
    RoomId? selectedRoomId,
    bool clearSelection = false,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) => RoomListState(
    rooms: rooms ?? this.rooms,
    selectedRoomId: clearSelection
        ? null
        : selectedRoomId ?? this.selectedRoomId,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
  );

  @override
  List<Object?> get props => [rooms, selectedRoomId, loading, error];
}

/// Presentation orchestration for durable saved Rooms.
///
/// Viewing/selecting a Room never starts Wi-Fi, hotspot, Bluetooth or guest
/// transport. A secure invite join is different: it is an explicit user action
/// and may use an injected carrier, but durable state changes only after the
/// issuer response has passed the canonical correlation checks and produced a
/// typed verified grant.
@injectable
class RoomListCubit extends Cubit<RoomListState> {
  RoomListCubit(this._repository)
    : _joinOrchestrator = RoomInviteJoinOrchestrator(),
      _joinImporter = RoomInviteJoinImporter(repository: _repository),
      super(const RoomListState());

  final RoomRepository _repository;
  final RoomInviteJoinOrchestrator _joinOrchestrator;
  final RoomInviteJoinImporter _joinImporter;

  Future<void> load() async {
    if (state.loading) return;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final rooms = await _repository.list();
      final selected = await _repository.selectedRoomId();
      final selectionStillExists =
          selected != null && rooms.any((saved) => saved.room.id == selected);
      if (selected != null && !selectionStillExists) {
        await _repository.select(null);
      }
      emit(
        RoomListState(
          rooms: rooms,
          selectedRoomId: selectionStillExists ? selected : null,
        ),
      );
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
    }
  }

  Future<SavedRoom?> createRoom({
    required String name,
    required String localDisplayName,
  }) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final created = await _repository.create(
        name: name,
        localDisplayName: localDisplayName,
      );
      await _repository.select(created.room.id);
      final rooms = await _repository.list();
      emit(RoomListState(rooms: rooms, selectedRoomId: created.room.id));
      return created;
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
      return null;
    }
  }

  /// Runs one explicit secure invite join attempt through the supplied carrier.
  ///
  /// Rejected, malformed, stale, cancelled or failed carrier exchanges leave
  /// durable Room state untouched. Only a verified grant is imported and then
  /// selected, after which this Cubit reloads from the canonical repository.
  Future<RoomInviteJoinAttemptStatus> joinByInvite({
    required RoomInvitation invitation,
    required String displayName,
    required RoomInviteJoinCarrier carrier,
  }) async {
    if (state.loading) return RoomInviteJoinAttemptStatus.cancelled;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final result = await _joinOrchestrator.join(
        invitation: invitation,
        displayName: displayName,
        carrier: carrier,
      );
      final grant = result.grant;
      if (result.status != RoomInviteJoinAttemptStatus.accepted || grant == null) {
        emit(state.copyWith(loading: false, clearError: true));
        return result.status;
      }

      final saved = await _joinImporter.importGrant(grant);
      final rooms = await _repository.list();
      emit(RoomListState(rooms: rooms, selectedRoomId: saved.room.id));
      return RoomInviteJoinAttemptStatus.accepted;
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
      return RoomInviteJoinAttemptStatus.invalidResponse;
    }
  }

  void cancelInviteJoin() {
    _joinOrchestrator.cancel();
  }

  Future<void> select(RoomId roomId) async {
    final exists = state.rooms.any((saved) => saved.room.id == roomId);
    if (!exists) return;
    await _repository.select(roomId);
    emit(state.copyWith(selectedRoomId: roomId, clearError: true));
  }

  /// Explicitly opens the currently selected durable Room as the logical
  /// source-of-truth for a live session. This creates no network attachment;
  /// transport orchestration attaches to the returned runtime afterwards.
  ///
  /// The identity comes from canonical [SavedRoom] state, never ChannelId or a
  /// current transport address/role. Invalid, archived or inactive membership
  /// fails closed through [RoomSessionFactory].
  RoomSessionRuntime? openSelectedSession({
    required String sessionId,
    bool initiallyMuted = false,
  }) {
    final selected = state.selectedRoom;
    if (selected == null) return null;
    return RoomSessionFactory.open(
      selected,
      sessionId: sessionId,
      initiallyMuted: initiallyMuted,
    );
  }

  Future<void> rename(RoomId roomId, String name) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _repository.rename(roomId, name);
      await _reloadKeepingSelection();
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
    }
  }

  Future<void> archive(RoomId roomId) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _repository.setArchived(roomId, true);
      if (state.selectedRoomId == roomId) await _repository.select(null);
      await _reloadKeepingSelection(
        clearSelection: state.selectedRoomId == roomId,
      );
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
    }
  }

  Future<void> leave(RoomId roomId) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _repository.leave(roomId);
      if (state.selectedRoomId == roomId) await _repository.select(null);
      await _reloadKeepingSelection(
        clearSelection: state.selectedRoomId == roomId,
      );
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
    }
  }

  Future<void> _reloadKeepingSelection({bool clearSelection = false}) async {
    final rooms = await _repository.list();
    final selected = clearSelection ? null : await _repository.selectedRoomId();
    emit(RoomListState(rooms: rooms, selectedRoomId: selected));
  }
}
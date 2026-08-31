import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
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
@injectable
class RoomListCubit extends Cubit<RoomListState> {
  RoomListCubit(
    this._repository, {
    RoomTransportIdentitySecureStore? identityStore,
  }) : _identityLifecycle = RoomTransportIdentityLifecycle(
         store: identityStore ?? PlatformRoomTransportIdentitySecureStore(),
       ),
       _joinOrchestrator = RoomInviteJoinOrchestrator(),
       super(const RoomListState()) {
    _joinImporter = RoomInviteJoinImporter(
      repository: _repository,
      persistTransportIdentity: _identityLifecycle.persistJoinedIdentity,
    );
  }

  final RoomRepository _repository;
  final RoomTransportIdentityLifecycle _identityLifecycle;
  final RoomInviteJoinOrchestrator _joinOrchestrator;
  late final RoomInviteJoinImporter _joinImporter;

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
    SavedRoom? created;
    try {
      created = await _repository.create(
        name: name,
        localDisplayName: localDisplayName,
      );
      try {
        await _identityLifecycle.ensureLocalIdentity(created);
      } catch (_) {
        await _repository.delete(created.room.id);
        rethrow;
      }
      await _repository.select(created.room.id);
      final rooms = await _repository.list();
      emit(RoomListState(rooms: rooms, selectedRoomId: created.room.id));
      return created;
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
      return null;
    }
  }

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
      final memberKeyPair = result.memberKeyPair;
      if (result.status != RoomInviteJoinAttemptStatus.accepted ||
          grant == null ||
          memberKeyPair == null) {
        emit(state.copyWith(loading: false, clearError: true));
        return result.status;
      }

      final saved = await _joinImporter.importGrant(
        grant,
        memberKeyPair: memberKeyPair,
      );
      final rooms = await _repository.list();
      emit(RoomListState(rooms: rooms, selectedRoomId: saved.room.id));
      return RoomInviteJoinAttemptStatus.accepted;
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
      return RoomInviteJoinAttemptStatus.invalidResponse;
    }
  }

  /// Imports a pre-authorised one-scan invite and selects its Room.
  Future<bool> joinDirect(RoomDirectJoinBundle bundle) async {
    if (state.loading || bundle.isExpired) return false;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final grant = RoomInviteJoinGrant(
        roomId: bundle.snapshot.roomId,
        memberId: bundle.memberId,
        displayName: bundle.snapshot.members
            .singleWhere((member) => member.memberId == bundle.memberId)
            .displayName,
        snapshot: bundle.snapshot,
        transportCertificate: bundle.certificate,
      );
      final saved = await _joinImporter.importGrant(
        grant,
        memberKeyPair: bundle.memberKeyPair,
      );
      final rooms = await _repository.list();
      emit(RoomListState(rooms: rooms, selectedRoomId: saved.room.id));
      return true;
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
      return false;
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
      final saved = await _repository.get(roomId);
      await _repository.leave(roomId);
      if (saved != null) {
        await _identityLifecycle.deleteLocalIdentity(saved);
      }
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

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../../../transfer/api/transfer_api.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_join_client.dart';
import '../../domain/service/room_invite_join_importer.dart';
import '../../domain/service/room_invite_join_orchestrator.dart';
import '../../domain/service/room_session_factory.dart';
import '../../domain/service/room_session_runtime.dart';

final class RoomListState extends Equatable {
  const RoomListState({
    this.rooms = const [],
    this.archived = const [],
    this.selectedRoomId,
    this.loading = false,
    this.error,
  });

  /// Rooms that are live on this phone. Never includes archived ones — every
  /// caller that reasons about "my rooms" means this list.
  final List<SavedRoom> rooms;

  /// Rooms put away, kept separate rather than filtered at each call site.
  ///
  /// They used to be dropped by the repository and never read back, which made
  /// archive a delete that reclaimed nothing and could not be undone.
  final List<SavedRoom> archived;

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
    List<SavedRoom>? archived,
    RoomId? selectedRoomId,
    bool clearSelection = false,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) => RoomListState(
    rooms: rooms ?? this.rooms,
    archived: archived ?? this.archived,
    selectedRoomId: clearSelection
        ? null
        : selectedRoomId ?? this.selectedRoomId,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
  );

  @override
  List<Object?> get props => [rooms, archived, selectedRoomId, loading, error];
}

/// Presentation orchestration for durable saved Rooms.
@injectable
class RoomListCubit extends Cubit<RoomListState> {
  RoomListCubit(
    this._repository, {
    // A test seam, not a dependency: the platform store below is the only one
    // production ever uses. Left injectable, the generated config asks GetIt
    // for a type nothing registers and the saved-Rooms page dies on open.
    @ignoreParam RoomTransportIdentitySecureStore? identityStore,
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

  /// Temporary side hint for the *bootstrap* transport only.
  ///
  /// The field test behind #186 exposed a subtle but serious coupling: the
  /// Room lobby used `canManageInvites` to decide which phone should create a
  /// hotspot. A joiner who was deliberately granted invite rights therefore
  /// became a second transport host. Create/one-scan join already know which
  /// end of this hand-off they are, so preserve that fact in the existing
  /// session-scoped role store instead. It is never persisted and does not
  /// make the creator an owner; verified live capability/election supersedes
  /// it once a transport exists.
  SessionRoleStore? get _bootstrapRoleStore =>
      GetIt.instance.isRegistered<SessionRoleStore>()
      ? GetIt.instance<SessionRoleStore>()
      : null;

  Future<void> load() async {
    if (state.loading) return;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final (rooms, archived) = await _partitioned();
      final selected = await _repository.selectedRoomId();
      final selectionStillExists =
          selected != null && rooms.any((saved) => saved.room.id == selected);
      if (selected != null && !selectionStillExists) {
        await _repository.select(null);
      }
      emit(
        RoomListState(
          rooms: rooms,
          archived: archived,
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
      // The phone that just created the Room is the sender side of this
      // immediate one-scan bootstrap. This hint lives only for the current app
      // session; it does not survive a restart or become Room ownership.
      _bootstrapRoleStore?.setRole(SessionRole.host);
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
      _bootstrapRoleStore?.setRole(SessionRole.joiner);
      final rooms = await _repository.list();
      emit(RoomListState(rooms: rooms, selectedRoomId: saved.room.id));
      return RoomInviteJoinAttemptStatus.accepted;
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
      return RoomInviteJoinAttemptStatus.invalidResponse;
    }
  }

  /// Imports a pre-authorised one-scan invite and selects its Room.
  /// Enters a Room straight from a scanned invite.
  ///
  /// [localDisplayName] is this phone's own name for itself. The host had to
  /// name the seat before anyone could scan it — it could not know who would —
  /// so without this the joiner shows up on both rosters as the placeholder
  /// the host invented. Applying it here is the first moment the real name
  /// exists on this side, and it also clears the seat's pending mark: someone
  /// has now demonstrably walked through it.
  Future<bool> joinDirect(
    RoomDirectJoinBundle bundle, {
    String? localDisplayName,
  }) async {
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
      var saved = await _joinImporter.importGrant(
        grant,
        memberKeyPair: bundle.memberKeyPair,
      );
      final ownName = localDisplayName?.trim() ?? '';
      if (ownName.isNotEmpty) {
        // Display metadata only — this cannot and must not affect the
        // authorization the scanned certificate already established.
        saved = await _repository.updateMember(
          saved.room.id,
          bundle.memberId,
          displayName: ownName,
          pending: false,
        );
      }
      // Scanning is the receiver side of exactly this bootstrap hand-off. Keep
      // that fact separate from whatever durable invite rights the QR grants;
      // granting Add Person must never turn this phone into a second hotspot.
      _bootstrapRoleStore?.setRole(SessionRole.joiner);
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

  /// Brings an archived Room back into the list.
  ///
  /// Deliberately does not re-select it: coming back from the archive is a
  /// filing decision, and quietly repointing the Start action at a Room the
  /// user has not looked at in weeks is not what they asked for.
  Future<void> unarchive(RoomId roomId) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _repository.setArchived(roomId, false);
      await _reloadKeepingSelection();
    } catch (error) {
      emit(state.copyWith(loading: false, error: error));
    }
  }

  /// Removes a Room from this phone for good.
  ///
  /// The record and its invite ledger go first, then the transport key that
  /// belonged to it — same order as [leave], and the order matters: a key
  /// deleted before the record would leave a Room on screen that can no longer
  /// authenticate, which is a worse state than either end of the operation.
  ///
  /// This is local only. Nothing is told to the other phones, because there is
  /// nobody to tell — a Room is durable state each phone holds for itself, and
  /// deleting your copy is the same shape of act as deleting a saved contact.
  Future<void> deleteRoom(RoomId roomId) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final saved = await _repository.get(roomId);
      await _repository.delete(roomId);
      if (saved != null) {
        await _identityLifecycle.deleteLocalIdentity(saved);
      }
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
    final (rooms, archived) = await _partitioned();
    final selected = clearSelection ? null : await _repository.selectedRoomId();
    emit(
      RoomListState(rooms: rooms, archived: archived, selectedRoomId: selected),
    );
  }

  /// One read, split into live and put-away.
  ///
  /// Asking the repository twice would be two passes over storage for an
  /// answer it already has, and — worse — two reads that a write landing
  /// between them could disagree about.
  Future<(List<SavedRoom>, List<SavedRoom>)> _partitioned() async {
    final all = await _repository.list(includeArchived: true);
    return (
      [
        for (final saved in all)
          if (!saved.room.archived) saved,
      ],
      [
        for (final saved in all)
          if (saved.room.archived) saved,
      ],
    );
  }
}

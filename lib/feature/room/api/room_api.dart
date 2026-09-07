/// Public surface of the Room feature.
///
/// App composition and cooperating features may import this barrel instead of
/// reaching into Room domain/presentation internals directly.
library;

export '../domain/entity/held_seat_name.dart' show isHeldSeatPlaceholder;
export '../domain/entity/room.dart' show RoomMember, RoomMemberId, SavedRoom;
export '../domain/repository/room_repository.dart' show RoomRepository;
export '../domain/service/room_connection_coordinator.dart'
    show RoomConnectionCoordinator, RoomConnectionPhase, RoomConnectionState;
export '../domain/service/room_connection_readiness_gate.dart'
    show
        RoomConnectionReadinessFailureStage,
        RoomConnectionReadinessGate,
        RoomConnectionReadinessResult,
        RoomPeerProofEvidence;
export '../domain/service/room_transport_planner.dart'
    show RoomTransportCandidate, RoomTransportKind, RoomTransportPlan;
export '../domain/service/selected_room_live_session_binding.dart'
    show SelectedRoomLiveSessionBinding;
export '../domain/service/selected_room_lobby_resolver.dart'
    show SelectedRoomLobbyResolver;
export '../presentation/page/room_list_page.dart' show RoomListPage;
export '../presentation/page/room_manager_entry.dart' show RoomManagerEntry;
export '../presentation/page/room_qr_join_issuer_page.dart'
    show RoomQrJoinIssuerPage;
export '../presentation/page/room_qr_join_page.dart' show RoomQrJoinPage;
export '../presentation/room_member_display_name.dart' show roomMemberDisplayName;
export '../presentation/widget/in_room_people_action.dart' show InRoomPeopleAction;
export '../presentation/widget/room_connection_status_chip.dart'
    show RoomConnectionStatusChip;
export '../presentation/widget/room_connection_status_scope.dart'
    show RoomConnectionUiPhase;
export '../presentation/widget/selected_room_lobby.dart' show SelectedRoomLobby;

/// Public surface of the Room feature.
///
/// App composition may import this barrel; other features should navigate by
/// AppRoutes rather than importing Room presentation internals directly.
library;

export '../domain/entity/room.dart' show SavedRoom;
export '../domain/repository/room_repository.dart' show RoomRepository;
export '../domain/service/selected_room_live_session_binding.dart'
    show SelectedRoomLiveSessionBinding;
export '../domain/service/selected_room_lobby_resolver.dart'
    show SelectedRoomLobbyResolver;
export '../presentation/page/room_list_page.dart' show RoomListPage;
export '../presentation/page/room_qr_join_issuer_page.dart'
    show RoomQrJoinIssuerPage;
export '../presentation/page/room_qr_join_page.dart' show RoomQrJoinPage;
export '../presentation/widget/selected_room_lobby.dart' show SelectedRoomLobby;

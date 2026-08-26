/// Public surface of the Room feature.
///
/// App composition may import this barrel; other features should navigate by
/// AppRoutes rather than importing Room presentation internals directly.
library;

export '../domain/repository/room_repository.dart' show RoomRepository;
export '../domain/service/selected_room_live_session_binding.dart'
    show SelectedRoomLiveSessionBinding;
export '../presentation/page/room_list_page.dart' show RoomListPage;

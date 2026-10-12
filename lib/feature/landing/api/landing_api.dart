/// Public surface of the landing feature.
///
/// The app composition root (router) needs the page; other features reach
/// the landing screen via AppRoutes, never by importing it. The room entry
/// cards are shared so onboarding's last step offers Create and Join in the
/// exact shape the user will meet on Landing afterwards.
library;

export '../presentation/page/landing_page.dart';
export '../presentation/widget/room_entry_actions.dart'
    show RoomEntryAction, RoomEntryActions, RoomEntryVariant;

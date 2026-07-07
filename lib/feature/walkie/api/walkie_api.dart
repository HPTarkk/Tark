/// Public surface of the walkie feature.
///
/// Mostly the app composition root (router) needs anything from here; other
/// features reach the walkie screen via AppRoutes, never by importing it.
/// [WalkieTalkieCubit] is exported so the settings feature can accept an
/// already-running instance (threaded through go_router's `extra`) to edit a
/// live session's settings in place — see SettingsCubit.
library;

export '../presentation/manager/walkie_talkie_cubit.dart' show WalkieTalkieCubit, WalkieTalkieState;
export '../presentation/page/walkie_talkie_page.dart';

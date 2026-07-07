/// Public surface of the settings feature.
///
/// Only the app composition root (router) needs anything from here; other
/// features reach the settings screen via AppRoutes, never by importing it.
library;

export '../presentation/page/settings_page.dart';

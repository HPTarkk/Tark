/// Public surface of the walkie feature.
///
/// Only the app composition root (router) needs anything from here; other
/// features reach the walkie screen via AppRoutes, never by importing it.
library;

export '../presentation/page/walkie_talkie_page.dart';

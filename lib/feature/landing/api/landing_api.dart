/// Public surface of the landing feature.
///
/// Only the app composition root (router) needs anything from here; other
/// features reach the landing screen via AppRoutes, never by importing it.
library;

export '../presentation/page/landing_page.dart';

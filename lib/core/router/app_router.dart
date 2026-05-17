import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../feature/audio/presentation/page/recording_page.dart';
import '../../feature/transfer/presentation/widget/connection_wrapper.dart';

class AppRouter {
  static GoRouter? _router;

  static GoRouter get router {
    if (_router != null) return _router!;
    _router = _buildRoute();
    return _router!;
  }

  static GoRouter _buildRoute() => GoRouter(
    initialLocation: '/${RecordingPage.path}',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          child: ConnectionWrapper.wrapper(child: child),
        ),
        routes: [
          GoRoute(
            path: '/${RecordingPage.path}',
            name: RecordingPage.name,
            builder: (context, state) => RecordingPage.buildPage(),
          ),
        ],
      ),
    ],
  );
}

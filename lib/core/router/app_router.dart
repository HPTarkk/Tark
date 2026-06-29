import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../feature/landing/presentation/page/landing_page.dart';
import '../../feature/walkie/presentation/page/walkie_talkie_page.dart';

class AppRouter {
  static GoRouter? _router;

  static GoRouter get router {
    _router ??= _buildRoute();
    return _router!;
  }

  static GoRouter _buildRoute() => GoRouter(
        initialLocation: LandingPage.path,
        routes: [
          GoRoute(
            path: LandingPage.path,
            name: LandingPage.name,
            builder: (context, state) => LandingPage.buildPage(),
          ),
          GoRoute(
            path: '/${WalkieTalkiePage.path}',
            name: WalkieTalkiePage.name,
            pageBuilder: (context, state) => CustomTransitionPage(
              key: state.pageKey,
              child: WalkieTalkiePage.buildPage(),
              transitionDuration: const Duration(milliseconds: 500),
              reverseTransitionDuration: const Duration(milliseconds: 400),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                // Entering: slide up + fade in + slight scale up
                final enter = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                );
                // Leaving (popped): slide down + fade out
                final exit = CurvedAnimation(
                  parent: secondaryAnimation,
                  curve: Curves.easeInCubic,
                );
                return FadeTransition(
                  opacity: Tween<double>(begin: 0.0, end: 1.0).animate(enter),
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(enter),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.96, end: 1.0).animate(enter),
                      child: FadeTransition(
                        opacity:
                            Tween<double>(begin: 1.0, end: 0.0).animate(exit),
                        child: child,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/widget/edit_profile_chip.dart';

/// The channel screen's "Edit" opens Profile directly — not Settings — with
/// the live session threaded through, and back returns to the channel.
void main() {
  testWidgets('Edit opens Profile directly and back lands on the channel', (
    tester,
  ) async {
    final cubit = _StubWalkieCubit(WalkieTalkieState.initial());
    addTearDown(cubit.close);
    Object? profileExtra;
    var settingsOpened = false;

    final router = GoRouter(
      initialLocation: AppRoutes.walkiePath,
      routes: [
        GoRoute(
          path: AppRoutes.walkiePath,
          name: AppRoutes.walkieName,
          builder: (_, _) => BlocProvider<WalkieTalkieCubit>.value(
            value: cubit,
            child: const Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('channel-screen'), EditProfileChip()],
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.settingsPath,
          name: AppRoutes.settingsName,
          builder: (_, _) {
            settingsOpened = true;
            return const Scaffold(body: Text('settings-screen'));
          },
        ),
        GoRoute(
          path: AppRoutes.profilePath,
          name: AppRoutes.profileName,
          builder: (_, state) {
            profileExtra = state.extra;
            return const Scaffold(body: Text('profile-screen'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('fa'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('channel-edit-profile')));
    await tester.pumpAndSettle();

    expect(find.text('profile-screen'), findsOneWidget);
    expect(settingsOpened, isFalse);
    expect(profileExtra, same(cubit));

    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('channel-screen'), findsOneWidget);
    expect(find.text('profile-screen'), findsNothing);
  });
}

class _StubWalkieCubit extends Cubit<WalkieTalkieState>
    implements WalkieTalkieCubit {
  _StubWalkieCubit(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/feature/room/presentation/widget/room_visuals.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/widget/music_cast_section.dart';
import 'package:tark/feature/walkie/presentation/widget/user_list.dart';

/// The walkie screen redesign: member rows speak the Room lobby's language,
/// and the music cast folds to one findable row. Pinned at the narrowest
/// supported width, in Persian, at a large text scale.
void main() {
  tearDown(() async => GetIt.instance.reset());

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Locale locale = const Locale('fa'),
    WalkieTalkieState? state,
  }) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.35)),
          child: app!,
        ),
        home: BlocProvider<WalkieTalkieCubit>(
          create: (_) => _StubWalkieCubit(state ?? WalkieTalkieState.initial()),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a talking peer gets a tinted face and the TX mark', (
    tester,
  ) async {
    await pump(
      tester,
      Column(
        children: [
          UserTile(user: _user('a', 'یک نام خیلی خیلی طولانی برای راننده')),
          UserTile(user: _user('b', 'Rider B', talking: true)),
        ],
      ),
    );

    expect(find.byType(TintedAvatar), findsNWidgets(2));
    expect(find.byType(WaveformBars), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same peer keeps the same tint on every phone', (
    tester,
  ) async {
    expect(TintedAvatar.tintFor('peer-1'), TintedAvatar.tintFor('peer-1'));
  });

  group('music cast fold', () {
    setUp(() {
      GetIt.instance.registerSingleton<LicenseGate>(_OpenGate());
    });

    testWidgets('folds to one row and unfolds to the start button', (
      tester,
    ) async {
      final en = AppLocalizationsEn();
      await pump(
        tester,
        MusicCastSection(supportedForTest: Future<bool>.value(true)),
        locale: const Locale('en'),
      );
      await tester.pump();

      expect(find.text(en.music_cast), findsOneWidget);
      expect(find.text(en.music_cast_start), findsNothing);

      await tester.tap(find.byKey(const Key('music-cast-fold')));
      await tester.pumpAndSettle();
      expect(find.text(en.music_cast_start), findsOneWidget);

      await tester.tap(find.byKey(const Key('music-cast-fold')));
      await tester.pumpAndSettle();
      expect(find.text(en.music_cast_start), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stays open while a cast is starting', (tester) async {
      final en = AppLocalizationsEn();
      await pump(
        tester,
        MusicCastSection(supportedForTest: Future<bool>.value(true)),
        locale: const Locale('en'),
        state: WalkieTalkieState.initial().copyWith(
          isStartingSystemAudio: true,
        ),
      );
      await tester.pump();

      expect(find.text(en.music_cast_starting), findsOneWidget);
    });

    testWidgets('fits at 320px in Persian at 1.35x', (tester) async {
      await pump(
        tester,
        MusicCastSection(supportedForTest: Future<bool>.value(true)),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('music-cast-fold')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

ChannelUser _user(String id, String name, {bool talking = false}) =>
    ChannelUser(
      id: id,
      name: name,
      isTalking: talking,
      lastSeen: DateTime.utc(2026, 9, 25),
      role: SessionRole.host,
    );

class _OpenGate implements LicenseGate {
  @override
  bool allows(PremiumFeature feature) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubWalkieCubit extends Cubit<WalkieTalkieState>
    implements WalkieTalkieCubit {
  _StubWalkieCubit(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

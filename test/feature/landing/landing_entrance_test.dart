import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/tark_mark.dart';
import 'package:tark/feature/landing/presentation/manager/landing_cubit.dart';
import 'package:tark/feature/landing/presentation/page/landing_page.dart';
import 'package:tark/feature/landing/presentation/widget/landing_identity_card.dart';
import 'package:tark/feature/landing/presentation/widget/landing_logo.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

class _Landing extends Cubit<LandingState> implements LandingCubit {
  _Landing()
    : super(
        const LandingState(
          localIp: '',
          myName: 'Pedram',
          isLoading: false,
          transferMode: TransferMode.bluetooth,
          pinnedMode: null,
        ),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    GetIt.instance.registerFactory<LandingCubit>(_Landing.new);
    PackageInfo.setMockInitialValues(
      appName: 'Tark',
      packageName: 'tark',
      version: '1.1.0',
      buildNumber: '1',
      buildSignature: 'test',
    );
  });
  tearDown(() => GetIt.instance.reset());

  Future<void> frames(WidgetTester tester, int milliseconds) async {
    for (var elapsed = 0; elapsed < milliseconds; elapsed += 10) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  double entranceOpacity(WidgetTester tester, Finder child) => tester
      .widget<Opacity>(
        find.ancestor(of: child, matching: find.byType(Opacity)).last,
      )
      .opacity;

  Future<GlobalKey<NavigatorState>> start(
    WidgetTester tester, {
    bool reduced = false,
    Locale locale = const Locale('en'),
    double scale = 1,
  }) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduced,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: const Scaffold(body: Text('before')),
      ),
    );
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(seconds: 1),
        pageBuilder: (_, _, _) => LandingPage.buildPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
    return navigator;
  }

  testWidgets('the full logo entrance waits for the real route transition', (
    tester,
  ) async {
    final navigator = await start(tester);
    final logo = find.byType(LandingLogo);
    final identity = find.byType(LandingIdentityCard);
    await tester.pump(const Duration(milliseconds: 700));
    expect(entranceOpacity(tester, logo), 0);
    expect(entranceOpacity(tester, identity), 0);
    await frames(tester, 320);
    await tester.pump();
    await frames(tester, 350);
    expect(entranceOpacity(tester, logo), greaterThan(0.9));
    expect(entranceOpacity(tester, identity), 0);
    final first = tester.getCenter(find.byType(TarkMark)).dy;
    await frames(tester, 900);
    final docked = tester.getCenter(find.byType(TarkMark)).dy;
    expect(first - docked, greaterThan(80));
    expect(entranceOpacity(tester, identity), greaterThan(0));
    await tester.pump(const Duration(seconds: 1));
    expect(entranceOpacity(tester, identity), 1);
    // Returning from another page must not replay the Home entrance.
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covered')),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(entranceOpacity(tester, logo), 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion shows the content immediately after arrival', (
    tester,
  ) async {
    await start(tester, reduced: true);
    await frames(tester, 1020);
    await tester.pump();
    expect(entranceOpacity(tester, find.byType(LandingLogo)), 1);
    expect(entranceOpacity(tester, find.byType(LandingIdentityCard)), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('small Persian screen with large text can complete and scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start(tester, locale: const Locale('fa'), scale: 1.5);
    await frames(tester, 2850);
    expect(entranceOpacity(tester, find.byType(LandingIdentityCard)), 1);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disposing during arrival leaves no delayed entrance callback', (
    tester,
  ) async {
    final navigator = await start(tester);
    await tester.pump(const Duration(milliseconds: 200));
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(LandingPage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

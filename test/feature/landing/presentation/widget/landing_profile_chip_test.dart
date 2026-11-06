import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/profile_hero.dart';
import 'package:tark/feature/landing/presentation/manager/landing_cubit.dart';
import 'package:tark/feature/landing/presentation/widget/landing_profile_chip.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

/// Home's profile chip: who you are, in the corner, and the start of the
/// face-and-name flight into Profile.
void main() {
  const state = LandingState(
    localIp: '',
    myName: 'Pedram',
    isLoading: false,
    transferMode: TransferMode.bluetooth,
    pinnedMode: null,
  );

  Widget host({bool reduced = false, VoidCallback? onTap}) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: LandingProfileChip(state: state, onTap: onTap ?? () {}),
        ),
      ),
    ),
  );

  testWidgets('opens Profile and announces name and readiness', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(onTap: () => taps++));
    await tester.tap(find.byKey(const ValueKey('landing-identity')));
    expect(taps, 1);
    final label = tester
        .getSemantics(find.byKey(const ValueKey('landing-identity')))
        .label;
    expect(label, contains('Pedram'));
    expect(find.byKey(const ValueKey('landing-identity-status')), findsOne);
  });

  testWidgets('face and name are the heroes Profile receives', (tester) async {
    await tester.pumpWidget(host());
    final tags = tester
        .widgetList<Hero>(find.byWidgetPredicate((w) => w is Hero))
        .map((hero) => hero.tag)
        .toSet();
    expect(tags, {ProfileHero.avatarTag, ProfileHero.nameTag});
    for (final mode in tester.widgetList<HeroMode>(find.byType(HeroMode))) {
      expect(mode.enabled, isTrue);
    }
  });

  testWidgets('reduced motion keeps the chip but grounds the flight', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduced: true));
    final modes = tester.widgetList<HeroMode>(find.byType(HeroMode));
    expect(modes, isNotEmpty);
    for (final mode in modes) {
      expect(mode.enabled, isFalse);
    }
  });

  testWidgets('a long name stops short and the chip never overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LandingProfileChip(
            state: state.copyWith(myName: 'Alexandria-Konstantinople'),
            onTap: () {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // 320 less the two 12dp corner insets and the 48dp settings chip
    // leaves 248; the chip must stay clear of it with room to spare.
    expect(
      tester.getSize(find.byKey(const ValueKey('landing-identity'))).width,
      lessThanOrEqualTo(208),
    );
  });
}

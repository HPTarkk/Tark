import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/settings_icon_button.dart';
import 'package:tark/core/widget/tark_mark.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/transfer/domain/service/link_quality.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/widget/walkie_header.dart';

void main() {
  group('WalkieHeaderLayout', () {
    test('the mark is big enough to hold two lines up', () {
      // R31. It stood beside a single line at 28 and now heads a block; a mark
      // shorter than the text beside it reads as decoration on a title rather
      // than the head of one. The glyph is derived from the mark so the two
      // cannot drift when the next size change comes.
      expect(WalkieHeaderLayout.brandMark, greaterThan(28.0));
      expect(WalkieHeaderLayout.brandGlyph / WalkieHeaderLayout.brandMark, 0.5);
    });

    test('lands every row on the body column, whatever the control is', () {
      // A bare identity line owns no padding, so it sits on the margin.
      expect(WalkieHeaderLayout.inset(0), WalkieHeaderLayout.opticalMargin);

      // The compensated insets: what the bar pads, plus what the control
      // already carries, is the margin in every case.
      for (final controlInset in [
        WalkieHeaderLayout.iconButtonInset,
        WalkieHeaderLayout.settingsChipInset,
      ]) {
        expect(
          WalkieHeaderLayout.inset(controlInset) + controlInset,
          WalkieHeaderLayout.opticalMargin,
          reason:
              'a control carrying $controlInset must still draw its edge '
              'on the ${WalkieHeaderLayout.opticalMargin} column',
        );
      }

      // The regression this replaces: an IconButton row and a chip row given
      // the same number end up 4 apart on screen.
      expect(
        WalkieHeaderLayout.inset(WalkieHeaderLayout.iconButtonInset),
        isNot(WalkieHeaderLayout.inset(WalkieHeaderLayout.settingsChipInset)),
      );
    });

    test('never pushes a row past the margin for an over-padded control', () {
      expect(WalkieHeaderLayout.inset(40), 0);
      expect(WalkieHeaderLayout.inset(WalkieHeaderLayout.opticalMargin), 0);
    });
  });

  // The arithmetic above is only correct if the two controls really do carry
  // the padding it claims. These measure them against Flutter's own layout,
  // because both numbers are inherited rather than declared: `IconButton`'s
  // comes from the Material theme, and the settings chip's from a wrapper that
  // squeezes a 48dp control into the header's 40.
  group('WalkieHeader edge controls', () {
    const barKey = Key('bar');
    const barWidth = 360.0;

    Future<double> gapFromEnd(
      WidgetTester tester, {
      required double barInset,
      required Widget control,
      required Finder drawnEdge,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                key: barKey,
                width: barWidth,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(end: barInset),
                  child: Row(children: [const Spacer(), control]),
                ),
              ),
            ),
          ),
        ),
      );
      final bar = tester.getRect(find.byKey(barKey));
      return bar.right - tester.getRect(drawnEdge).right;
    }

    testWidgets('a bare icon button lands on the column, not 8 short of it', (
      tester,
    ) async {
      final gap = await gapFromEnd(
        tester,
        barInset: WalkieHeaderLayout.inset(WalkieHeaderLayout.iconButtonInset),
        control: IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: () {},
          icon: const Icon(Icons.groups_2_outlined),
        ),
        drawnEdge: find.byIcon(Icons.groups_2_outlined),
      );
      expect(gap, WalkieHeaderLayout.opticalMargin);
    });

    testWidgets('the settings chip lands on the same column', (tester) async {
      final gap = await gapFromEnd(
        tester,
        barInset: WalkieHeaderLayout.inset(
          WalkieHeaderLayout.settingsChipInset,
        ),
        control: SizedBox(
          width: 40,
          height: 40,
          child: SettingsIconButton(onTap: () {}),
        ),
        drawnEdge: find.descendant(
          of: find.byType(SettingsIconButton),
          matching: find.byType(Container),
        ),
      );
      expect(gap, WalkieHeaderLayout.opticalMargin);
    });
  });
  // The synthetic measurements above were all correct while the real header
  // was not, which is the whole reason this group exists: they pump one
  // control inside `Row(children: [Spacer(), control])`, and the fault was in
  // how the *rest* of the row competed for the same slack.
  //
  // A `Spacer` beside a `Flexible` title splits the free space between them,
  // and whatever the title does not use is left lying at the end of the row
  // rather than handed back — so the trailing controls drifted inward by an
  // amount that depended on the width and on how wide the wordmark happened to
  // be in that language. Persian at 430pt put the settings chip 37.5 from its
  // column instead of 16.
  group('WalkieHeader trailing controls', () {
    Future<void> pumpHeader(
      WidgetTester tester, {
      required Locale locale,
      required double width,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final repository = SharedPreferencesRoomRepository();
      final room = await repository.create(
        name: 'Friday night ride',
        localDisplayName: 'Pedram',
      );
      await repository.select(room.room.id);
      GetIt.instance.registerSingleton<RoomRepository>(repository);

      tester.view.physicalSize = Size(width, 400);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider<WalkieTalkieCubit>(
            create: (_) => _StubWalkieCubit(
              WalkieTalkieState.initial().copyWith(
                localId: '192.168.43.5',
                isReady: true,
                linkQuality: LinkQuality.good,
              ),
            ),
            child: const Scaffold(body: Column(children: [WalkieHeader()])),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    tearDown(() async {
      await GetIt.instance.reset();
    });

    // The room's code is what you say out loud mid-ride to get somebody in, so
    // it is the half that must survive. `Row` alone cannot say that: flex
    // shares are decided before anyone is measured, so any weighting that
    // saves the code on a narrow phone starves the name on a wide one.
    testWidgets('the name gives way to the code, not the other way', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpHeader(tester, locale: const Locale('en'), width: 430);
      final roomCode = find.textContaining('#');
      expect(roomCode, findsOneWidget);
      expect(find.text('Friday night ride'), findsOneWidget);

      // Squeezed until only one of them can be there. The code is still whole
      // — never ellipsized — and the name is gone rather than the two of them
      // sharing a space neither can use.
      await GetIt.instance.reset();
      await pumpHeader(tester, locale: const Locale('en'), width: 320);
      final code = tester.widget<Text>(find.textContaining('#'));
      expect(code.data, isNot(contains('…')));
      expect(find.text('Friday night ride'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final locale in [const Locale('en'), const Locale('fa')]) {
      for (final width in [320.0, 390.0, 430.0]) {
        final rtl = locale.languageCode == 'fa';
        testWidgets('trailing controls sit on the margin '
            '(${locale.languageCode} at ${width.toInt()})', (tester) async {
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await pumpHeader(tester, locale: locale, width: width);

          final chip = tester.getRect(
            find
                .descendant(
                  of: find.byType(SettingsIconButton),
                  matching: find.byType(Container),
                )
                .first,
          );
          // The drawn edge of the chip, on whichever side is trailing.
          final chipGap = rtl ? chip.left : width - chip.right;
          expect(
            chipGap,
            WalkieHeaderLayout.opticalMargin,
            reason: 'settings chip drifted off the body column',
          );

          // R32. Adding someone happens once a ride at most, and it was
          // holding the trailing edge of the screen a rider looks at for the
          // whole trip. It lives in the members card now.
          expect(find.byKey(const Key('in-room-add-rider')), findsNothing);

          // R31. The room line begins exactly under the app name — one block
          // beside one mark, sharing a left edge structurally rather than by
          // an indent constant that was one edit away from drifting.
          final wordmark = tester.getRect(
            find.text(
              AppLocalizations.of(
                tester.element(find.byType(WalkieHeader)),
              )!.app_name,
            ),
          );
          final roomLine = tester.getRect(
            find.byKey(const Key('ride-room-identity')),
          );
          expect(
            rtl ? wordmark.right : wordmark.left,
            rtl ? roomLine.right : roomLine.left,
            reason: 'the room must begin exactly under the app name',
          );

          // Both lines are the leading and nothing else. A control taller
          // than the text on the wordmark's line turns every pixel of its
          // extra height into space under the wordmark, which is what put
          // eleven pixels between two lines that are one thing.
          expect(
            roomLine.top - wordmark.bottom,
            lessThanOrEqualTo(4.0),
            reason: 'the room line drifted away from the wordmark',
          );

          // The mark and both controls share one centre line — the mark
          // because it belongs to both text lines, the controls because a row
          // is what the eye expects at this edge. This is the whole reason
          // nothing taller than the text is allowed inside the column.
          final mark = tester.getRect(find.byType(TarkMark));
          final bars = tester.getRect(find.byType(LinkQualityBars));
          for (final control in {'link': bars, 'settings': chip}.entries) {
            expect(
              control.value.center.dy,
              closeTo(mark.center.dy, 0.5),
              reason: '${control.key} left the header centre line',
            );
          }
          expect(
            rtl ? mark.left > roomLine.right : mark.right < roomLine.left,
            isTrue,
            reason: 'the mark leads the identity block',
          );

          // A header that overflows paints outside its box with nothing on
          // screen to say so, which is how the identity line shipped.
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

class _StubWalkieCubit extends Cubit<WalkieTalkieState>
    implements WalkieTalkieCubit {
  _StubWalkieCubit(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_carrier.dart';
import 'package:tark/feature/room/domain/service/room_carrier_promotion_controller.dart';
import 'package:tark/feature/room/presentation/widget/carrier_handover_note.dart';
import 'package:tark/feature/room/presentation/widget/carrier_status_scope.dart';

/// The carrier handover is invisible machinery with exactly one visible
/// surface, so what that surface says — and, far more often, does not say — is
/// the whole user-facing contract.
///
/// Driven through [RoomCarrierStatusSource] rather than the real controller:
/// the widget's entire dependency is two properties, and pulling a hotspot
/// radio, a signing key and a three-second timer into a rendering test would
/// test none of what is on screen.
void main() {
  final hostMember = RoomMemberId('b' * 24);

  Future<void> pump(
    WidgetTester tester,
    RoomCarrierStatusSource? source, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        // The app's own delegate, not just the Material ones: these screens
        // read their copy from [AppLocalizations] now rather than switching
        // on the locale themselves, so a harness without it has no strings.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: CarrierStatusScope(
            controller: source,
            child: const CarrierHandoverNote(),
          ),
        ),
      ),
    );
    // Three frames, not one: the note crossfades, and AnimatedSwitcher keeps
    // the outgoing child mounted for the length of the transition. A single
    // pump would find both notes on screen at once. Bounded rather than
    // pumpAndSettle because the busy variant spins forever by design.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  _FakeStatusSource sourceAt(
    RoomCarrierStage stage, {
    bool localIsHost = false,
    RoomCarrierDurability durability = RoomCarrierDurability.borrowed,
  }) => _FakeStatusSource(
    RoomCarrierStatus(
      stage: stage,
      durability: durability,
      generation: 1,
      hostMemberId: hostMember,
      localIsHost: localIsHost,
    ),
  );

  testWidgets('says nothing at all when there is no handover machinery', (
    tester,
  ) async {
    // Bluetooth, the guest link, a device with no signing material. Absent is
    // not the same as settled, and reassurance we cannot back up is worse than
    // silence.
    await pump(tester, null);
    expect(find.byKey(const Key('carrier-handover-note')), findsNothing);
  });

  testWidgets('says nothing on a phone that is simply along for the ride', (
    tester,
  ) async {
    await pump(
      tester,
      sourceAt(
        RoomCarrierStage.settled,
        durability: RoomCarrierDurability.owned,
      ),
    );
    expect(find.byKey(const Key('carrier-handover-note')), findsNothing);
  });

  testWidgets('explains the move in plain language while it happens', (
    tester,
  ) async {
    await pump(tester, sourceAt(RoomCarrierStage.raising, localIsHost: true));

    expect(find.byKey(const Key('carrier-handover-note')), findsOneWidget);
    expect(find.textContaining('stay connected'), findsOneWidget);
  });

  testWidgets('never uses a word a rider would have to look up', (
    tester,
  ) async {
    // The user's own brief: they should be able to use this knowing nothing
    // about networking. Every stage gets checked, because it only takes one
    // to break the promise.
    for (final stage in RoomCarrierStage.values) {
      for (final localIsHost in const [true, false]) {
        await pump(tester, sourceAt(stage, localIsHost: localIsHost));
        for (final jargon in const [
          'Wi-Fi',
          'WiFi',
          'hotspot',
          'network',
          'SSID',
          'transport',
          'access point',
          'carrier',
        ]) {
          expect(
            find.textContaining(jargon),
            findsNothing,
            reason:
                '"$jargon" reached the screen in $stage '
                '(localIsHost: $localIsHost)',
          );
        }
      }
    }
  });

  testWidgets('a follower is told to wait, without being told why', (
    tester,
  ) async {
    await pump(tester, sourceAt(RoomCarrierStage.awaitingHost));
    expect(find.textContaining('One moment'), findsOneWidget);
  });

  testWidgets('tells the hub phone it has given up its internet', (
    tester,
  ) async {
    // The one standing fact worth carrying past the handover: this phone is
    // offline until the room closes, and whoever is holding it should not have
    // to discover that when a message fails to send.
    await pump(
      tester,
      sourceAt(
        RoomCarrierStage.settled,
        localIsHost: true,
        durability: RoomCarrierDurability.owned,
      ),
    );
    expect(find.textContaining('off the internet'), findsOneWidget);
  });

  testWidgets('the standing note is calm, and the in-flight one is busy', (
    tester,
  ) async {
    // A spinner says "wait"; a settled fact must not, or the room looks like it
    // is permanently mid-repair.
    await pump(tester, sourceAt(RoomCarrierStage.raising, localIsHost: true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.cell_tower_rounded), findsNothing);

    // Torn down between the two, rather than swapped: the note crossfades, so
    // swapping in place leaves the outgoing spinner mounted for the length of
    // the transition and the assertion would be racing it.
    await pump(tester, null);
    await pump(
      tester,
      sourceAt(
        RoomCarrierStage.settled,
        localIsHost: true,
        durability: RoomCarrierDurability.owned,
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.cell_tower_rounded), findsOneWidget);
  });

  testWidgets('a status arriving on the stream updates what is on screen', (
    tester,
  ) async {
    final source = sourceAt(
      RoomCarrierStage.settled,
      durability: RoomCarrierDurability.owned,
    );
    await pump(tester, source);
    expect(find.byKey(const Key('carrier-handover-note')), findsNothing);

    source.emit(
      const RoomCarrierStatus(
        stage: RoomCarrierStage.raising,
        durability: RoomCarrierDurability.borrowed,
        generation: 1,
        localIsHost: true,
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.byKey(const Key('carrier-handover-note')), findsOneWidget);
    addTearDown(source.dispose);
  });

  testWidgets('Persian says it in Persian rather than borrowing English', (
    tester,
  ) async {
    await pump(
      tester,
      sourceAt(RoomCarrierStage.raising, localIsHost: true),
      locale: const Locale('fa'),
    );
    expect(find.textContaining('ارتباط'), findsOneWidget);
  });
}

class _FakeStatusSource implements RoomCarrierStatusSource {
  _FakeStatusSource(this._status);

  RoomCarrierStatus _status;
  final _controller = StreamController<RoomCarrierStatus>.broadcast();

  @override
  RoomCarrierStatus get status => _status;

  @override
  Stream<RoomCarrierStatus> get statusChanges => _controller.stream;

  void emit(RoomCarrierStatus status) {
    _status = status;
    _controller.add(status);
  }

  void dispose() => _controller.close();
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_carrier.dart';
import 'package:tark/feature/room/domain/service/room_carrier_promotion_controller.dart';
import 'package:tark/feature/room/presentation/widget/carrier_move_scene.dart';
import 'package:tark/feature/room/presentation/widget/carrier_status_scope.dart';

void main() {
  final host = RoomMemberId('b' * 24);
  final scene = find.byKey(const Key('carrier-move-scene'));

  RoomCarrierStatus status(
    RoomCarrierStage stage, {
    RoomCarrierDurability durability = RoomCarrierDurability.borrowed,
    RoomCarrierMoveFailure? failure,
    int generation = 1,
  }) => RoomCarrierStatus(
    stage: stage,
    durability: durability,
    generation: generation,
    hostMemberId: host,
    failure: failure,
  );

  Future<_Source> pump(WidgetTester tester) async {
    final source = _Source(status(RoomCarrierStage.settled));
    addTearDown(source.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: CarrierStatusScope(
            controller: source,
            child: const CarrierMoveScene(child: Text('the call')),
          ),
        ),
      ),
    );
    return source;
  }

  testWidgets('a move opens over the call and folds back once it lands', (
    tester,
  ) async {
    final source = await pump(tester);
    expect(scene, findsNothing);

    source.emit(status(RoomCarrierStage.awaitingHost));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(scene, findsOneWidget);
    expect(find.text('Getting the room ready for the road'), findsOneWidget);

    source.emit(
      status(RoomCarrierStage.settled, durability: RoomCarrierDurability.owned),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Ready for the road'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(scene, findsNothing);
    expect(find.text('the call'), findsOneWidget);
  });

  testWidgets('it can be put away, and stays away for that move', (
    tester,
  ) async {
    final source = await pump(tester);
    source.emit(status(RoomCarrierStage.awaitingHost));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('carrier-move-hide')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(scene, findsNothing);

    source.emit(status(RoomCarrierStage.moving));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(scene, findsNothing);
  });

  testWidgets('a move that does not happen folds away without a word', (
    tester,
  ) async {
    final source = await pump(tester);
    source.emit(status(RoomCarrierStage.awaitingHost));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    source.emit(
      status(
        RoomCarrierStage.settled,
        failure: RoomCarrierMoveFailure.timedOut,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(scene, findsNothing);
  });
}

class _Source implements RoomCarrierStatusSource {
  _Source(this._status);

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

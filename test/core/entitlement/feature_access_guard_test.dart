import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/feature_access_guard.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';

void main() {
  late _Gate gate;
  setUp(() {
    gate = _Gate();
    GetIt.instance.registerSingleton<LicenseGate>(gate);
  });
  tearDown(() async {
    await GetIt.instance.reset();
    await gate.controller.close();
  });

  testWidgets(
    'camera construction waits for purchase return, not just a state notification',
    (tester) async {
      final access = Completer<bool>();
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureAccessGuard(
            feature: PremiumFeature.wifiTransport,
            requestAccess: (_, _) => access.future,
            onDenied: () => fail('unexpected cancellation'),
            builder: (_) {
              builds++;
              return const Text('camera');
            },
          ),
        ),
      );
      expect(builds, 0);
      gate.setAllowed(true);
      await tester.pump();
      expect(
        builds,
        0,
        reason: 'the purchase screen still owns the foreground',
      );
      access.complete(true);
      await tester.pump();
      expect(find.text('camera'), findsOneWidget);
      expect(builds, 1);
    },
  );

  for (final reportedGrant in [false, true]) {
    testWidgets(
      'denied access never creates the scanner (reported grant: $reportedGrant)',
      (tester) async {
        var denied = 0;
        var builds = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: FeatureAccessGuard(
              feature: PremiumFeature.wifiTransport,
              requestAccess: (_, _) async => reportedGrant,
              onDenied: () => denied++,
              builder: (_) {
                builds++;
                return const Text('camera');
              },
            ),
          ),
        );
        await tester.pump();
        expect(builds, 0);
        expect(denied, 1);
      },
    );
  }

  testWidgets('unlocked build enters without a subscription prompt', (
    tester,
  ) async {
    gate.allowed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: FeatureAccessGuard(
          feature: PremiumFeature.wifiTransport,
          requestAccess: (_, _) async => throw StateError('should not prompt'),
          onDenied: () => fail('unexpected cancellation'),
          builder: (_) => const Text('camera'),
        ),
      ),
    );
    expect(find.text('camera'), findsOneWidget);
  });

  testWidgets(
    'revocation removes the scanner and cancels its pending connection before prompting',
    (tester) async {
      gate.allowed = true;
      var lost = 0;
      final access = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureAccessGuard(
            feature: PremiumFeature.wifiTransport,
            requestAccess: (_, _) => access.future,
            onAccessLost: () => lost++,
            onDenied: () {},
            builder: (_) => const Text('camera'),
          ),
        ),
      );
      gate.setAllowed(false);
      await tester.pump();
      expect(lost, 1);
      expect(find.text('camera'), findsNothing);
      access.complete(false);
      await tester.pump();
    },
  );
}

class _Gate implements LicenseGate {
  bool allowed = false;
  final controller = StreamController<void>.broadcast(sync: true);
  void setAllowed(bool value) {
    allowed = value;
    controller.add(null);
  }

  @override
  bool allows(PremiumFeature feature) => allowed;
  @override
  bool get canPurchase => true;
  @override
  Stream<void> get changes => controller.stream;
}

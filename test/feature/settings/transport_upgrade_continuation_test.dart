import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/billing_service.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/plan_catalog.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/entitlement/subscription_service.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/settings/presentation/widget/transport_mode_picker.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  late _Gate gate;
  late _Store store;
  late _Subscription subscription;

  setUp(() {
    gate = _Gate();
    store = _Store();
    subscription = _Subscription();
    GetIt.instance
      ..registerSingleton<LicenseGate>(gate)
      ..registerSingleton<TransferModeStore>(store)
      ..registerSingleton<SubscriptionService>(subscription)
      ..registerSingleton<BillingService>(const UnavailableBillingService())
      ..registerSingleton<PlanCatalog>(_Plans());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await gate.controller.close();
    await store.controller.close();
  });

  Future<void> openLockedWifi(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(body: TransportModePicker()),
      ),
    );
    final context = tester.element(find.byType(TransportModePicker));
    await tester.tap(
      find.text(AppLocalizations.of(context)!.transport_wifi_hotspot),
    );
    await tester.pump();
    expect(store.writes, isEmpty);
  }

  testWidgets('unlock resumes the originally selected transport once', (
    tester,
  ) async {
    await openLockedWifi(tester);
    gate.allowed = true;
    gate.controller.add(null);
    subscription.answer.complete(const GateGranted());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(store.writes, [TransferMode.wifi]);
    expect(store.pinnedMode, TransferMode.wifi);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'choosing the free alternative selects Bluetooth, never the paid transport',
    (tester) async {
      await openLockedWifi(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('paywall-free-bluetooth')));
      subscription.answer.complete(const GateSignInRequired());
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(store.writes, [TransferMode.bluetooth]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing the upgrade leaves the transport untouched', (
    tester,
  ) async {
    await openLockedWifi(tester);
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop(false);
    subscription.answer.complete(const GateSignInRequired());
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(store.writes, isEmpty);
    expect(store.pinnedMode, isNull);
    expect(tester.takeException(), isNull);
  });
}

class _Gate implements LicenseGate {
  bool allowed = false;
  final controller = StreamController<void>.broadcast();
  @override
  bool allows(PremiumFeature feature) => allowed;
  @override
  bool get canPurchase => true;
  @override
  Stream<void> get changes => controller.stream;
}

class _Store implements TransferModeStore {
  final writes = <TransferMode?>[];
  final controller = StreamController<TransferMode?>.broadcast();
  @override
  TransferMode mode = TransferMode.bluetooth;
  @override
  TransferMode? pinnedMode;
  @override
  Stream<TransferMode> get modeChanges => const Stream.empty();
  @override
  Stream<TransferMode?> get pinChanges => controller.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> setMode(TransferMode value) async => mode = value;
  @override
  Future<void> setPinnedMode(TransferMode? value) async {
    writes.add(value);
    pinnedMode = value;
    controller.add(value);
  }
}

class _Subscription implements SubscriptionService {
  final answer = Completer<GateOutcome>();
  @override
  Future<GateOutcome> check() => answer.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Plans implements PlanCatalog {
  @override
  Future<List<BillingPlan>> load() async => const [];
}

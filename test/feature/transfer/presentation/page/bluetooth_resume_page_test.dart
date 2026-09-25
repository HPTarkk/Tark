import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/analytics/analytics.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/sfx/sfx_player.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_connection_state.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_role.dart';
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart';
import 'package:tark/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart';
import 'package:tark/feature/transfer/presentation/page/bluetooth_resume_page.dart';

class _Transport implements BluetoothTransport {
  @override
  Stream<BluetoothConnectionState> get connectionState => const Stream.empty();

  @override
  Stream<bool> get bleAdvertising => const Stream.empty();

  @override
  void reset() {}

  @override
  void cancelDiscovery() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements SettingsRepository {
  @override
  Future<String> getMyName() async => 'Me';

  @override
  Future<String?> getLastBluetoothPeerId() async => null;

  @override
  Future<String?> getLastBluetoothPeerName() async => null;

  // The real resume never runs here; the fake cubit decides instead.
  @override
  Future<bool> getAutoReconnectEnabled() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sfx implements SfxPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

class _Analytics implements Analytics {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

/// The real cubit with the resume decision and the link driven by the test.
class _Cubit extends BluetoothConnectCubit {
  _Cubit(this.started) : super(_Transport(), _Settings(), _Sfx(), _Analytics());

  final Completer<bool> started;
  int resets = 0;

  @override
  Future<bool> get autoResume => started.future;

  void push(BluetoothConnectState s) => emit(s);

  @override
  void backToRoleSelection() {
    resets++;
    super.backToRoleSelection();
  }
}

void main() {
  final getIt = GetIt.instance;
  late Completer<bool> started;
  late _Cubit cubit;

  setUp(() {
    getIt.registerFactory<BluetoothConnectCubit>(() => cubit = _Cubit(started));
  });

  tearDown(() => getIt.reset());

  Future<void> pumpPage(WidgetTester tester) async {
    // Created inside the test body so its completion runs in the fake-async
    // zone that `pump` drives.
    started = Completer<bool>();
    final router = GoRouter(
      initialLocation: AppRoutes.bluetoothResumePath,
      routes: [
        GoRoute(
          path: AppRoutes.landingPath,
          name: AppRoutes.landingName,
          builder: (_, _) => const Scaffold(body: Text('LANDING')),
        ),
        GoRoute(
          path: AppRoutes.walkiePath,
          name: AppRoutes.walkieName,
          builder: (_, state) =>
              Scaffold(body: Text('WALKIE ${state.uri.query}')),
        ),
        GoRoute(
          path: AppRoutes.bluetoothResumePath,
          builder: (_, _) => BluetoothResumePage.buildPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pump();
  }

  BluetoothConnectState joining() => BluetoothConnectState.initial().copyWith(
    role: BluetoothRole.joiner,
    connectionState: BluetoothConnectionState.connecting,
    lastPeer: const BluetoothPeer(id: 'aa', name: 'Sara', isAppHost: true),
  );

  testWidgets('steps aside to Landing when nothing is resumed', (tester) async {
    await pumpPage(tester);
    started.complete(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('LANDING'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('connects, then asks before entering the channel', (
    tester,
  ) async {
    await pumpPage(tester);
    cubit.push(joining());
    started.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Looking for Sara...'), findsOneWidget);

    cubit.push(
      joining().copyWith(connectionState: BluetoothConnectionState.connected),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Connected to Sara'), findsOneWidget);
    expect(find.text('Go to the channel now?'), findsOneWidget);
    expect(find.text('WALKIE ride=true'), findsNothing);

    await tester.tap(find.text('ENTER CHANNEL'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('WALKIE ride=true'), findsOneWidget);
    expect(cubit.resets, 0);
  });

  testWidgets('Not now closes the link and goes to Landing', (tester) async {
    await pumpPage(tester);
    cubit.push(joining());
    started.complete(true);
    await tester.pump();
    cubit.push(
      joining().copyWith(connectionState: BluetoothConnectionState.connected),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.text('NOT NOW'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('LANDING'), findsOneWidget);
    expect(cubit.resets, 1);
  });

  testWidgets('Cancel stops the search and goes to Landing', (tester) async {
    await pumpPage(tester);
    cubit.push(joining());
    started.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('NEVER MIND'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('LANDING'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(cubit.resets, 1);
  });

  testWidgets('gives up after 30 seconds with a note', (tester) async {
    await pumpPage(tester);
    cubit.push(joining());
    started.complete(true);
    await tester.pump();

    await tester.pump(const Duration(seconds: 29));
    expect(find.text('LANDING'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('LANDING'), findsOneWidget);
    expect(
      find.textContaining("Couldn't reach the other phone"),
      findsOneWidget,
    );
    expect(cubit.resets, 1);
  });
}

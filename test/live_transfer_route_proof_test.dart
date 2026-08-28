import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/core/error/failure.dart';
import 'package:tark/feature/transfer/data/repository/live_transfer_repository.dart';
import 'package:tark/feature/transfer/domain/entity/audio_profile.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/entity/transport_route_proof_observation.dart';
import 'package:tark/feature/transfer/domain/entity/transport_stats.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/repository/transport_route_proof_exchange.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

void main() {
  late _ModeStore modes;
  late _ProofTransfer wifi;
  late _ProofTransfer bluetooth;
  late _ProofTransfer guest;
  late LiveTransferRepository subject;

  setUp(() {
    modes = _ModeStore(TransferMode.wifi);
    wifi = _ProofTransfer();
    bluetooth = _ProofTransfer();
    guest = _ProofTransfer();
    subject = LiveTransferRepository(
      modeStore: modes,
      wifi: wifi,
      bluetooth: bluetooth,
      guest: guest,
    );
  });

  tearDown(() {
    subject.dispose();
    modes.dispose();
    wifi.disposeControllers();
    bluetooth.disposeControllers();
    guest.disposeControllers();
  });

  test('route proof observations follow only the active transport', () async {
    final observed = <TransportRouteProofObservation>[];
    final subscription = subject.routeProofObservations.listen(observed.add);

    wifi.emitProof(_proof('wifi-route', 1));
    await _flush();
    expect(observed.map((value) => value.peerKey), ['wifi-route']);

    await modes.setMode(TransferMode.guest);
    await _flush();

    wifi.emitProof(_proof('stale-wifi-route', 2));
    guest.emitProof(_proof('guest-route', 3));
    await _flush();

    expect(observed.map((value) => value.peerKey), [
      'wifi-route',
      'guest-route',
    ]);
    await subscription.cancel();
  });

  test('route proof provider moves to replacement and leaves stale transport', () async {
    Future<String?> provider({
      required int token,
      required int challengeEpoch,
    }) async => 'proof-$token-$challengeEpoch';

    subject.routeProofObservations.listen((_) {});
    subject.setRouteProofProvider(provider);
    expect(wifi.routeProofProvider, same(provider));

    await modes.setMode(TransferMode.bluetooth);
    await _flush();

    expect(wifi.routeProofProvider, isNull);
    expect(bluetooth.routeProofProvider, same(provider));
    expect(guest.routeProofProvider, isNull);
  });

  test('rapid replacements cannot restore proof provider on stale transport', () async {
    Future<String?> provider({
      required int token,
      required int challengeEpoch,
    }) async => 'proof';

    final observed = <TransportRouteProofObservation>[];
    subject.routeProofObservations.listen(observed.add);
    subject.setRouteProofProvider(provider);

    await modes.setMode(TransferMode.guest);
    await modes.setMode(TransferMode.bluetooth);
    await _flush();

    expect(wifi.routeProofProvider, isNull);
    expect(guest.routeProofProvider, isNull);
    expect(bluetooth.routeProofProvider, same(provider));

    guest.emitProof(_proof('stale-guest-route', 4));
    bluetooth.emitProof(_proof('bluetooth-route', 5));
    await _flush();

    expect(observed.map((value) => value.peerKey), ['bluetooth-route']);
  });

  test('session stop removes proof provider from active transport', () async {
    Future<String?> provider({
      required int token,
      required int challengeEpoch,
    }) async => 'proof';

    subject.setRouteProofProvider(provider);
    expect(wifi.routeProofProvider, same(provider));

    subject.stopConnection();
    await _flush();

    expect(wifi.routeProofProvider, isNull);
    expect(wifi.stopCalls, 1);
  });
}

TransportRouteProofObservation _proof(String peerKey, int token) =>
    TransportRouteProofObservation(
      peerKey: peerKey,
      token: token,
      challengeEpoch: 7,
      encodedProof: 'opaque-$token',
      observedAt: DateTime.utc(2026, 8, 28),
    );

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _ModeStore implements TransferModeStore {
  _ModeStore(this._mode);

  TransferMode _mode;
  final _changes = StreamController<TransferMode>.broadcast(sync: true);
  final _pins = StreamController<TransferMode?>.broadcast(sync: true);
  TransferMode? _pinned;

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _changes.stream;

  @override
  TransferMode? get pinnedMode => _pinned;

  @override
  Stream<TransferMode?> get pinChanges => _pins.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    _changes.add(mode);
  }

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {
    _pinned = mode;
    _pins.add(mode);
    if (mode != null) await setMode(mode);
  }

  void dispose() {
    unawaited(_changes.close());
    unawaited(_pins.close());
  }
}

final class _ProofTransfer implements TransferRepository, TransportRouteProofExchange {
  int stopCalls = 0;
  TransportRouteProofProvider? routeProofProvider;

  final _packets = StreamController<WakiPacket>.broadcast();
  final _health = StreamController<ConnectionHealth>.broadcast();
  final _proofs = StreamController<TransportRouteProofObservation>.broadcast();

  void emitProof(TransportRouteProofObservation observation) {
    _proofs.add(observation);
  }

  @override
  Stream<TransportRouteProofObservation> get routeProofObservations =>
      _proofs.stream;

  @override
  void setRouteProofProvider(TransportRouteProofProvider? provider) {
    routeProofProvider = provider;
  }

  @override
  Stream<WakiPacket> startListening() => _packets.stream;

  @override
  Stream<ConnectionHealth> connect() => _health.stream;

  @override
  AudioFormatProfile get negotiatedFormat => AudioFormatProfile.legacy16k;

  @override
  AudioFormatProfile? get negotiatedMediaFormat => null;

  @override
  SessionRole get sessionRole => SessionRole.unknown;

  @override
  TransportStats get stats => TransportStats.none;

  @override
  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  ) async => const Right<Failure, void>(null);

  @override
  Future<Either<Failure, void>> sendMedia(
    List<double> samples,
    String senderName,
  ) async => const Right<Failure, void>(null);

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) async => const Right<Failure, void>(null);

  @override
  void setAudioProfile(AudioProfile profile) {}

  @override
  void setAutoReconnectEnabled(bool enabled) {}

  @override
  void retryNow() {}

  @override
  void resetCodecState() {}

  @override
  void repairSendPath() {}

  @override
  void stopConnection() {
    stopCalls += 1;
  }

  @override
  void dispose() {}

  void disposeControllers() {
    unawaited(_packets.close());
    unawaited(_health.close());
    unawaited(_proofs.close());
  }
}

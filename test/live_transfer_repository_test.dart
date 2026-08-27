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
import 'package:tark/feature/transfer/domain/entity/transport_capability_advertisement.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_observation.dart';
import 'package:tark/feature/transfer/domain/entity/transport_stats.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/repository/transport_capability_observation_source.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

void main() {
  late _ModeStore modes;
  late _FakeTransfer wifi;
  late _FakeTransfer bluetooth;
  late _FakeTransfer guest;
  late LiveTransferRepository subject;

  setUp(() {
    modes = _ModeStore(TransferMode.wifi);
    wifi = _FakeTransfer();
    bluetooth = _FakeTransfer();
    guest = _FakeTransfer();
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

  test(
    'live sends follow a mode change without rebuilding the Cubit',
    () async {
      await subject.sendAudio(const [0.1], 'Rider');
      expect(wifi.audioSends, 1);
      expect(bluetooth.audioSends, 0);

      await modes.setMode(TransferMode.bluetooth);
      await subject.sendAudio(const [0.2], 'Rider');

      expect(wifi.stopCalls, 1);
      expect(wifi.audioSends, 1);
      expect(bluetooth.audioSends, 1);
    },
  );

  test('wifi to hotspot keeps the same live transport attachment', () async {
    subject.startListening();
    subject.connect();
    expect(wifi.listenStarts, 1);
    expect(wifi.connectStarts, 1);

    await modes.setMode(TransferMode.hotspot);
    await _flush();

    expect(wifi.stopCalls, 0);
    expect(wifi.listenStarts, 1);
    expect(wifi.connectStarts, 1);
  });

  test('consumed packet and health streams rebind to replacement', () async {
    subject.startListening();
    subject.connect();

    await modes.setMode(TransferMode.guest);
    await _flush();

    expect(wifi.stopCalls, 1);
    expect(guest.listenStarts, 1);
    expect(guest.connectStarts, 1);
  });

  test('verified capability observations follow active transport', () async {
    final observed = <TransportCapabilityObservation>[];
    final subscription = subject.transportCapabilityObservations.listen(
      observed.add,
    );

    wifi.emitCapability(_observation('wifi-route'));
    await _flush();
    expect(observed.map((value) => value.peerKey), ['wifi-route']);

    await modes.setMode(TransferMode.guest);
    await _flush();

    wifi.emitCapability(_observation('stale-wifi-route'));
    guest.emitCapability(_observation('guest-route'));
    await _flush();

    expect(observed.map((value) => value.peerKey), [
      'wifi-route',
      'guest-route',
    ]);
    await subscription.cancel();
  });

  test('wifi to hotspot keeps capability evidence on same source', () async {
    final observed = <TransportCapabilityObservation>[];
    final subscription = subject.transportCapabilityObservations.listen(
      observed.add,
    );

    await modes.setMode(TransferMode.hotspot);
    wifi.emitCapability(_observation('same-wifi-route'));
    await _flush();

    expect(wifi.stopCalls, 0);
    expect(observed.single.peerKey, 'same-wifi-route');
    await subscription.cancel();
  });

  test('rapid replacements cannot attach an older repository last', () async {
    subject.startListening();
    subject.connect();
    final observed = <TransportCapabilityObservation>[];
    final subscription = subject.transportCapabilityObservations.listen(
      observed.add,
    );

    await modes.setMode(TransferMode.guest);
    await modes.setMode(TransferMode.bluetooth);
    await _flush();

    await subject.sendAudio(const [0.3], 'Rider');
    guest.emitCapability(_observation('stale-guest-route'));
    bluetooth.emitCapability(_observation('bluetooth-route'));
    await _flush();

    expect(bluetooth.audioSends, 1);
    expect(guest.audioSends, 0);
    expect(bluetooth.listenStarts, 1);
    expect(bluetooth.connectStarts, 1);
    expect(observed.map((value) => value.peerKey), ['bluetooth-route']);
    await subscription.cancel();
  });

  test(
    'session stop releases wrapper ownership, not concrete singleton',
    () async {
      subject.startListening();
      subject.connect();
      subject.transportCapabilityObservations.listen((_) {});

      subject.stopConnection();
      await _flush();

      expect(wifi.stopCalls, 1);
      expect(wifi.disposeCalls, 0);

      await modes.setMode(TransferMode.bluetooth);
      await _flush();

      expect(bluetooth.listenStarts, 0);
      expect(bluetooth.connectStarts, 0);
      expect(wifi.stopCalls, 1);
    },
  );
}

TransportCapabilityObservation _observation(String peerKey) =>
    TransportCapabilityObservation(
      peerKey: peerKey,
      capability: const TransportCapabilityAdvertisement(
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 80,
      ),
      observedAt: DateTime.utc(2026, 8, 27),
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

final class _FakeTransfer
    implements TransferRepository, TransportCapabilityObservationSource {
  int audioSends = 0;
  int stopCalls = 0;
  int listenStarts = 0;
  int connectStarts = 0;
  int disposeCalls = 0;

  final _packets = StreamController<WakiPacket>.broadcast();
  final _health = StreamController<ConnectionHealth>.broadcast();
  final _capabilities =
      StreamController<TransportCapabilityObservation>.broadcast();

  void emitCapability(TransportCapabilityObservation observation) {
    _capabilities.add(observation);
  }

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      _capabilities.stream;

  @override
  Stream<WakiPacket> startListening() {
    listenStarts += 1;
    return _packets.stream;
  }

  @override
  Stream<ConnectionHealth> connect() {
    connectStarts += 1;
    return _health.stream;
  }

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
  ) async {
    audioSends += 1;
    return const Right<Failure, void>(null);
  }

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
  void dispose() {
    disposeCalls += 1;
  }

  void disposeControllers() {
    unawaited(_packets.close());
    unawaited(_health.close());
    unawaited(_capabilities.close());
  }
}

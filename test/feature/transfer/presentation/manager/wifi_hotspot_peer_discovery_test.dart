import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/error/failure.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/core/sfx/sfx_event.dart';
import 'package:tark/core/sfx/sfx_player.dart';
import 'package:tark/feature/audio/domain/service/session_wake_lock.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/wifi_transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/channel_gate.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/session_role_store.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';
import 'package:tark/feature/transfer/presentation/manager/wifi_hotspot_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sdk = MethodChannel('tark/bluetooth_server/methods');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(sdk, (_) async => 33);
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final id in call.arguments as List<dynamic>) id: 1};
      }
      return 1;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(sdk, null);
    messenger.setMockMethodCallHandler(permissions, null);
  });

  test('two phones discover each other from one network QR without '
      'either phone entering the call first', () async {
    final pair = _Pair();
    addTearDown(pair.dispose);
    await pair.host.cubit.chooseRole(HotspotRole.host);
    await pair.joiner.cubit.chooseRole(HotspotRole.join);

    // This is the same payload the production host screen draws. The peer
    // adopts its channel before the fake OS associates with its network.
    final qr = pair.host.cubit.state.credentials!.qrPayload(
      channel: pair.host.cubit.state.channelId,
    );
    await pair.joiner.cubit.submitScannedCode(qr);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(pair.joiner.cubit.state.joinPhase, JoinPhase.joined);
    expect(pair.joiner.membership.current, pair.host.membership.current);
    expect(pair.host.cubit.state.peerConnected, isTrue);
    expect(pair.joiner.cubit.state.peerConnected, isTrue);
    expect(pair.host.wifi.sent, greaterThan(0));
    expect(pair.joiner.wifi.sent, greaterThan(0));
    expect(pair.host.wakeLock.microphoneRequests, everyElement(isFalse));
    expect(pair.joiner.wakeLock.microphoneRequests, everyElement(isFalse));

    // Navigation closes these setup cubits. It hands the AP and network to
    // the call, but must retire the setup heartbeat immediately.
    await pair.host.cubit.close();
    await pair.joiner.cubit.close();
    final counts = (pair.host.wifi.sent, pair.joiner.wifi.sent);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect((pair.host.wifi.sent, pair.joiner.wifi.sent), counts);
    expect(pair.host.hotspot.stops, 0);
    expect(pair.joiner.joiner.leaves, 0);
  });

  test('another channel cannot complete setup and backing out retires '
      'presence before releasing the link', () async {
    final pair = _Pair();
    addTearDown(pair.dispose);
    await pair.host.cubit.chooseRole(HotspotRole.host);
    await pair.joiner.cubit.chooseRole(HotspotRole.join);
    final foreignChannel = pair.host.membership.current.value == 0xABCDEF
        ? const ChannelId(0x123456)
        : const ChannelId(0xABCDEF);
    await pair.joiner.cubit.submitScannedCode(
      pair.host.cubit.state.credentials!.qrPayload(channel: foreignChannel),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(pair.host.cubit.state.peerConnected, isFalse);
    expect(pair.joiner.cubit.state.peerConnected, isFalse);
    expect(pair.host.wifi.sent, greaterThan(0));
    expect(pair.joiner.wifi.sent, greaterThan(0));

    await pair.joiner.cubit.backToRoleChoice();
    final sent = pair.joiner.wifi.sent;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(pair.joiner.wifi.sent, sent);
    expect(pair.joiner.joiner.leaves, 1);
    expect(pair.joiner.cubit.state.role, isNull);
  });

  test('a lost association stops announcing until the retry joins '
      'the scanned network again', () async {
    final pair = _Pair();
    addTearDown(pair.dispose);
    // Keep the remote transport quiet so this device remains on setup.
    await pair.joiner.cubit.chooseRole(HotspotRole.join);
    await pair.joiner.cubit.submitScannedCode(_Host.credentials.wifiQrPayload);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pair.joiner.wifi.sent, greaterThan(0));
    pair.joiner.joiner.lost.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pair.joiner.cubit.state.joinPhase, JoinPhase.lost);
    final sent = pair.joiner.wifi.sent;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(pair.joiner.wifi.sent, sent);

    await pair.joiner.cubit.joinNetwork(_Host.credentials);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pair.joiner.cubit.state.joinPhase, JoinPhase.joined);
    expect(pair.joiner.wifi.sent, greaterThan(sent));
  });

  test(
    'a synchronous presence failure does not interrupt a joined bridge',
    () async {
      final pair = _Pair();
      addTearDown(pair.dispose);
      pair.joiner.wifi.throwOnPresence = true;
      await pair.joiner.cubit.chooseRole(HotspotRole.join);
      await pair.joiner.cubit.submitScannedCode(
        _Host.credentials.wifiQrPayload,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pair.joiner.cubit.state.joinPhase, JoinPhase.joined);
      expect(pair.joiner.cubit.state.peerConnected, isFalse);
      expect(pair.joiner.wifi.sent, 1);

      pair.joiner.wifi.throwOnPresence = false;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(pair.joiner.wifi.sent, greaterThan(1));
    },
  );
}

class _Pair {
  _Pair() {
    host = _Endpoint('aaaaaaaaaaaa', () => linked);
    joiner = _Endpoint('bbbbbbbbbbbb', () => linked);
    host.wifi.other = joiner.wifi;
    joiner.wifi.other = host.wifi;
    joiner.joiner.onJoin = () => linked = true;
  }

  bool linked = false;
  late final _Endpoint host;
  late final _Endpoint joiner;

  Future<void> dispose() async {
    await host.dispose();
    await joiner.dispose();
  }
}

class _Endpoint {
  _Endpoint(String id, bool Function() linked) {
    wifi = _PipeWifi(id, membership, roles, linked);
    cubit = WifiHotspotCubit(
      wifi,
      hotspot,
      joiner,
      _SilentSfx(),
      wakeLock,
      roles,
      _Keeper(),
      membership,
      _Modes(),
    );
  }

  final membership = ChannelMembership();
  final roles = _Roles();
  final hotspot = _Host();
  final joiner = _Joiner();
  final wakeLock = _WakeLock();
  late final _PipeWifi wifi;
  late final WifiHotspotCubit cubit;

  Future<void> dispose() async {
    if (!cubit.isClosed) await cubit.close();
    await wifi.release();
    await hotspot.stopped.close();
    await joiner.lost.close();
  }
}

// Only UDP delivery and OS association are simulated. Presence bytes and
// channel attribution pass through the production codec on both phones.
class _PipeWifi implements WifiTransferRepository {
  _PipeWifi(String id, this.membership, this.roles, this.linked)
    : codec = WakiPacketCodec(id, SessionEpoch(), membership) {
    packets = StreamController<WakiPacket>.broadcast(
      onCancel: () => listening = false,
    );
  }

  final ChannelMembership membership;
  final _Roles roles;
  final bool Function() linked;
  final WakiPacketCodec codec;
  late final StreamController<WakiPacket> packets;
  _PipeWifi? other;
  bool listening = false;
  bool throwOnPresence = false;
  int sent = 0;

  @override
  Stream<WakiPacket> startListening() {
    listening = true;
    return packets.stream;
  }

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) {
    sent++;
    if (throwOnPresence) throw StateError('send socket is rebuilding');
    final target = other;
    if (!linked() || target == null || !target.listening) {
      return Future.value(const Right(null));
    }
    final bytes = codec.encodePresence(
      senderName,
      isTalking,
      role: roles.role ?? SessionRole.peer,
      isLeaving: isLeaving,
    );
    final packet = target.codec.decode(bytes, 'peer-route');
    if (packet != null &&
        ChannelGate(target.membership.current).admits(packet.channelId)) {
      target.packets.add(packet);
    }
    return Future.value(const Right(null));
  }

  @override
  void stopConnection() => listening = false;

  Future<void> release() async {
    codec.release();
    await packets.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _Host implements HotspotHost {
  static const credentials = HotspotCredentials(
    ssid: 'Tark;Ride:01',
    passphrase: r'p;ass:word\x',
  );
  final stopped = StreamController<void>.broadcast();
  int stops = 0;

  @override
  Future<HotspotCredentials> start() async => credentials;
  @override
  Future<void> stop() async => stops++;
  @override
  Stream<void> get onStopped => stopped.stream;
  @override
  Future<HotspotWifiAdvice> wifiAdvice() async => HotspotWifiAdvice.none;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _Joiner implements HotspotJoiner {
  final lost = StreamController<void>.broadcast();
  void Function()? onJoin;
  int leaves = 0;

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    if (credentials != _Host.credentials) return HotspotJoinResult.declined;
    onJoin?.call();
    return HotspotJoinResult.joined;
  }

  @override
  Future<void> leave() async => leaves++;
  @override
  Stream<void> get onLost => lost.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _Roles implements SessionRoleStore {
  @override
  SessionRole? role;
  @override
  void setRole(SessionRole next) => role = next;
  @override
  void clear() => role = null;
}

class _Keeper implements HotspotLinkKeeper {
  @override
  void adopt(HotspotCredentials credentials) {}
  @override
  Future<void> release() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _WakeLock implements SessionWakeLock {
  final microphoneRequests = <bool>[];
  @override
  Future<void> start({bool usesMicrophone = true}) async =>
      microphoneRequests.add(usesMicrophone);
  @override
  Future<void> stop() async {}
}

class _SilentSfx implements SfxPlayer {
  @override
  void play(SfxEvent event) {}
}

class _Modes implements TransferModeStore {
  @override
  TransferMode mode = TransferMode.wifi;
  @override
  Future<void> setMode(TransferMode next) async => mode = next;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

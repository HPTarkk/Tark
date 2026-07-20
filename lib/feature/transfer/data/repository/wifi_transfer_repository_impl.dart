import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/lan_ipv4.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../codec/waki_packet_codec.dart';

const kBroadcastPort = 4000;

@LazySingleton(as: WifiTransferRepository)
class WifiTransferRepositoryImpl implements WifiTransferRepository {
  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _receiveSocket;
  final _connectionController = StreamController<ConnectionHealth>.broadcast();

  bool _autoReconnectEnabled = true;
  Completer<void>? _manualRetryCompleter;

  // Liveness watchdog: the socket can stay bound while silently receiving
  // nothing (dead peer, or the OS killed delivery under Doze/a network
  // switch) — that's indistinguishable from "healthy" by socket state alone.
  // Closing the socket after a stretch of silence with known peers routes
  // the problem through the existing, already-correct error/retry path below
  // instead of requiring the user to manually leave and rejoin.
  Timer? _livenessTimer;
  DateTime _lastPacketAt = DateTime.now();
  static const _livenessCheckInterval = Duration(seconds: 5);
  static const _livenessTimeout = Duration(seconds: 15);

  // Every packet is sent to ALL of these. A device can sit on several IPv4
  // networks at once (hotspot AP interface + cellular, or WiFi + hotspot),
  // and only one of them contains the peers. Broadcasting on every private
  // interface (plus the limited broadcast) means we never depend on
  // interface order — picking "the first non-loopback interface" broke the
  // hotspot-host case, where cellular is usually listed first. Targets are
  // limited to RFC1918 subnets so we never spray a directed broadcast at a
  // public range (the cellular interface often carries a public IP).
  List<InternetAddress> _broadcastTargets = const [];
  DateTime _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _targetsMaxAge = Duration(seconds: 10);

  // Private /24 prefixes ("a.b.c") we sit on, used for the unicast discovery
  // sweep, and our own addresses, used to ignore our broadcast echo.
  List<String> _sweepSubnets = const [];
  Set<String> _localAddresses = const {};

  // Peers we've actually heard from, by source address. iOS can neither
  // send nor receive UDP broadcast without Apple's restricted multicast
  // entitlement (com.apple.developer.networking.multicast), so on top of
  // broadcasting, every packet is also unicast to each recently seen peer —
  // unicast only needs the Local Network permission. Duplicates on
  // platforms where broadcast DOES arrive are harmless: presence handling
  // is idempotent and the playback buffer drops repeated audio seqs.
  final Map<String, DateTime> _peers = {};
  static const _peerMaxAge = Duration(seconds: 10);

  final _codec = WakiPacketCodec();

  // Incremented each time startListening() is called so any in-flight
  // generator from a previous session knows to stop when it wakes from
  // its retry delay and sees a different generation number.
  int _generation = 0;

  // Per-outgoing-stream counter so receivers can detect UDP loss/reordering.
  int _audioSeq = 0;

  WifiTransferRepositoryImpl();

  @disposeMethod
  @override
  void dispose() {
    _generation++;
    _livenessTimer?.cancel();
    _sendSocket?.close();
    _sendSocket = null;
    _receiveSocket?.close();
    _receiveSocket = null;
    _connectionController.close();
    _codec.release();
  }

  @override
  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  ) async {
    try {
      await _ensureSendSocket();
      final packet = _codec.encodeAudio(samples, senderName, _audioSeq++);
      _sendToAllTargets(packet);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking,
  ) async {
    try {
      await _ensureSendSocket();
      final packet = _codec.encodePresence(senderName, isTalking);
      _sendToAllTargets(packet);
      _sweepIfUndiscovered(packet);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Stream<WakiPacket> startListening() async* {
    // Claim this generation slot. Any previous generator still alive in a
    // retry-delay sleep will see _generation != myGen and exit cleanly.
    final myGen = ++_generation;

    // Telegram-style reconnect backoff: 4s → 8s → 16s … 64s between rebind
    // attempts, reset the moment traffic actually flows again (first datagram
    // after a bind) so an isolated drop doesn't inherit a long stale delay.
    final backoff = ExponentialBackoff();

    while (_generation == myGen) {
      try {
        _receiveSocket?.close();
        _receiveSocket = null;

        // Re-resolve every rebind: a Wi-Fi/hotspot interface that changed
        // while we were down (screen-off drop, network switch) is picked up
        // here so the send side targets the right subnet on recovery.
        await _resolveNetwork();
        _targetsResolvedAt = DateTime.now();

        _receiveSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          kBroadcastPort,
        );
        _receiveSocket!.broadcastEnabled = true;
        _setHealth(const ConnectionHealth.healthy());
        _lastPacketAt = DateTime.now();
        _startLivenessWatch(myGen);
        Logger.log('UDP socket bound on port $kBroadcastPort (gen $myGen)');

        await for (final event in _receiveSocket!) {
          if (_generation != myGen) break;
          if (event == RawSocketEvent.read) {
            Datagram? dg;
            while ((dg = _receiveSocket?.receive()) != null) {
              // Broadcast echoes of our own packets can arrive from ANY of
              // our addresses (multi-interface), not just the one the cubit
              // filters on — drop them here where all of them are known.
              if (_localAddresses.contains(dg!.address.address)) continue;
              // Real traffic is flowing — the link is healthy, so the next
              // drop backs off from 4s again rather than from where we left.
              backoff.reset();
              _lastPacketAt = DateTime.now();
              final packet = _codec.decode(dg.data, dg.address.address);
              if (packet != null) {
                _rememberPeer(dg.address.address);
                yield packet;
              }
            }
          } else if (event == RawSocketEvent.closed) {
            break;
          }
        }

        _livenessTimer?.cancel();
        // Auto path: the reconnecting state (with its countdown) is emitted in
        // the backoff block below, once the delay is known. Only the terminal
        // "down" needs announcing here.
        if (!_autoReconnectEnabled) _setHealth(const ConnectionHealth.down());
      } catch (error) {
        Logger.log('Socket error (gen $myGen): $error');
        _livenessTimer?.cancel();
        if (!_autoReconnectEnabled) _setHealth(const ConnectionHealth.down());
        _receiveSocket?.close();
        _receiveSocket = null;
      }

      if (_generation != myGen) break;

      if (_autoReconnectEnabled) {
        // Announce the scheduled attempt so the banner can count down to it —
        // the delay grows each failed cycle (backoff) and resets to 4s once
        // real traffic flows again (backoff.reset above).
        final delay = backoff.next();
        _setHealth(
          ConnectionHealth.reconnecting(
            nextRetryAt: DateTime.now().add(delay),
            retryDelay: delay,
          ),
        );

        // Retry delay, sliced short: async* cancellation only takes effect
        // between awaits, so one long sleep here would make cancel() (and
        // the page teardown awaiting it) lag by whole seconds. The wait is
        // also interruptible mid-backoff: the banner's "Reconnect now"
        // (retryNow) completes _manualRetryCompleter to rebind at once
        // instead of sitting out the remaining seconds.
        final completer = Completer<void>();
        _manualRetryCompleter = completer;
        final slices = delay.inMilliseconds ~/ 250;
        for (
          var i = 0;
          i < slices && _generation == myGen && !completer.isCompleted;
          i++
        ) {
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 250)),
            completer.future,
          ]);
        }
        _manualRetryCompleter = null;

        // Countdown's over — the rebind at the top of the loop is now the
        // active attempt; drop the countdown so the banner shows the
        // indeterminate "reconnecting…" until it succeeds or reschedules.
        if (_generation == myGen) {
          _setHealth(const ConnectionHealth.reconnecting());
        }
      } else {
        // Auto-reconnect is off: wait indefinitely for an explicit
        // retryNow() instead of retrying on our own.
        final completer = Completer<void>();
        _manualRetryCompleter = completer;
        await completer.future;
        _manualRetryCompleter = null;
      }
    }
  }

  void _startLivenessWatch(int myGen) {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(_livenessCheckInterval, (_) {
      if (_generation != myGen) {
        _livenessTimer?.cancel();
        return;
      }
      // Only fires once we've actually heard from someone — a freshly
      // opened, never-joined channel isn't "unreachable," it's just empty.
      if (_peers.isEmpty) return;
      if (DateTime.now().difference(_lastPacketAt) > _livenessTimeout) {
        Logger.log('WiFi liveness timeout (gen $myGen) — forcing rebind');
        _receiveSocket?.close();
      }
    });
  }

  @override
  Stream<ConnectionHealth> connect() => _connectionController.stream;

  @override
  void setAutoReconnectEnabled(bool enabled) {
    _autoReconnectEnabled = enabled;
    if (enabled) retryNow();
  }

  @override
  void retryNow() {
    // Null first so a re-entrant call (double-tap on "Reconnect now") can't
    // complete the same completer twice.
    final completer = _manualRetryCompleter;
    _manualRetryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void resetCodecState() => _codec.resetDecoders();

  @override
  void stopConnection() {
    // Invalidate any running generator by advancing the generation counter.
    _generation++;
    _livenessTimer?.cancel();
    _manualRetryCompleter?.complete();
    _manualRetryCompleter = null;

    _receiveSocket?.close();
    _receiveSocket = null;

    // Also tear down the send socket so the next session gets a fresh one
    // with correctly resolved broadcast targets (WiFi/network may change).
    _sendSocket?.close();
    _sendSocket = null;
    _broadcastTargets = const [];
    _sweepSubnets = const [];
    _localAddresses = const {};
    _peers.clear();

    _setHealth(const ConnectionHealth.down());
  }

  Future<void> _ensureSendSocket() async {
    if (_sendSocket == null) {
      _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sendSocket!.broadcastEnabled = true;
    }

    // Re-resolve periodically so a hotspot/WiFi interface that appears
    // mid-session (e.g. a client joining the hotspot brings the AP interface
    // up) starts receiving without needing to leave and rejoin the channel.
    final now = DateTime.now();
    if (_broadcastTargets.isEmpty ||
        now.difference(_targetsResolvedAt) > _targetsMaxAge) {
      await _resolveNetwork();
      _targetsResolvedAt = now;
    }
  }

  void _sendToAllTargets(List<int> packet) {
    for (final target in _broadcastTargets) {
      _trySend(packet, target);
    }
    final now = DateTime.now();
    _peers.removeWhere((_, seen) => now.difference(seen) > _peerMaxAge);
    for (final addr in _peers.keys) {
      _trySend(packet, InternetAddress(addr));
    }
  }

  /// Discovery fallback for platforms where broadcast never arrives (iOS
  /// without the multicast entitlement): while no peer is known, unicast the
  /// presence packet to every host of each private /24 we sit on. ~253 tiny
  /// packets per presence tick, and it stops as soon as anyone answers —
  /// from then on the peer map carries the session.
  void _sweepIfUndiscovered(List<int> packet) {
    if (_peers.isNotEmpty) return;
    for (final prefix in _sweepSubnets) {
      for (var host = 1; host < 255; host++) {
        final addr = '$prefix.$host';
        if (_localAddresses.contains(addr)) continue;
        _trySend(packet, InternetAddress(addr));
      }
    }
  }

  void _rememberPeer(String address) {
    // Our own broadcast comes back to us — that's not a peer.
    if (_localAddresses.contains(address)) return;
    _peers[address] = DateTime.now();
  }

  // A broadcast send is EXPECTED to fail on iOS (errno 65, no multicast
  // entitlement); one failing target must not abort the remaining
  // (unicast) targets, which do work there.
  void _trySend(List<int> packet, InternetAddress target) {
    try {
      _sendSocket!.send(packet, target, kBroadcastPort);
    } catch (_) {}
  }

  /// Resolves the directed broadcast address (x.y.z.255) of every private
  /// (RFC1918) IPv4 interface plus the limited broadcast 255.255.255.255,
  /// along with the matching /24 sweep prefixes and our own addresses.
  ///
  /// NetworkInterface.list doesn't expose the subnet prefix, so /24 is
  /// assumed — that matches Android/Windows/iPhone hotspots and virtually
  /// all home routers, and the limited broadcast covers the rest. Public and
  /// CLAT (192.0.0.x) addresses are skipped: peers can never be there, and a
  /// directed broadcast to a public range would leave the LAN.
  Future<void> _resolveNetwork() async {
    final targets = <String>{'255.255.255.255'};
    final subnets = <String>{};
    final locals = <String>{};
    try {
      for (final entry in await LanIpv4.addresses()) {
        locals.add(entry.address);
        if (!LanIpv4.isPrivate(entry.address)) continue;
        final parts = entry.address.split('.');
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
        targets.add('$prefix.255');
        subnets.add(prefix);
      }
    } catch (e) {
      Logger.log('Could not enumerate network interfaces: $e');
    }
    _broadcastTargets = targets.map(InternetAddress.new).toList();
    _sweepSubnets = subnets.toList();
    _localAddresses = locals;
    Logger.log('Broadcast targets: $targets, sweep subnets: $subnets');
  }

  void _setHealth(ConnectionHealth health) {
    if (_connectionController.isClosed) return;
    _connectionController.add(health);
  }
}

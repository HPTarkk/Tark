import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/lan_ipv4.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/session_role_store.dart';
import '../codec/waki_packet_codec.dart';
import 'discovery_sweep.dart';

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

  /// Paces the unicast discovery sweep across ticks instead of emitting the
  /// whole thing at once.
  final DiscoverySweep _sweep = DiscoverySweep();

  /// Targets whose last send did not go out, so the failure is reported once
  /// rather than at the presence tick rate.
  final Set<String> _failingTargets = {};

  /// Directed broadcasts for subnets we have received traffic from, which
  /// survive an interface enumeration that missed them (see
  /// [_rememberHeardSubnet]).
  final Set<String> _heardSubnets = {};
  List<InternetAddress> _heardSubnetBroadcasts = const [];

  /// `senderId@address` pairs already reported by [_noteSenderRoute]. Kept
  /// separate from [_peers], which ages entries out every 10s — a quiet peer
  /// would otherwise be announced again every time it spoke.
  final Set<String> _seenSenderRoutes = {};

  late final _codec = WakiPacketCodec(_identity.id);

  // Incremented each time startListening() is called so any in-flight
  // generator from a previous session knows to stop when it wakes from
  // its retry delay and sees a different generation number.
  int _generation = 0;

  // Per-outgoing-stream counter so receivers can detect UDP loss/reordering.
  int _audioSeq = 0;

  final DeviceIdentity _identity;
  final SessionRoleStore _roleStore;

  WifiTransferRepositoryImpl(this._identity, this._roleStore);

  /// Nothing about a UDP socket says who brought the network up, so the
  /// hotspot bridge records the side the user picked and this reads it back.
  /// Nobody claimed a side → plain Wi-Fi through a router, where every device
  /// really is an equal peer.
  @override
  SessionRole get sessionRole => _roleStore.role ?? SessionRole.peer;

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
      final packet = _codec.encodePresence(
        senderName,
        isTalking,
        role: sessionRole,
      );
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
        // Per generation, not per session: navigating from the hotspot screen
        // into the channel rebinds, and without this the new generation stays
        // silent about who it hears — leaving "still receiving" and "went deaf
        // on the rebind" indistinguishable in the log.
        _seenSenderRoutes.clear();
        _failingTargets.clear();
        _setHealth(const ConnectionHealth.healthy());
        _lastPacketAt = DateTime.now();
        _startLivenessWatch(myGen);
        // Local addresses restated here rather than left to the change-only
        // line in _resolveNetwork: this is the one thing every "why is nothing
        // arriving" question turns on, and a log captured after the session
        // started would otherwise never show it.
        Logger.diagnostic(
          'wifi: UDP bound on $kBroadcastPort (gen $myGen), '
          'local $_localAddresses, broadcasting to '
          '${_broadcastTargets.map((a) => a.address).toList()}',
        );

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
                _rememberHeardSubnet(dg.address.address);
                _noteSenderRoute(dg.address.address, packet.senderId);
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
        Logger.diagnostic('wifi: liveness timeout (gen $myGen) — forcing rebind');
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
    _seenSenderRoutes.clear();
    _heardSubnets.clear();
    _heardSubnetBroadcasts = const [];
    _sweep.retarget(const []);

    _setHealth(const ConnectionHealth.down());
  }

  Future<void> _ensureSendSocket() async {
    // Resolve BEFORE ensuring the socket, not after. A resolve that finds the
    // addresses changed discards the send socket so it can be rebuilt on the
    // network we are actually on — done in the other order, that discard lands
    // on the socket this method just created, and every send in the tick that
    // follows dies on a null.
    //
    // Re-resolved periodically so an interface that appears mid-session (a
    // client joining the hotspot brings the AP interface up) is picked up
    // without leaving and rejoining the channel.
    final now = DateTime.now();
    if (_broadcastTargets.isEmpty ||
        now.difference(_targetsResolvedAt) > _targetsMaxAge) {
      await _resolveNetwork();
      _targetsResolvedAt = now;
    }

    if (_sendSocket == null) {
      _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sendSocket!.broadcastEnabled = true;
    }
  }

  void _sendToAllTargets(List<int> packet) {
    for (final target in _broadcastTargets) {
      _trySend(packet, target);
    }
    for (final target in _heardSubnetBroadcasts) {
      _trySend(packet, target);
    }
    final now = DateTime.now();
    // Losing the unicast path matters on its own: where broadcast does not
    // cross a SoftAP, unicast is the ONLY delivery, and it lasts exactly as
    // long as we keep hearing from the peer. Both ends going quiet at once is
    // therefore self-sustaining, so the moment it happens is worth a line.
    _peers.removeWhere((addr, seen) {
      if (now.difference(seen) <= _peerMaxAge) return false;
      Logger.diagnostic('wifi: peer $addr aged out — no longer unicasting to it');
      return true;
    });
    for (final addr in _peers.keys) {
      _trySend(packet, InternetAddress(addr));
    }
  }

  /// Adds the /24 directed broadcast of a subnet we have actually received a
  /// packet from.
  ///
  /// [_resolveNetwork] can only offer subnets it can see on our own
  /// interfaces, and that enumeration is not always complete — a hotspot host
  /// whose AP interface does not turn up in `NetworkInterface.list` is left
  /// with nothing but the limited broadcast, which a SoftAP often will not
  /// carry. A subnet a datagram genuinely arrived from is known-reachable
  /// evidence that no enumeration can contradict, and it keeps working after
  /// the unicast peer entry ages out.
  void _rememberHeardSubnet(String address) {
    if (!LanIpv4.isPrivate(address)) return;
    final parts = address.split('.');
    if (parts.length != 4) return;
    final directed = '${parts[0]}.${parts[1]}.${parts[2]}.255';
    if (!_heardSubnets.add(directed)) return;
    // Only the ones _resolveNetwork did not already cover — otherwise every
    // packet goes to the same directed broadcast twice.
    final known = _broadcastTargets.map((a) => a.address).toSet();
    _heardSubnetBroadcasts = _heardSubnets
        .where((a) => !known.contains(a))
        .map(InternetAddress.new)
        .toList();
    _retargetSweep();
    Logger.diagnostic('wifi: also broadcasting to $directed (heard traffic)');
  }

  /// Discovery fallback for platforms where broadcast never arrives (iOS
  /// without the multicast entitlement): while no peer is known, unicast the
  /// presence packet to hosts of the private /24s we sit on, and stop as soon
  /// as anyone answers — from then on the peer map carries the session.
  ///
  /// Rate-limited by [DiscoverySweep]. Firing every host of every subnet in
  /// one tick overran the socket's send buffer and silently ate the very
  /// packets the session runs on, which kept a peer from ever being found and
  /// so kept the sweep running — see that class for the whole story.
  void _sweepIfUndiscovered(List<int> packet) {
    if (_peers.isNotEmpty) {
      _sweep.reset();
      return;
    }
    for (final addr in _sweep.nextSlice()) {
      _trySend(packet, InternetAddress(addr));
    }
  }

  /// Rebuilds the sweep's target list, subnets we have actually heard traffic
  /// from first. Those are where a peer demonstrably is, so they get probed
  /// before a subnet that is merely present on this device (a home Wi-Fi the
  /// other phone was never on).
  void _retargetSweep() {
    final heardFirst = <String>[];
    final rest = <String>[];
    for (final prefix in _sweepSubnets) {
      final bucket = _heardSubnets.contains('$prefix.255') ? heardFirst : rest;
      for (var host = 1; host < 255; host++) {
        final addr = '$prefix.$host';
        if (_localAddresses.contains(addr)) continue;
        bucket.add(addr);
      }
    }
    _sweep.retarget([...heardFirst, ...rest]);
  }

  /// Notes each (source address, sender id) pair the first time it is seen.
  ///
  /// One line per pair, so it stays quiet during a call while answering the
  /// two questions that are impossible to reason about from the code alone:
  /// who is actually on the channel, and whether one device is arriving by
  /// more than one route (the same id under two addresses is a phone sending
  /// on two interfaces).
  void _noteSenderRoute(String address, String senderId) {
    if (!_seenSenderRoutes.add('$senderId@$address')) return;
    Logger.diagnostic('wifi: sender $senderId first heard from $address');
  }

  void _rememberPeer(String address) {
    // Our own broadcast comes back to us — that's not a peer.
    if (_localAddresses.contains(address)) return;
    _peers[address] = DateTime.now();
  }

  // A broadcast send is EXPECTED to fail on iOS (errno 65, no multicast
  // entitlement); one failing target must not abort the remaining
  // (unicast) targets, which do work there.
  //
  // Failures are reported once per target, and once again on recovery. This
  // used to swallow both halves of a failed send — the thrown errno AND a
  // return of 0, which means the datagram never left — so a phone that had
  // silently stopped transmitting looked identical to one with nothing to say.
  // Every other stage of the path can be observed; this one could not.
  void _trySend(List<int> packet, InternetAddress target) {
    // Read once into a local: a rebuild can null the field between targets in
    // the same loop, and a `!` here turned that into an exception per target
    // rather than a skipped packet.
    final socket = _sendSocket;
    if (socket == null) return;
    try {
      final sent = socket.send(packet, target, kBroadcastPort);
      if (sent == 0) {
        if (_failingTargets.add(target.address)) {
          Logger.diagnostic(
            'wifi: send to ${target.address} dropped (socket would block)',
          );
        }
        return;
      }
      if (_failingTargets.remove(target.address)) {
        Logger.diagnostic('wifi: send to ${target.address} recovered');
      }
    } catch (e) {
      if (_failingTargets.add(target.address)) {
        Logger.diagnostic('wifi: send to ${target.address} failed: $e');
      }
    }
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
    // Only when it actually changes: this re-resolves every 10s while sending,
    // and the interesting event is an interface appearing or going away (a
    // client bringing the AP interface up, cellular arriving alongside it) —
    // not the six identical lines a minute in between.
    if (!setEquals(locals, _localAddresses)) {
      Logger.diagnostic('wifi: local addresses $locals, broadcasting to $targets');
      // The addresses moved under us, which on this path means the OS put us
      // on a different network — a joiner being pulled off an internet-less
      // hotspot back onto its saved Wi-Fi is the case that matters. The send
      // socket was created on the network that just went away; keeping it
      // leaves every send failing against a route that no longer exists,
      // silently, while the phone looks perfectly connected on the new one.
      // Dropping it here makes the next send build a fresh one.
      if (_localAddresses.isNotEmpty && _sendSocket != null) {
        Logger.diagnostic('wifi: network changed — rebuilding the send socket');
        _sendSocket?.close();
        _sendSocket = null;
      }
      // Anyone we knew was reachable from the old network. Clearing them stops
      // us unicasting into a dead subnet for the next 10s, and lets discovery
      // start over on the network we are actually on.
      _peers.clear();
      _heardSubnets.clear();
      _heardSubnetBroadcasts = const [];
    }
    _localAddresses = locals;
    _retargetSweep();
  }

  void _setHealth(ConnectionHealth health) {
    if (_connectionController.isClosed) return;
    _connectionController.add(health);
  }
}

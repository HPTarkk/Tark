import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:injectable/injectable.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/identity/channel_membership.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../../core/identity/session_epoch.dart';
import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/lan_ipv4.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/audio_profile.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/control_packet.dart';
import '../../domain/entity/opus_tuning.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/transport_stats.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/wifi_transfer_repository.dart';
import '../../domain/service/audio_capability_negotiator.dart';
import '../../domain/service/host_subnet_filter.dart';
import '../../domain/service/media_opus_tuner.dart';
import '../../domain/service/recovery_ladder.dart';
import '../../domain/service/opus_tuner.dart';
import '../../domain/service/peer_loss_tracker.dart';
import '../../domain/service/peer_ping_tracker.dart';
import '../../domain/service/channel_gate.dart';
import '../../domain/service/sender_route_pin.dart';
import '../../domain/service/session_epoch_gate.dart';
import '../../domain/service/session_role_store.dart';
import '../../domain/service/transport_drop_counters.dart';
import '../codec/opus_audio_codec.dart';
import '../codec/waki_packet_codec.dart';
import '../hotspot/wifi_client_address.dart';
import 'broadcast_policy.dart';
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

  /// When a peer was last heard, for the watchdog's "is there a session to
  /// watch?" question — deliberately separate from [_peers], which is cleared
  /// whenever our addresses change.
  ///
  /// Gating the watchdog on `_peers.isEmpty` made it disable itself in exactly
  /// the case it was written for: the OS moves the phone to another network,
  /// [_resolveNetwork] clears the peer map, the watchdog then returns early
  /// forever, the receive socket is never rebound, and no packet can arrive to
  /// repopulate the map. A dead link reported itself as healthy, indefinitely.
  DateTime? _lastPeerAt;

  /// How long after the last peer packet the watchdog keeps trying. Past this
  /// the other end is treated as genuinely gone rather than unreachable, so a
  /// user sitting alone in a channel isn't handed a rebind every 15s.
  static const _watchdogGrace = Duration(minutes: 2);

  /// Set by [rebindSockets] to skip the backoff wait — the network changing
  /// under us is news, not a failed attempt, and the right move is to bind on
  /// the new one immediately.
  bool _rebindRequested = false;

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

  /// Addresses that were peers recently, kept far longer than [_peerMaxAge]
  /// and unicast to whenever [_peers] is empty.
  ///
  /// This is what breaks the deadlock the comment in [_sendToAllTargets]
  /// describes but did nothing about. Where broadcast does not cross the
  /// SoftAP — the common hotspot case — unicast to [_peers] is the *only*
  /// delivery path, and it is sustained purely by hearing from the other end.
  /// So a stall longer than [_peerMaxAge] in both directions at once (Wi-Fi
  /// power save, Doze, the host's AP hiccuping when cellular flips) ages the
  /// peer out on BOTH phones in the same window. From then on neither one
  /// unicasts, both fall back to a broadcast that never arrives, and nothing
  /// either side can do will produce the packet that would repopulate the map.
  /// The channel is dead until the user leaves and rejoins — which is exactly
  /// how "it dropped every few minutes and I had to re-enter" is reported.
  ///
  /// Keeping the address around and still unicasting to it while no live peer
  /// is known costs a couple of datagrams per send in the failure case and
  /// nothing at all in the healthy one (the branch in [_sendToAllTargets] only
  /// consults this map when [_peers] is empty), and it lets a stall of any
  /// length inside the window heal on its own the moment the air clears.
  final Map<String, DateTime> _recoveryPeers = {};

  /// How long an aged-out peer stays worth unicasting to. Deliberately equal
  /// to [_watchdogGrace]: for as long as the liveness watchdog still treats
  /// the other end as unreachable-rather-than-gone and keeps rebinding for it,
  /// the send side keeps addressing it. Past that, both give up together.
  static const _peerRecoveryWindow = _watchdogGrace;

  /// Paces the unicast discovery sweep across ticks instead of emitting the
  /// whole thing at once.
  final DiscoverySweep _sweep = DiscoverySweep();

  /// Targets whose last send did not go out, so the failure is reported once
  /// rather than at the presence tick rate.
  final Set<String> _failingTargets = {};

  /// Device ids we have decoded a packet from recently, which is what goes out
  /// on our presence so the other end can tell whether it is being heard at
  /// all. Keyed on the device id rather than the address for the same reason
  /// the roster is: one phone can arrive under two source IPs.
  final Map<String, DateTime> _heardSenders = {};

  /// How long a sender stays on the heard list. Deliberately longer than the
  /// 2s presence tick and shorter than the roster's own timeout: it has to
  /// survive a couple of dropped datagrams without claiming to hear someone
  /// who has actually gone.
  static const _heardSenderMaxAge = Duration(seconds: 8);

  /// When the send socket last failed against every target it had.
  ///
  /// A socket bound to a Network handle the OS has since torn down does not
  /// close, report an error, or stop existing — it just fails every `send`
  /// with ENETUNREACH forever, while the receive side (which is not routed and
  /// so does not care) carries on delivering perfectly. That asymmetry is
  /// exactly the reported "I can hear them, they can't hear me", and this is
  /// what notices it.
  DateTime? _sendFailingSince;

  /// Grace before a wholly failing send socket is thrown away and rebuilt.
  /// Long enough that a single blocked send (a full socket buffer) is not a
  /// reason to rebuild; short enough that a dead link heals inside one breath.
  static const _sendFailureGrace = Duration(seconds: 2);

  /// Rate limit on those rebuilds, so a genuinely unreachable peer costs one
  /// socket per interval rather than one per datagram.
  DateTime _lastSendRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _sendRebuildInterval = Duration(seconds: 5);

  // Traffic counters for the periodic session line in the diagnostic log.
  // Two numbers answer most of "why did it go quiet": whether we were still
  // sending, and whether anything was still arriving.
  int _packetsIn = 0;
  int _packetsOut = 0;

  /// #30's media stream, counted separately from [_packetsIn]/[_packetsOut]
  /// (which count every packet type, media included) so the session line can
  /// say how much of the traffic is actually music rather than only that
  /// traffic exists.
  int _mediaPacketsIn = 0;
  int _mediaPacketsOut = 0;

  /// Directed broadcasts for subnets we have received traffic from, which
  /// survive an interface enumeration that missed them (see
  /// [_rememberHeardSubnet]).
  final Set<String> _heardSubnets = {};
  List<InternetAddress> _heardSubnetBroadcasts = const [];

  /// `senderId@address` pairs already reported by [_noteSenderRoute]. Kept
  /// separate from [_peers], which ages entries out every 10s — a quiet peer
  /// would otherwise be announced again every time it spoke.
  final Set<String> _seenSenderRoutes = {};

  /// Per sender, per source address: how many packets arrived and when the
  /// last one did.
  ///
  /// One phone arriving under two addresses at once is the worst failure this
  /// transport has, and the hardest to see. It happens whenever both ends are
  /// multi-homed — each hosting a hotspot the other has joined, or both still
  /// on a router alongside the hotspot — and then every packet reaches us
  /// twice by paths with completely different latency. The jitter buffer
  /// downstream sees one sender's sequence jumping forward and back by
  /// hundreds of packets and spends the whole session resyncing, which is
  /// heard as syllables repeating and speech breaking up.
  ///
  /// Nothing about that is visible in the counters: `in=` climbs, the peer is
  /// in the roster, the sockets are up, health is green. The only evidence is
  /// exactly this — the same sender id under two addresses — which is why it
  /// is tracked per route rather than inferred from [_peers] (whose keys are
  /// addresses, and so cannot tell two phones from one phone twice).
  final Map<String, Map<String, _RouteStats>> _senderRoutes = {};

  /// A route unheard for this long stops counting toward the split-route
  /// warning. Long enough to survive a burst of loss on one path, short enough
  /// that a genuinely abandoned route clears within a couple of report cycles.
  static const _routeMaxAge = Duration(seconds: 12);

  /// When the split-route warning last went out, so a session that stays
  /// split reports at the session-line rate instead of per packet.
  DateTime _lastSplitRouteLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _splitRouteLogInterval = Duration(seconds: 15);

  /// Datagrams the socket refused to queue since the last session line.
  ///
  /// Distinct from [_failingTargets], which reports a target's FIRST failure
  /// and then stays quiet: a target that blocks on nearly every send and one
  /// that blocked once look identical there. On a SoftAP whose driver queue is
  /// backing up — a client at the edge of range, which is exactly the case the
  /// user is in when they report bad audio — this is the number that moves,
  /// and it has to be a rate to mean anything.
  int _sendErrorWindow = 0;

  /// Windowed AND session-cumulative counts for the three drop/block classes
  /// below, kept independent by [TransportDropCounters] — see its doc for why
  /// the log line's 15s window reset must never touch the totals the quality
  /// indicator diffs every 2s.
  final _drops = TransportDropCounters();

  @override
  TransportStats get stats => TransportStats(
    sendFailing: _sendFailingSince != null,
    unicastUnconfirmed: _unicastUnconfirmed,
    rtt: _lastRtt,
    staleEpochDrops: _drops.staleEpochTotal,
    duplicateRouteDrops: _drops.duplicateRouteTotal,
    blockedSends: _drops.blockedTotal,
    peerCount: _peers.length,
  );

  late final _codec = WakiPacketCodec(_identity.id, _epoch, _membership);

  /// Drops packets from a peer's previous join that arrive after its new one
  /// has started. See [SessionEpochGate].
  final SessionEpochGate _epochGate = SessionEpochGate();

  /// Tracks what every currently-heard peer has advertised, and resolves the
  /// mutual audio wire format. WiFi is a broadcast transport with one encoder
  /// for the whole roster (see [AudioCapabilityNegotiator]'s class doc), so
  /// this feeds it the *whole* heard roster rather than one peer.
  final AudioCapabilityNegotiator _capabilities = AudioCapabilityNegotiator();

  AudioFormatProfile _negotiatedFormat = AudioFormatProfile.legacy16k;

  @override
  AudioFormatProfile get negotiatedFormat => _negotiatedFormat;

  /// Recomputes the mutual profile from what's currently tracked and applies
  /// it if it changed. Cheap to call on every presence tick — a no-op change
  /// is the overwhelmingly common case — which is what keeps a negotiated
  /// profile from flapping packet to packet.
  ///
  /// The log line doubles as #28's A/B evidence: everything measurable about
  /// the link at the moment it crossed from one profile to the other, so a
  /// session that ran through both a legacy and an HD stretch can be
  /// compared from its own diagnostic export — device capture/playback rate
  /// is AudioEngineImpl's own "wire format" line, logged at the same
  /// transition from the other side of the negotiation. Subjective listening
  /// quality stays owner/field evidence; this only captures what's measured.
  void _syncFormatProfile() {
    final resolved = _capabilities.resolve();
    if (resolved == _negotiatedFormat) return;
    final previous = _negotiatedFormat;
    _negotiatedFormat = resolved;
    _codec.setFormatProfile(resolved);
    Logger.diagnostic(
      'wifi: negotiated audio profile ${previous.label} -> ${resolved.label} '
      '| ${_opusSummary()} rtt=${_lastRtt?.inMilliseconds ?? '?'}ms',
    );
  }

  /// #29's media analog of [_capabilities]/[_syncFormatProfile] — same
  /// whole-roster reasoning, same wire byte, different bits (see
  /// [AudioCapabilityNegotiator.media]).
  final AudioCapabilityNegotiator _mediaCapabilities =
      AudioCapabilityNegotiator.media();

  AudioFormatProfile? _negotiatedMediaFormat;

  @override
  AudioFormatProfile? get negotiatedMediaFormat => _negotiatedMediaFormat;

  void _syncMediaFormatProfile() {
    final resolved = _mediaCapabilities.resolveOptional();
    if (resolved == _negotiatedMediaFormat) return;
    final previous = _negotiatedMediaFormat;
    _negotiatedMediaFormat = resolved;
    // #30: unlike before, there is now a real media codec instance to apply
    // this to. A null [resolved] leaves the encoder on whatever it was last
    // set to — harmless, since nothing calls [sendMedia] once no peer
    // negotiates a media profile.
    if (resolved != null) _codec.setMediaFormatProfile(resolved);
    Logger.diagnostic(
      'wifi: negotiated media profile ${previous?.label ?? 'none'} -> '
      '${resolved?.label ?? 'none'}',
    );
  }

  /// Counterpart of the tuning [_measureLink] applies to [_codec] via
  /// [OpusTuner.forProfile] — now (#30) actually applied to [_codec]'s media
  /// stream, and also read by [_mediaOpusSummary] for the session log. Null
  /// whenever no media profile is currently negotiated.
  OpusTuning? _mediaTuning;

  /// Recomputes [_mediaTuning] from the same link measurement
  /// [_measureLink] just fed the voice tuner, and applies it to [_codec]'s
  /// media encoder. Cheap to call on every measurement tick even while
  /// nothing is casting — [OpusAudioCodec.applyTuning] no-ops when unchanged.
  void _updateMediaTuning() {
    final profile = _negotiatedMediaFormat;
    if (profile == null) {
      _mediaTuning = null;
      return;
    }
    final tuning = MediaOpusTuner.forProfile(profile).tune(
      AudioLinkConditions(lossFraction: _loss.worstLossFraction, rtt: _lastRtt),
    );
    _mediaTuning = tuning;
    _codec.applyMediaTuning(tuning);
  }

  /// The media analog of [_opusSummary], for the session log line — what the
  /// #29 media bitrate policy currently computes, whether or not anything is
  /// actually casting. `media=none` when no peer has negotiated an HD media
  /// profile.
  String _mediaOpusSummary() {
    final format = _negotiatedMediaFormat;
    final tuning = _mediaTuning;
    if (format == null || tuning == null) return 'media=none';
    return 'media=${format.label}/${tuning.bitrate ~/ 1000}kbps/'
        'fec${_codec.hasMediaFec ? 'on' : 'off'}';
  }

  /// Packets belonging to a *different* conversation on this network, dropped
  /// since the last session line.
  ///
  /// Worth its own counter rather than folding into the others, because it is
  /// the only drop class that is good news. A non-zero value says there is a
  /// second group in earshot and we are correctly ignoring them — which is
  /// exactly the question behind "why can't my friend hear me on this Wi-Fi",
  /// and impossible to answer from a screenshot without it.
  int _otherChannelWindow = 0;

  /// The distinct channels we have heard and excluded this session, so the log
  /// can say *how many* other groups are here rather than only how loud they
  /// are. Bounded by the log line resetting it.
  final Set<int> _otherChannelsHeard = {};

  // Incremented each time startListening() is called so any in-flight
  // generator from a previous session knows to stop when it wakes from
  // its retry delay and sees a different generation number.
  int _generation = 0;

  // Per-outgoing-stream counter so receivers can detect UDP loss/reordering.
  int _audioSeq = 0;

  /// #30's independent counter for the media stream — deliberately not
  /// [_audioSeq]: voice and media are separate sequence spaces, so loss or
  /// reordering on one is invisible to the other's jitter buffer.
  int _mediaSeq = 0;

  final DeviceIdentity _identity;
  final SessionEpoch _epoch;
  final SessionRoleStore _roleStore;
  final ChannelMembership _membership;

  WifiTransferRepositoryImpl(
    this._identity,
    this._epoch,
    this._roleStore,
    this._membership,
  );

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
    _pingTimer?.cancel();
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
      _sendToAllTargets(packet, isAudio: true);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendMedia(
    List<double> samples,
    String senderName,
  ) async {
    try {
      await _ensureSendSocket();
      final packet = _codec.encodeMediaAudio(samples, senderName, _mediaSeq++);
      // Same "unicast-covers-everyone skips the broadcast leg" treatment as
      // voice — see [needsBroadcastLeg] — media is just as high-frequency.
      _sendToAllTargets(packet, isAudio: true);
      _mediaPacketsOut++;
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
        // Never null on this transport: a Wi-Fi channel genuinely knows who it
        // hears, and an honest empty list is what lets a peer whose send path
        // has died find out. See [PresencePacket.heardIds].
        heardIds: _currentlyHeardSenders(),
      );
      _sendToAllTargets(packet, isAudio: false);
      _sweepIfUndiscovered(packet);
      _logSessionState();
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

    // A new join, so a new epoch on everything we send from here — this is the
    // one place that means "the user entered a channel". Deliberately outside
    // the loop below: every iteration of that is a *rebind*, the same session
    // repairing itself, and renewing there would have every peer treat each of
    // our recoveries as a rejoin and re-adopt us mid-call.
    final epoch = _epoch.renew();
    Logger.diagnostic('wifi: session epoch $epoch (gen $myGen)');

    // Telegram-style reconnect backoff: 4s → 8s → 16s … 64s between rebind
    // attempts, reset the moment traffic actually flows again (first datagram
    // after a bind) so an isolated drop doesn't inherit a long stale delay.
    final backoff = ExponentialBackoff();

    while (_generation == myGen) {
      try {
        _receiveSocket?.close();
        _receiveSocket = null;
        // BOTH sockets, every time. Rebinding only the receive side was a
        // half-recovery that produced the app's most confusing failure: the
        // phone kept hearing everyone (delivery to a bound UDP port does not
        // depend on which network the socket was created on) while every one
        // of its own packets died on a route that no longer existed. Its
        // troubleshooting sheet then reported four green checks — mic working,
        // address present, link steady, one person here — for a device nobody
        // could hear.
        //
        // The reasons to rebind are all reasons to distrust the send socket
        // too: the liveness watchdog fired, the socket errored, or
        // [rebindSockets] was called because the OS moved us. Discarding it
        // here costs one `bind` per rebind and removes the entire class of
        // one-way-after-recovery states.
        _sendSocket?.close();
        _sendSocket = null;
        _sendFailingSince = null;

        // Past the rebind rungs, the network we keep binding to is itself the
        // suspect — discard what we believe about it before resolving again.
        if (_ladder.shouldRenegotiate) _renegotiate();

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
        // Consumed here as well as in the backoff block below: a rebind asked
        // for while the loop was already sleeping between attempts gets served
        // by that attempt, and must not leave the flag set to skip the backoff
        // of some later, unrelated failure.
        _rebindRequested = false;
        _startLivenessWatch(myGen);
        _startPingLoop(myGen);
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
              // drop backs off from 4s again rather than from where we left,
              // and starts back at the quiet rung of the ladder rather than
              // wherever the last run of failures had climbed to.
              backoff.reset();
              _ladder.reset();
              _lastPacketAt = DateTime.now();

              // Control is answered here and never yielded: a ping is a
              // transport question with a transport answer, and the session
              // has no opinion about it. Gated on the raw type byte so the
              // audio path — fifty times more traffic — pays one comparison.
              if (WakiPacketCodec.isControl(dg.data[0])) {
                final control = _codec.decodeControl(
                  dg.data,
                  dg.address.address,
                );
                if (control != null) {
                  _rememberPeer(dg.address.address);
                  _handleControl(control, dg.address.address);
                }
                continue;
              }

              final packet = _codec.decode(dg.data, dg.address.address);
              if (packet != null) {
                _packetsIn++;
                // Channel before epoch, and both before anything is recorded
                // about the sender. The order is by how fundamental the
                // question is: a packet from a different conversation is not
                // a peer of ours at all, so it must not reach the epoch gate
                // (where it would claim a slot in a per-sender map that only
                // grows) any more than it may refresh the peer map, the heard
                // list or the route pin.
                if (!_acceptChannel(packet)) continue;
                // Then epoch. A ghost from a sender's previous join must not
                // refresh the peer map, the heard list or the route pin —
                // all three would be taking a session that has already ended
                // as evidence the current one is alive.
                if (!_acceptEpoch(packet)) continue;
                _noteSenderRoute(dg.address.address, packet.senderId);
                // Subnet pinning, receive half. A sender reaching us by a
                // second path is dropped here, before anything downstream can
                // act on it — the jitter buffer in particular, which cannot
                // tell a second copy from a restarted stream and spends the
                // session flip-flopping between the two numberings.
                if (!_acceptRoute(packet.senderId, dg.address.address)) {
                  continue;
                }
                _rememberPeer(dg.address.address);
                _rememberHeardSubnet(dg.address.address);
                _heardSenders[packet.senderId] = _lastPacketAt;
                // Which device is at which address, so a unicast ping can
                // carry the right peer's counters.
                _senderAtAddress[dg.address.address] = packet.senderId;
                if (packet is AudioPacket) {
                  (_rxBySender[packet.senderId] ??= _PeerAudioStats()).record(
                    packet.seq,
                  );
                } else if (packet is MediaAudioPacket) {
                  // No per-sender stats map of its own yet — #30 checkpoint 4
                  // adds the receive-side media buffer that per-sender
                  // tracking actually belongs to; this transport only counts
                  // the traffic, the way it counts everything else.
                  _mediaPacketsIn++;
                } else if (packet is PresencePacket) {
                  _capabilities.observePeer(
                    packet.senderId,
                    packet.capabilityBitmask,
                  );
                  _syncFormatProfile();
                  _mediaCapabilities.observePeer(
                    packet.senderId,
                    packet.capabilityBitmask,
                  );
                  _syncMediaFormatProfile();
                }
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

      // The network moved under us and [rebindSockets] tore the sockets down
      // on purpose. There is nothing to back off from — the bind at the top of
      // the loop is the whole point — so go straight back to it.
      if (_rebindRequested) {
        _rebindRequested = false;
        backoff.reset();
        // Not a failed attempt, so it does not climb the ladder — but not
        // silent either: the network moving under a live session is worth the
        // banner, and it is news the user can act on if it does not settle.
        _ladder.reset();
        _setHealth(const ConnectionHealth.reconnecting());
        continue;
      }

      if (_autoReconnectEnabled) {
        // Announce the scheduled attempt so the banner can count down to it —
        // the delay grows each failed cycle (backoff) and resets to 4s once
        // real traffic flows again (backoff.reset above).
        final delay = backoff.next();
        _ladder.escalate();
        _setHealth(_ladder.rung(delay));

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
        // indeterminate state until it succeeds or reschedules. The rung is
        // kept: an attempt that is about to renegotiate must not flash back
        // through "reconnecting" on its way there.
        if (_generation == myGen) _setHealth(_ladder.rung(null));
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

  /// One line every [_sessionLogInterval] describing the whole transport, for
  /// the on-device log.
  ///
  /// This is deliberately a single dense line rather than events, because the
  /// question it has to answer after the fact is comparative: at the moment
  /// the user says it went quiet, was this phone still sending, was anything
  /// still arriving, did it still have peers to send to, and on which
  /// addresses? Two of these lines side by side from the two phones settle in
  /// seconds what no amount of reasoning about the code can.
  ///
  /// Rides the presence tick (2s) and throttles itself rather than owning a
  /// timer, so it cannot outlive the session that produces it.
  void _logSessionState() {
    final now = DateTime.now();
    // Checked before the throttle: a split route is the one condition worth
    // knowing about at its own cadence, and it owns its own rate limit.
    _logSplitRoutes(now);
    if (now.difference(_lastSessionLogAt) < _sessionLogInterval) return;
    final window = now.difference(_lastSessionLogAt);
    _lastSessionLogAt = now;
    final silentFor = now.difference(_lastPacketAt).inSeconds;
    // Deltas alongside the totals. The totals answer "did it ever work"; only
    // a rate answers "is it working now", and reading one off two cumulative
    // lines 15s apart is exactly the arithmetic nobody does at 2am.
    final inDelta = _packetsIn - _lastPacketsIn;
    final outDelta = _packetsOut - _lastPacketsOut;
    _lastPacketsIn = _packetsIn;
    _lastPacketsOut = _packetsOut;
    final mediaInDelta = _mediaPacketsIn - _lastMediaPacketsIn;
    final mediaOutDelta = _mediaPacketsOut - _lastMediaPacketsOut;
    _lastMediaPacketsIn = _mediaPacketsIn;
    _lastMediaPacketsOut = _mediaPacketsOut;
    final dropWindow = _drops.takeWindow();
    final blocked = dropWindow.blocked;
    final errored = _sendErrorWindow;
    final dupRoute = dropWindow.duplicateRoute;
    final staleEpoch = dropWindow.staleEpoch;
    final otherChannels = _otherChannelWindow;
    final otherChannelCount = _otherChannelsHeard.length;
    _sendErrorWindow = 0;
    _otherChannelWindow = 0;
    _otherChannelsHeard.clear();
    // The cumulative totals are deliberately NOT reset here — see
    // TransportDropCounters' doc. Only stopConnection()'s real session
    // boundary zeroes them; this log line only takes and zeroes its own
    // window.
    Logger.diagnostic(
      'wifi: in=$_packetsIn(+$inDelta) out=$_packetsOut(+$outDelta) '
      'mediaIn=$_mediaPacketsIn(+$mediaInDelta) '
      'mediaOut=$_mediaPacketsOut(+$mediaOutDelta) '
      'over ${window.inSeconds}s '
      'peers=${_peers.keys.toList()} recovery=${_recoveryPeers.length} '
      'heard=${_heardSenders.keys.toList()} '
      'routes=${_routeSummary()} pinned=${_routePin.pinnedAddresses} '
      'dupRoute=$dupRoute staleEpoch=$staleEpoch epoch=${_epoch.value} '
      'channel=${_membership.current.code ?? 'open'} '
      '${otherChannels == 0 ? '' : 'otherChannels=$otherChannelCount($otherChannels pkts) '}'
      'rtt=${_lastRtt?.inMilliseconds ?? '?'}ms '
      'txLoss=${_lossSummary()} opus=${_opusSummary()} ${_mediaOpusSummary()} '
      '${_unicastUnconfirmed ? 'UNICAST-UNCONFIRMED ' : ''}'
      'local=$_localAddresses '
      'bcast=${_broadcastTargets.map((a) => a.address).toList()}'
      '${_heardSubnetBroadcasts.isEmpty ? '' : '+${_heardSubnetBroadcasts.map((a) => a.address).toList()}'} '
      'sendSocket=${_sendSocket == null ? 'none' : 'up'} '
      'rxSocket=${_receiveSocket == null ? 'none' : 'up'} '
      'blocked=$blocked errs=$errored '
      'quietFor=${silentFor}s'
      '${_sendFailingSince == null ? '' : ' SEND-FAILING'}',
    );
  }

  /// What the encoder is actually set to, and whether it could be set at all.
  ///
  /// `fec=off` is the one that matters when a report says a peer sounds torn up
  /// under loss: it means the controlled bindings were unavailable on that
  /// phone, so the tuning beside it describes what the link was measured to
  /// want rather than anything in force.
  String _opusSummary() {
    final tuning = _codec.tuning;
    return '${_negotiatedFormat.label}/${tuning.bitrate ~/ 1000}kbps/'
        'loss${tuning.packetLossPerc}%/fec${_codec.hasFec ? 'on' : 'off'}';
  }

  /// Worst far-end loss and which peer is reporting it. Named because "13 %
  /// loss" and "13 % loss, always that same phone" are different problems: the
  /// first is the channel, the second is one rider dropping behind.
  String _lossSummary() {
    final worstId = _loss.worstPeerId;
    if (worstId == null) return '?';
    final percent = (_loss.worstLossFraction * 100).toStringAsFixed(1);
    return '$percent%@$worstId';
  }

  /// `senderId:routeCount` for everyone currently being heard, so the ordinary
  /// session line carries the multi-route fact even when the dedicated warning
  /// above is inside its rate limit.
  String _routeSummary() => _senderRoutes.isEmpty
      ? '{}'
      : '{${_senderRoutes.entries.map((e) => '${e.key}:${e.value.length}').join(', ')}}';

  int _lastPacketsIn = 0;
  int _lastPacketsOut = 0;
  int _lastMediaPacketsIn = 0;
  int _lastMediaPacketsOut = 0;

  DateTime _lastSessionLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _sessionLogInterval = Duration(seconds: 15);

  /// How far the current run of failures has escalated, and what to report at
  /// each step. See [RecoveryLadder].
  final RecoveryLadder _ladder = RecoveryLadder();

  /// Throws away what we think we know about the network, so the next bind
  /// starts from discovery rather than from a topology that has stopped
  /// working.
  ///
  /// Rebinding repeatedly onto the same resolved addresses is the failure this
  /// answers: every attempt is technically successful — the socket binds, the
  /// targets resolve — and not one packet reaches anybody, because the subnet
  /// we narrowed onto is not where the channel is any more. Nothing in the
  /// retry loop notices, because from inside it every attempt looks the same.
  ///
  /// [_recoveryPeers] deliberately survives. It is the set that keeps unicast
  /// alive when broadcast cannot cross a SoftAP, and clearing it here would
  /// remove the one delivery path most likely to still work at exactly the
  /// moment we are trying everything.
  void _renegotiate() {
    Logger.diagnostic(
      'wifi: ${_ladder.attempts} rebinds have not restored traffic — '
      'renegotiating (re-resolving addresses, widening discovery)',
    );
    // Peers scope the broadcast down to the subnets they were last seen on
    // (see [_broadcastsFor]). Dropping them reopens the wide spray.
    _peers.clear();
    _narrowedTo = const {};
    // Force a re-resolve rather than reusing targets inside their max age.
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _broadcastTargets = const [];
    _sweep.retarget(const []);
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
      final lastPeer = _lastPeerAt;
      if (lastPeer == null) return;
      final now = DateTime.now();
      // …and stops once they've been gone long enough to be gone rather than
      // unreachable, so a solo channel doesn't rebind forever.
      if (now.difference(lastPeer) > _watchdogGrace) return;
      if (now.difference(_lastPacketAt) > _livenessTimeout) {
        Logger.diagnostic(
          'wifi: liveness timeout (gen $myGen) — forcing rebind',
        );
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
  void setAudioProfile(AudioProfile profile) => _codec.setAudioProfile(
    profile == AudioProfile.music
        ? OpusEncodeProfile.music
        : OpusEncodeProfile.voice,
  );

  @override
  void resetCodecState() {
    _codec.resetDecoders();
    _codec.resetMediaDecoders();
  }

  @override
  void repairSendPath() {
    // Rate-limited by the same clock the automatic rebuild uses: a peer whose
    // presence keeps saying it can't hear us arrives every 2s, and rebuilding
    // the socket on each one would guarantee it never got a chance to work.
    final now = DateTime.now();
    if (now.difference(_lastSendRebuildAt) < _sendRebuildInterval) return;
    _lastSendRebuildAt = now;
    Logger.diagnostic(
      'wifi: a peer we can hear reports it cannot hear us — '
      'rebuilding the send path',
    );
    _sendSocket?.close();
    _sendSocket = null;
    _sendFailingSince = null;
    // Re-resolve rather than trust the targets that have been failing. The
    // realistic cause is that the OS moved us onto a new network handle
    // without anything noticing, so both the socket and the addresses it was
    // aiming at are stale.
    _broadcastTargets = const [];
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
    // Not a full rebindSockets(): the receive half is demonstrably working —
    // that is how we heard the complaint — and tearing it down would trade a
    // one-way link for a moment of no link at all.
  }

  @override
  void rebindSockets() {
    Logger.diagnostic('wifi: rebinding both sockets on the current network');
    _rebindRequested = true;

    // Both, not just the send socket. _resolveNetwork already rebuilds the
    // send socket when it notices the addresses changed, and stopping there is
    // why a recovered link could come back send-only: the RECEIVE socket was
    // bound before the process was pinned to the new network, so nothing
    // arrived on it and nothing ever rebuilt it.
    _sendSocket?.close();
    _sendSocket = null;
    // Force the next send to re-resolve rather than target the old subnet.
    _broadcastTargets = const [];
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
    // Live peers belong to the network we just left, so discovery starts over
    // — but they stay in [_recoveryPeers], which is what carries the session
    // through the case this method is most often called for: the OS releasing
    // and re-granting the SAME hotspot (see HotspotLinkKeeper._onRebound).
    // There the peer is still sitting at the same DHCP-leased address, and
    // dropping the only unicast path to it at the exact moment we reconnect is
    // how a recovery turned into a permanent one-way link.
    _peers.clear();
    // Heard subnets deliberately survive: they are evidence of where traffic
    // genuinely came from, and on a SoftAP whose AP interface never enumerates
    // they are the only broadcast target that works. [_resolveNetwork] runs at
    // the top of the rebind loop and clears them if the addresses really did
    // move; a rebind onto the network we were already on should not throw them
    // away on the mere possibility.

    // Closing it breaks the `await for` in startListening, which drops into
    // the rebind at the top of the loop. The generation is untouched, so the
    // session's subscription survives.
    _receiveSocket?.close();
    _receiveSocket = null;

    // If the loop is already sitting out a backoff delay, cut it short.
    final completer = _manualRetryCompleter;
    _manualRetryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void stopConnection() {
    // Invalidate any running generator by advancing the generation counter.
    _generation++;
    _livenessTimer?.cancel();
    _pingTimer?.cancel();
    _manualRetryCompleter?.complete();
    _manualRetryCompleter = null;
    _rebindRequested = false;
    // A new session starts with no history of having heard anyone, so the
    // watchdog stays quiet until this one has a peer of its own.
    _lastPeerAt = null;
    // …and on the bottom rung of the recovery ladder, so its first hiccup is
    // repaired quietly rather than inheriting the escalation of the session
    // that just ended.
    _ladder.reset();

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
    // A new session starts discovery from scratch — unlike a rebind, which
    // keeps the recovery set precisely so it can heal the link underneath a
    // still-running session.
    _recoveryPeers.clear();
    _seenSenderRoutes.clear();
    _heardSubnets.clear();
    _heardSubnetBroadcasts = const [];
    // Carrying these into a new session would have the first presence packet
    // announce that we hear people we have not heard from in this one — which
    // is precisely the claim the other end acts on.
    _heardSenders.clear();
    _sendFailingSince = null;
    _packetsIn = 0;
    _packetsOut = 0;
    _lastPacketsIn = 0;
    _lastPacketsOut = 0;
    // Routes belong to the network topology of the session that just ended.
    // Carrying them over would have a fresh session open by announcing a split
    // route that no longer exists — and, worse, hide a real one behind the
    // warning's rate limit.
    _senderRoutes.clear();
    _lastSplitRouteLogAt = DateTime.fromMillisecondsSinceEpoch(0);
    _targetLoggedAt.clear();
    // Route pins belong to the topology of the session that just ended. A new
    // session must be free to pin wherever its peers turn out to be — carrying
    // a pin over would have it silently ignore the network it is now on.
    _routePin.clear();
    // Likewise session-scoped: the epochs held here are what the peers were on
    // during the session that just ended. Carrying them into a new one would
    // have a peer that has *not* restarted — and so is still on the same epoch
    // it was — read as ordinary traffic, which is correct, while a peer that
    // rejoined below its previous number could not exist. Clearing is simply
    // the honest starting point: adopt whatever the new session hears first.
    _epochGate.clear();
    // Ping state belongs to the peers of the session that just ended: a new
    // one must earn its confirmations rather than inherit them, and starting
    // with _unicastUnconfirmed set would put audio on the broadcast leg for a
    // session that has not sent a single ping yet.
    _pings.clear();
    _unicastUnconfirmed = false;
    _lastRtt = null;
    // Session-scoped for the same reason: the estimate describes peers that
    // are gone, and both counters it diffs against restart with the transport.
    _loss.clear();
    // Likewise: what the last session's peers advertised says nothing about
    // the next session's, and a stale mutual profile would either hold a
    // fresh, still-unconfirmed pair below what they can actually run or
    // (worse, once HD is reachable) claim a profile before anyone on the new
    // session has said they support it.
    _capabilities.clear();
    _negotiatedFormat = AudioFormatProfile.legacy16k;
    _codec.setFormatProfile(AudioFormatProfile.legacy16k);
    _mediaCapabilities.clear();
    _negotiatedMediaFormat = null;
    _mediaTuning = null;
    // Independent of voice's decoder reset just above: a media-only event
    // must never touch voice's decoder state and vice versa — see
    // [WakiPacketCodec.resetMediaDecoders].
    _codec.resetMediaDecoders();
    _mediaSeq = 0;
    _mediaPacketsIn = 0;
    _mediaPacketsOut = 0;
    _lastMediaPacketsIn = 0;
    _lastMediaPacketsOut = 0;
    _rxBySender.clear();
    _senderAtAddress.clear();
    _narrowedTo = const {};
    _sendErrorWindow = 0;
    // The real session boundary: this is the one place the cumulative totals
    // reset, not the diagnostic log line (see TransportDropCounters).
    _drops.reset();
    // Session-scoped like the rest: the neighbouring channels counted here are
    // the ones sharing the network we were on, and the next session may well
    // be on a different one entirely. Our *own* membership is deliberately not
    // cleared here — leaving the channel is the user's act, not the socket's,
    // and a rebind that silently opened the channel back up would put a group
    // that had separated itself back in with everyone else.
    _otherChannelWindow = 0;
    _otherChannelsHeard.clear();
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

  /// Device ids heard recently enough to still be worth announcing.
  List<String> _currentlyHeardSenders() {
    final now = DateTime.now();
    _heardSenders.removeWhere(
      (_, seen) => now.difference(seen) > _heardSenderMaxAge,
    );
    return _heardSenders.keys.toList(growable: false);
  }

  void _sendToAllTargets(List<int> packet, {required bool isAudio}) {
    final now = DateTime.now();
    // Losing the unicast path matters on its own: where broadcast does not
    // cross a SoftAP, unicast is the ONLY delivery, and it lasts exactly as
    // long as we keep hearing from the peer. Both ends going quiet at once is
    // therefore self-sustaining, so the moment it happens is worth a line.
    _peers.removeWhere((addr, seen) {
      if (now.difference(seen) <= _peerMaxAge) return false;
      Logger.diagnostic(
        'wifi: peer $addr aged out — still unicasting to it for recovery',
      );
      return true;
    });
    _recoveryPeers.removeWhere((addr, seen) {
      if (now.difference(seen) <= _peerRecoveryWindow) return false;
      Logger.diagnostic(
        'wifi: peer $addr gave up — no longer unicasting to it',
      );
      return true;
    });
    // Live peers when we have them, the recovery set when we don't. Never
    // both: while anyone is actually being heard, the extra sends would be
    // pure duplication.
    final unicastTargets = _peers.isNotEmpty
        ? _peers.keys
        : _recoveryPeers.keys;
    // Copied before iterating: [_gradeSendPath] below can discard the send
    // socket, and keeping a live view of a map across that is asking for
    // trouble the day something else touches it.
    final unicast = unicastTargets.toList(growable: false);

    // Broadcast targets, narrowed to the subnets the channel is actually on.
    // See [_broadcastsFor] — this is the send half of subnet pinning, and the
    // ordering matters: the peer set is aged above, so a subnet whose peers
    // have all gone silent stops being broadcast to on this very tick.
    //
    // Audio skips this leg entirely while the unicasts already cover every
    // known peer, which after narrowing they always do — see
    // [needsBroadcastLeg] for the doubled-delivery this ends.
    if (needsBroadcastLeg(
      isAudio: isAudio,
      hasLivePeers: _peers.isNotEmpty,
      unicastFailing: _sendFailingSince != null,
      unicastUnconfirmed: _unicastUnconfirmed,
    )) {
      for (final target in _broadcastsFor(unicast)) {
        _trySend(packet, target);
      }
    }

    var failed = 0;
    for (final addr in unicast) {
      if (!_trySend(packet, InternetAddress(addr))) failed++;
    }

    _packetsOut++;
    _gradeSendPath(attempted: unicast.length, failed: failed, now: now);
  }

  /// Which broadcast addresses this packet goes to, given where the peers are.
  ///
  /// Until a peer is known there is nothing to narrow to, so this is every
  /// private subnet on the device plus the limited broadcast — discovery has
  /// to be able to reach a network we have not heard from yet, and that is
  /// what the wide spray is for.
  ///
  /// Once peers ARE known it collapses to the directed broadcast of each
  /// subnet a peer sits on, and the limited broadcast is dropped. This is
  /// subnet pinning on the send side, and it does two things:
  ///
  ///  * It stops us putting the same audio onto a network the channel is not
  ///    using. A phone hosting a hotspot while still associated to a router
  ///    was broadcasting every packet onto both, and the peer — also on both —
  ///    received each one several times, seconds apart, on paths of wildly
  ///    different delay. That is what makes speech repeat and break up.
  ///  * It cuts what we put on the air. A measured session sent each packet to
  ///    three broadcast addresses and two unicasts; the receiving phone counted
  ///    4.5x more datagrams in than the sender counted out, and the host's
  ///    SoftAP queue jammed under it (37042 blocked sends in one session, up to
  ///    42 a second). Narrowing removes that load at the source, which matters
  ///    on exactly the marginal links where it hurts most.
  ///
  /// Deliberately keyed on the peers rather than on a single pinned subnet: a
  /// channel legitimately spanning two networks (someone on the router, someone
  /// on the hotspot) keeps working, because every subnet with a peer on it is
  /// still addressed. What stops is broadcasting into subnets with nobody
  /// there.
  List<InternetAddress> _broadcastsFor(List<String> peerAddresses) {
    if (peerAddresses.isEmpty) {
      return _wideSpray();
    }
    final directed = <String>{};
    for (final addr in peerAddresses) {
      final parts = addr.split('.');
      if (parts.length != 4) continue;
      directed.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
    }
    if (directed.isEmpty) {
      return _wideSpray();
    }
    if (!setEquals(directed, _narrowedTo)) {
      _narrowedTo = directed;
      Logger.diagnostic(
        'wifi: broadcasting only to $directed — the subnet(s) our peers are '
        'actually on; other interfaces are no longer sprayed',
      );
    }
    return directed.map(InternetAddress.new).toList(growable: false);
  }

  /// Every private subnet we can see plus the limited broadcast — the
  /// discovery posture, used until peers say where the channel actually is.
  List<InternetAddress> _wideSpray() {
    if (_narrowedTo.isNotEmpty) {
      _narrowedTo = const {};
      Logger.diagnostic(
        'wifi: no peers to aim at — broadcasting to every interface again '
        'until one answers',
      );
    }
    return [..._broadcastTargets, ..._heardSubnetBroadcasts];
  }

  /// Last narrowed set, so the line above is written on change rather than
  /// every 20 ms.
  Set<String> _narrowedTo = const {};

  /// Notices a send socket that has stopped working, and throws it away.
  ///
  /// The failure this exists for is invisible from every other angle. When the
  /// OS releases the network a socket was created on — which is exactly what a
  /// screen lock does to a phone joined to a hotspot, since the app-scoped
  /// Wi-Fi request is foreground-only — the socket stays open and keeps
  /// failing every `send` against a route that is gone. Nothing closes it,
  /// nothing reports it, and the receive path is unaffected, so the phone
  /// looks completely healthy while nobody can hear it.
  ///
  /// Dropping the socket is the whole fix: [_ensureSendSocket] rebuilds it on
  /// the network the process is on *now*, which after the OS has put us back
  /// on the AP is the right one.
  ///
  /// Graded on the **unicast** targets only, never the broadcasts. A broadcast
  /// send is expected to fail outright on iOS (errno 65, no multicast
  /// entitlement), so counting those would have every iPhone sitting alone in
  /// a channel rebuild its socket on a timer forever. A unicast to an address
  /// we have actually heard from is the honest test: it should work, and its
  /// failing is news.
  void _gradeSendPath({
    required int attempted,
    required int failed,
    required DateTime now,
  }) {
    if (attempted == 0 || failed < attempted) {
      if (_sendFailingSince != null) {
        // Same rate limit as the per-target lines, for the same reason: a send
        // path that flaps sets and clears this flag on alternate ticks, and
        // the unguarded line came back 6959 times in one session.
        if (_mayLogTarget('<send-path>', now)) {
          Logger.diagnostic('wifi: send path recovered');
        }
        _sendFailingSince = null;
      }
      return;
    }
    final since = _sendFailingSince ??= now;
    if (now.difference(since) < _sendFailureGrace) return;
    if (now.difference(_lastSendRebuildAt) < _sendRebuildInterval) return;
    _lastSendRebuildAt = now;
    Logger.diagnostic(
      'wifi: every send has failed for ${now.difference(since).inSeconds}s '
      '($attempted targets) — rebuilding the send socket',
    );
    _sendSocket?.close();
    _sendSocket = null;
    // Force the next send to re-resolve too: if the addresses moved, the
    // targets this was failing against are the wrong ones anyway.
    _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
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
  ///
  /// Heard subnets are a *source* of targets here, not just an ordering key.
  /// Ordering them within [_sweepSubnets] alone meant a subnet known only from
  /// received traffic contributed no hosts at all — and that is precisely the
  /// case [_rememberHeardSubnet] exists for: a hotspot host whose AP interface
  /// never turns up in `NetworkInterface.list` has the peer's subnet in
  /// [_heardSubnets] and nowhere else. Rediscovery on that phone could
  /// therefore only ever sweep networks the peer was not on, so once the peer
  /// map emptied the host stayed deaf for the rest of the session.
  void _retargetSweep() {
    final heardPrefixes = <String>{};
    for (final directed in _heardSubnets) {
      final parts = directed.split('.');
      if (parts.length != 4) continue;
      heardPrefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }

    final heardFirst = <String>[];
    final rest = <String>[];
    for (final prefix in {...heardPrefixes, ..._sweepSubnets}) {
      final bucket = heardPrefixes.contains(prefix) ? heardFirst : rest;
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
    final routes = _senderRoutes.putIfAbsent(senderId, () => {});
    (routes[address] ??= _RouteStats()).hit();
    if (!_seenSenderRoutes.add('$senderId@$address')) return;
    Logger.diagnostic('wifi: sender $senderId first heard from $address');
  }

  /// Names any sender currently arriving by more than one route.
  ///
  /// Deliberately its own line rather than a field on the session line: it is
  /// the difference between a session that will sound fine and one that cannot
  /// possibly sound fine, and it needs to be greppable on its own. The packet
  /// counts per route are what says which path to blame — a route carrying a
  /// tenth of the traffic is a straggler adding latency, two roughly equal
  /// routes means every packet is genuinely being delivered twice.
  void _logSplitRoutes(DateTime now) {
    for (final routes in _senderRoutes.values) {
      routes.removeWhere((_, s) => now.difference(s.lastAt) > _routeMaxAge);
    }
    _senderRoutes.removeWhere((_, routes) => routes.isEmpty);
    final split = _senderRoutes.entries.where((e) => e.value.length > 1);
    if (split.isEmpty) return;
    if (now.difference(_lastSplitRouteLogAt) < _splitRouteLogInterval) return;
    _lastSplitRouteLogAt = now;
    for (final entry in split) {
      final routes = entry.value.entries
          .map((r) => '${r.key}(${r.value.packets})')
          .join(' + ');
      // Still reported even though [_acceptRoute] now discards the extra
      // copies: the duplicate delivery is a fact about the network, and the
      // fact that we are coping with it is not a reason to stop saying the
      // topology is wrong. Both phones being on each other's hotspot costs
      // air time and battery on every hop regardless of which copies we use.
      Logger.diagnostic(
        'wifi: SPLIT ROUTE — sender ${entry.key} is arriving on '
        '${entry.value.length} paths: $routes. Only the pinned one is used '
        '(pinned=${_routePin.pinnedFor(entry.key) ?? 'none'}); the rest are dropped. '
        'Both devices are probably on two shared networks at once.',
      );
    }
  }

  /// Whether a packet from [senderId] arriving at [address] should be used.
  ///
  /// The decision itself lives in [SenderRoutePin], which documents why one
  /// route per sender is the right rule and why the pin has to expire. This
  /// wrapper does the two things that need the repository: saying so in the
  /// log, and dropping an abandoned address out of the peer sets so we stop
  /// transmitting onto a network we no longer listen to.
  bool _acceptRoute(String senderId, String address) {
    final verdict = _routePin.offer(senderId, address, DateTime.now());
    switch (verdict.decision) {
      case RouteDecision.pinned:
        Logger.diagnostic('wifi: pinned sender $senderId to $address');
      case RouteDecision.accepted:
        break;
      case RouteDecision.rejected:
        // Counted rather than logged: this arrives at the full audio rate, and
        // the count on the session line is what makes it legible.
        _drops.duplicateRouteDropped();
      case RouteDecision.repinned:
        Logger.diagnostic(
          'wifi: sender $senderId moved from ${verdict.previous} to $address '
          '(old route silent for '
          '${verdict.previousSilence?.inSeconds ?? '?'}s) — repinning',
        );
        // The abandoned address may still be in the peer/recovery sets, where
        // it would keep drawing unicasts and keep its subnet in the narrowed
        // broadcast set. Dropping it here is what actually stops us
        // transmitting onto the network we just stopped listening to.
        _peers.remove(verdict.previous);
        _recoveryPeers.remove(verdict.previous);
    }
    return verdict.isAccepted;
  }

  /// Whether [packet] belongs to the conversation this device is having.
  ///
  /// The decision lives in [ChannelGate], which documents why an unstated
  /// channel on either side has to be admitted. This wrapper does the parts
  /// that need the repository: counting the drops, and remembering *which*
  /// other channels are out there so the session line can say how many groups
  /// share this network rather than only how much of their traffic we threw
  /// away.
  ///
  /// The gate is rebuilt per packet rather than held as a field, because our
  /// own membership can change mid-session — the scanner adopts a channel on
  /// another page — and a gate captured at bind time would go on filtering
  /// against the channel we used to be in.
  bool _acceptChannel(WakiPacket packet) {
    final gate = ChannelGate(_membership.current);
    if (gate.admits(packet.channelId)) return true;
    _otherChannelWindow++;
    _otherChannelsHeard.add(packet.channelId.value);
    return false;
  }

  /// Whether [packet] belongs to the join of its sender we are listening to.
  ///
  /// The decision lives in [SessionEpochGate], which documents why a rejoin
  /// has to be told apart from the session it replaced. This wrapper does the
  /// parts that need the repository: the log line, the drop counter, and
  /// clearing the per-sender state a rejoin invalidates.
  bool _acceptEpoch(WakiPacket packet) {
    // A build that predates the epoch says nothing about which join it is on,
    // and silence is not a claim. Grading it would put every peer on an older
    // version permanently out of the channel — the exact mixed-version split
    // the wire format's forward compatibility exists to avoid.
    if (!packet.hasSessionEpoch) return true;

    final verdict = _epochGate.offer(packet.senderId, packet.sessionEpoch);
    switch (verdict.decision) {
      case EpochDecision.adopted:
        Logger.diagnostic(
          'wifi: sender ${packet.senderId} on epoch ${packet.sessionEpoch}',
        );
      case EpochDecision.accepted:
        break;
      case EpochDecision.stale:
        // Counted rather than logged: a ghost burst arrives at the full audio
        // rate, and the count on the session line is what makes it legible.
        _drops.staleEpochDropped();
      case EpochDecision.renewed:
        Logger.diagnostic(
          'wifi: sender ${packet.senderId} rejoined — epoch '
          '${verdict.previous} → ${verdict.offered}',
        );
        // Everything below is keyed to the session that just ended. The route
        // pin is the one that matters: the peer may well come back on a
        // different address, and a pin from its previous join would reject the
        // new one for the whole grace period — silence at exactly the moment
        // the user reconnected.
        _routePin.forget(packet.senderId);
        _senderRoutes.remove(packet.senderId);
        _seenSenderRoutes.removeWhere(
          (r) => r.startsWith('${packet.senderId}@'),
        );
        // Its old sequence numbering went with it, so the per-sender Opus
        // decoder must not carry state across the boundary — for both
        // streams, since the rejoin restarts both sequence spaces at once.
        _codec.resetDecoders();
        _codec.resetMediaDecoders();
    }
    return verdict.isAccepted;
  }

  // ── Unicast heartbeat ───────────────────────────────────────────────────

  /// Whether any peer we can hear has stopped answering on the unicast path.
  ///
  /// Recomputed on each ping tick rather than asked per send: [_sendToAllTargets]
  /// runs fifty times a second and must not walk the peer set to answer it.
  bool _unicastUnconfirmed = false;

  /// Round-trip confirmation per peer — see [PeerPingTracker].
  final PeerPingTracker _pings = PeerPingTracker();

  Timer? _pingTimer;
  int _pingToken = 0;

  /// One ping per second, which is the review's figure and a reasonable one:
  /// fast enough that [PeerPingTracker.grace] is six lost pings rather than
  /// two, and 36 bytes/s per peer against roughly 8 kB/s of Opus.
  static const _pingInterval = Duration(seconds: 1);

  /// Highest audio sequence and packet count received per sender, so a ping
  /// can tell the far end what we have actually got from it. Two ends
  /// comparing "you say you sent up to N" against "I have up to M" is a loss
  /// measurement neither could make alone.
  final Map<String, _PeerAudioStats> _rxBySender = {};

  /// Which sender is currently at which address, so a ping addressed by IP can
  /// carry the counters for the device that lives there. The route pin holds
  /// the same relation the other way round; this is the direction a unicast
  /// needs.
  final Map<String, String> _senderAtAddress = {};

  void _startPingLoop(int myGen) {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_generation != myGen) {
        _pingTimer?.cancel();
        return;
      }
      _pingPeers();
    });
  }

  /// Pings every live peer, unicast only.
  ///
  /// Deliberately not [_sendToAllTargets]: that adds the broadcast leg for
  /// anything that is not audio, and a ping answered over broadcast would
  /// confirm the one path we are not trying to test. This is the whole point
  /// of the mechanism — it has to travel exactly where audio travels.
  void _pingPeers() {
    final now = DateTime.now();
    final targets = _peers.keys.toList(growable: false);
    for (final address in targets) {
      final senderId = _senderAtAddress[address];
      final rx = senderId == null ? null : _rxBySender[senderId];
      final token = ++_pingToken;
      final packet = _codec.encodePing(
        token: token,
        lastTxSeq: _audioSeq,
        lastRxSeq: rx?.lastSeq ?? 0,
        audioRxPackets: rx?.count ?? 0,
      );
      if (_trySend(packet, InternetAddress(address))) {
        _pings.sent(address, token, now);
      }
    }

    // Expire the loss estimates of peers who have gone. Before reading the
    // worst below, because the worst is exactly what a departed peer would
    // otherwise go on being: a rider who drops off the back of the group at
    // 40 % loss would hold the encoder at its lowest bitrate for everyone still
    // talking, for the rest of the session.
    _loss.retain(_currentlyHeardSenders());
    // Same reasoning for capability: a peer who dropped off must not go on
    // holding (or, once a higher profile is reachable, blocking) the mutual
    // format for everyone still here.
    _capabilities.retain(_currentlyHeardSenders());
    _syncFormatProfile();
    _mediaCapabilities.retain(_currentlyHeardSenders());
    _syncMediaFormatProfile();

    // Retune the encoder for the link we just measured. On this tick rather
    // than per frame because that is the cadence a new measurement arrives at,
    // and the codec ignores an unchanged tuning anyway. The ladder itself
    // follows the negotiated profile — HD's is re-derived, not the legacy
    // tiers scaled up, see [OpusTuner.hd].
    _codec.applyTuning(
      OpusTuner.forProfile(_negotiatedFormat).tune(
        AudioLinkConditions(
          lossFraction: _loss.worstLossFraction,
          rtt: _lastRtt,
        ),
      ),
    );
    _updateMediaTuning();

    // Peers that have gone silent on unicast while still being heard. Recorded
    // as a flag the send path can read for free.
    final unconfirmed = _pings.unconfirmedAmong(targets, now);
    final wasUnconfirmed = _unicastUnconfirmed;
    _unicastUnconfirmed = unconfirmed.isNotEmpty;
    if (_unicastUnconfirmed != wasUnconfirmed) {
      Logger.diagnostic(
        _unicastUnconfirmed
            ? 'wifi: $unconfirmed heard but not answering unicast pings — '
                  'audio is going back on the broadcast leg for them'
            : 'wifi: every heard peer is answering unicast again — '
                  'audio back to unicast only',
      );
    }
  }

  /// Answers a ping on the same unicast path it arrived by, and records a pong.
  void _handleControl(ControlPacket packet, String fromAddress) {
    switch (packet) {
      case PingPacket():
        final rx = _rxBySender[packet.senderId];
        _trySend(
          _codec.encodePong(
            token: packet.token,
            lastTxSeq: _audioSeq,
            lastRxSeq: rx?.lastSeq ?? 0,
            audioRxPackets: rx?.count ?? 0,
          ),
          InternetAddress(fromAddress),
        );
      case PongPacket():
        final rtt = _pings.pong(fromAddress, packet.token, DateTime.now());
        if (rtt != null) _lastRtt = rtt;
        // The counters this pong carries are the only measurement of loss in
        // the direction our voice travels — see [PeerLossTracker]. They were
        // already on the wire from P0; this is what finally reads them.
        _loss.sample(
          packet.senderId,
          ourSentCount: _audioSeq,
          theirReceivedCount: packet.audioRxPackets,
        );
    }
  }

  /// How much of our audio each peer is failing to receive.
  final PeerLossTracker _loss = PeerLossTracker();

  /// Most recent measured round trip, for the link-quality grade.
  Duration? _lastRtt;

  /// One source address per sender — see [SenderRoutePin].
  final SenderRoutePin _routePin = SenderRoutePin();

  void _rememberPeer(String address) {
    // Our own broadcast comes back to us — that's not a peer.
    if (_localAddresses.contains(address)) return;
    final now = DateTime.now();
    _peers[address] = now;
    _recoveryPeers[address] = now;
    _lastPeerAt = now;
  }

  /// Minimum spacing between transition lines for one target.
  ///
  /// "Reported once per target, and once again on recovery" was true only of a
  /// target that fails and then stays failed. A target that blocks and clears
  /// on alternate sends — a SoftAP whose driver queue is right at its limit,
  /// which is the normal state of a hotspot host with a client at the edge of
  /// range — crosses that boundary tens of times a second, and each crossing
  /// wrote two lines. A real capture of this came back 99.7% these two
  /// messages: 37042 "dropped" and 34833 "recovered" out of 79081 lines, at up
  /// to 42 a second, with every other category of evidence squeezed into what
  /// was left of the ring.
  ///
  /// The rate itself is not lost — it is the `blocked=`/`errs=` counters on
  /// the session line, which is where a rate belongs. What is kept here is the
  /// occasional statement of WHICH target and WHICH errno, which a counter
  /// cannot carry.
  static const _targetLogInterval = Duration(seconds: 30);
  final Map<String, DateTime> _targetLoggedAt = {};

  /// Whether [target] may write a transition line now.
  bool _mayLogTarget(String target, DateTime now) {
    final last = _targetLoggedAt[target];
    if (last != null && now.difference(last) < _targetLogInterval) return false;
    _targetLoggedAt[target] = now;
    return true;
  }

  // A broadcast send is EXPECTED to fail on iOS (errno 65, no multicast
  // entitlement); one failing target must not abort the remaining
  // (unicast) targets, which do work there.
  //
  // Both halves of a failed send are caught — the thrown errno AND a return of
  // 0, which means the datagram never left. Swallowing them made a phone that
  // had silently stopped transmitting look identical to one with nothing to
  // say; every other stage of the path can be observed, this one could not.
  /// Returns whether the datagram actually left the device, so the caller can
  /// tell one dead target apart from a dead socket (see [_gradeSendPath]).
  bool _trySend(List<int> packet, InternetAddress target) {
    // Read once into a local: a rebuild can null the field between targets in
    // the same loop, and a `!` here turned that into an exception per target
    // rather than a skipped packet.
    final socket = _sendSocket;
    if (socket == null) return false;
    try {
      final sent = socket.send(packet, target, kBroadcastPort);
      if (sent == 0) {
        _drops.blocked();
        if (_failingTargets.add(target.address) &&
            _mayLogTarget(target.address, DateTime.now())) {
          Logger.diagnostic(
            'wifi: send to ${target.address} dropped (socket would block)',
          );
        }
        return false;
      }
      if (_failingTargets.remove(target.address) &&
          _mayLogTarget(target.address, DateTime.now())) {
        Logger.diagnostic('wifi: send to ${target.address} recovered');
      }
      return true;
    } catch (e) {
      _sendErrorWindow++;
      if (_failingTargets.add(target.address) &&
          _mayLogTarget(target.address, DateTime.now())) {
        Logger.diagnostic('wifi: send to ${target.address} failed: $e');
      }
      return false;
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
    final subnets = <String>{};
    final locals = <String>{};
    try {
      for (final entry in await LanIpv4.addresses()) {
        locals.add(entry.address);
        if (!LanIpv4.isPrivate(entry.address)) continue;
        final parts = entry.address.split('.');
        subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
      }
    } catch (e) {
      Logger.log('Could not enumerate network interfaces: $e');
    }

    // A host serves exactly one network — its own AP — and must not announce
    // itself on a Wi-Fi it happens to still be a client of. Doing so puts the
    // two halves of the same session on two subnets, and both phones then show
    // an empty channel while every diagnostic reads healthy. See
    // [HostSubnetFilter]; the platform read is what tells the AP apart from the
    // joined network, since interface names cannot.
    final isHost = sessionRole == SessionRole.host;
    final kept = HostSubnetFilter.apply(
      subnets: subnets.toList(),
      clientIp: isHost ? await WifiClientAddress.current() : null,
      isHost: isHost,
    );
    if (kept.length != subnets.length) {
      Logger.diagnostic(
        'wifi: hosting — not announcing on ${subnets.difference(kept.toSet())}, '
        'the network this phone is only a client of. Peers are on our AP.',
      );
    }

    // The limited broadcast stays whatever happens: it names no subnet, costs
    // one datagram, and is the only thing that reaches a device whose AP
    // interface never appears in NetworkInterface.list.
    final targets = <String>{
      '255.255.255.255',
      for (final prefix in kept) '$prefix.255',
    };
    _broadcastTargets = targets.map(InternetAddress.new).toList();
    _sweepSubnets = kept;
    // Only when it actually changes: this re-resolves every 10s while sending,
    // and the interesting event is an interface appearing or going away (a
    // client bringing the AP interface up, cellular arriving alongside it) —
    // not the six identical lines a minute in between.
    if (!setEquals(locals, _localAddresses)) {
      Logger.diagnostic(
        'wifi: local addresses $locals, broadcasting to $targets',
      );
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

/// Traffic seen from one sender on one source address. See [_senderRoutes].
class _RouteStats {
  int packets = 0;
  DateTime lastAt = DateTime.now();

  void hit() {
    packets++;
    lastAt = DateTime.now();
  }
}

/// Highest audio sequence and packet count seen from one sender, reported back
/// to it on pings so both ends can compare what was sent against what arrived.
class _PeerAudioStats {
  int lastSeq = 0;
  int count = 0;

  void record(int seq) {
    count++;
    // Highest rather than latest: reordering is routine on UDP, and a straggler
    // must not walk the high-water mark backwards and invent loss that the far
    // end would then read as its own.
    if (seq > lastSeq) lastSeq = seq;
  }
}

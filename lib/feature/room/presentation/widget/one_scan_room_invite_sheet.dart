import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../../core/widget/link_preparing_visual.dart';
import '../../../../core/widget/qr_brand_plan.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/entity/held_seat_name.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_accepted_join_snapshot.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/entity/room_invite_link.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_member_transport_identity.dart';
import 'room_invite_grant_toggle.dart';

/// Where the person who scanned this phone's code is, as this phone's link
/// actually sees it. Only the opener — which owns the link and the signed
/// hello — can know; the sheet just tells it.
enum RoomInviteeProgress {
  /// Nobody has reached this phone yet: the code is what matters.
  waiting,

  /// Something from the other phone has arrived on this phone's link (their
  /// traffic on the hotspot, their Bluetooth link), and the signed hello is
  /// under way.
  connecting,

  /// They proved themselves; the call is opening.
  connected,
}

/// Opens the low-distraction Add person flow used from an active Room.
///
/// The normal path deliberately has exactly one actionable QR. When this
/// phone is the current hotspot host, that QR remains a standards-compliant
/// Wi-Fi payload but carries the durable Room invite as a Tarkk extension.
/// The scanning phone therefore saves membership first and joins the network
/// from the same scan. SSID/password and a second Wi-Fi QR stay out of the
/// primary interaction entirely.
///
/// Before a Room is live nothing is hosting yet, so a QR made then would carry
/// membership and no network: the scanning phone joined the Room with no way
/// to reach this one, and this phone never learned anybody had scanned. The
/// Room entry therefore brings this phone's link up itself (hotspot or
/// Bluetooth, whichever is selected) and passes it as [link]: the sheet waits
/// for it, never shows a code without it, and reports through [onShown] the
/// moment a code people can actually use is on screen.
/// [dismissWhen] closes the sheet from outside — when the person who scanned
/// has proven themselves and the call is opening. [linkKind] says which link
/// [link] is raising, so the wait shows the right thing coming up; it
/// defaults to a hotspot when there is a [link].
///
/// When the link (or the code) cannot be made, the sheet says so in place and
/// offers Try again, which does the whole preparation over without anybody
/// closing anything: [onRetryLink] is asked for a fresh link (the opener
/// cleans up the failed attempt and raises a new one); without it the sheet
/// raises a hotspot itself. [onScanInstead], when given, adds the way to swap
/// roles by hand — the newcomer's phone could not join this one and is now
/// showing its own code — and is called right after the sheet has closed
/// itself (its future then completes with false).
///
/// [invitee] is the newcomer's progress on this phone's link. The moment it
/// leaves [RoomInviteeProgress.waiting] the code folds into the two phones
/// finding each other — so the person holding this phone sees their friend
/// arriving instead of a code nobody needs any more — and if that attempt
/// falls through, the code comes back, still good.
Future<bool> showOneScanRoomInviteSheet(
  BuildContext context, {
  RoomRepository? repository,
  RoomTransportIdentityLifecycle? identityLifecycle,
  HotspotLinkKeeper? hotspotLinkKeeper,
  TransferRepository? transferRepository,
  Future<RoomInviteLink?>? link,
  LinkPreparingKind? linkKind,
  VoidCallback? onShown,
  Future<void>? dismissWhen,
  Future<RoomInviteLink?> Function()? onRetryLink,
  VoidCallback? onScanInstead,
  ValueListenable<RoomInviteeProgress>? invitee,
}) async {
  final rooms =
      repository ??
      (GetIt.instance.isRegistered<RoomRepository>()
          ? GetIt.instance<RoomRepository>()
          : null);
  SavedRoom? saved;
  try {
    final selected = await rooms?.selectedRoomId();
    saved = selected == null ? null : await rooms?.get(selected);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.getString.room_start_failed)),
      );
    }
    return false;
  }
  if (!context.mounted) return false;
  // Asked before any paywall: a member who cannot invite must not be sent to
  // a subscription screen for an act they are not allowed to perform. The
  // sheet re-checks on issue, and every other phone re-verifies the signed
  // grant chain, so this is the courtesy — not the enforcement.
  if (saved != null && !canInviteFrom(saved)) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.getString.people_cannot_invite)),
    );
    return false;
  }
  if (saved != null &&
      GetIt.instance.isRegistered<LicenseGate>() &&
      RoomAccessPolicy.inviteRequiresPremium(
        saved.room.confirmedMembers.length,
      ) &&
      !await openSubscriptionGate(context, PremiumFeature.groupRooms)) {
    return false;
  }
  if (!context.mounted) return false;
  if (GetIt.instance.isRegistered<LicenseGate>() &&
      !await openSubscriptionGate(context, PremiumFeature.wifiTransport)) {
    return false;
  }
  if (!context.mounted) return false;
  return await showModalBottomSheet<bool>(
        context: context,
        routeSettings: const RouteSettings(name: 'RoomInviteSheet'),
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        // Material 3 caps a bottom sheet at 640 wide, which leaves this one
        // floating in the middle of a landscape phone or a tablet. The code is
        // the whole point of the sheet; it gets all the width there is, the
        // same edge-to-edge panel (less the shell's margin) as on a phone.
        constraints: const BoxConstraints(),
        barrierColor: Colors.black.withValues(alpha: 0.62),
        builder: (_) => OneScanRoomInviteSheet(
          repository: repository,
          identityLifecycle: identityLifecycle,
          hotspotLinkKeeper: hotspotLinkKeeper,
          transferRepository: transferRepository,
          link: link,
          linkKind: linkKind,
          onShown: onShown,
          dismissWhen: dismissWhen,
          onRetryLink: onRetryLink,
          onScanInstead: onScanInstead,
          invitee: invitee,
        ),
      ) ??
      false;
}

/// Whether this phone may show an invite for [saved] at all.
///
/// The one rule every invite surface asks, so none of them can drift into
/// offering a control that only fails once tapped.
bool canInviteFrom(SavedRoom saved) =>
    !saved.room.archived &&
    saved.membership.active &&
    saved.membership.canManageInvites;

/// Everything needed to re-sign the code on screen without opening a second
/// seat: flipping "can invite" changes only the certificate, never the member.
final class _InviteMint {
  const _InviteMint({
    required this.identity,
    required this.room,
    required this.memberId,
    required this.memberKeyPair,
    required this.expiresAt,
  });

  final RoomTransportIdentityLifecycle identity;
  final SavedRoom room;
  final RoomMemberId memberId;
  final RoomMemberTransportKeyPair memberKeyPair;
  final DateTime expiresAt;

  Future<RoomDirectJoinBundle> sign({required bool grantInvite}) async {
    final certificate = await identity.issueMemberCertificate(
      issuerRoom: room,
      memberId: memberId,
      memberPublicKey: memberKeyPair.publicKey,
      grantInvite: grantInvite,
    );
    final bundle = RoomDirectJoinBundle(
      memberId: memberId,
      snapshot: RoomAcceptedJoinSnapshot.fromSavedRoom(
        room,
        acceptedMemberId: memberId,
        // Mirrors the signed grant; the joining phone ignores it and reads
        // the certificate.
        grantsInviteManagement: certificate.canInvite,
      ),
      memberKeyPair: memberKeyPair,
      certificate: certificate,
      expiresAt: expiresAt,
    );
    return bundle;
  }
}

class OneScanRoomInviteSheet extends StatefulWidget {
  const OneScanRoomInviteSheet({
    super.key,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.link,
    this.linkKind,
    this.onShown,
    this.dismissWhen,
    this.onRetryLink,
    this.onScanInstead,
    this.invitee,
  });

  final RoomRepository? repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;

  /// This phone's link, being brought up for this invite. While it is
  /// pending the sheet says it is getting ready; null from it is a failure,
  /// and the sheet then shows no code at all rather than one that cannot
  /// connect.
  final Future<RoomInviteLink?>? link;

  /// Which link [link] is bringing up. Null means a hotspot when [link] is
  /// set, and no link at all otherwise.
  final LinkPreparingKind? linkKind;

  /// Called once, when the code on screen carries a network to join.
  final VoidCallback? onShown;

  /// Completes when the sheet should close on its own (the call is opening).
  final Future<void>? dismissWhen;

  /// Asked by Try again for a fresh [link] after it failed. The opener owns
  /// the link, so it is the one that can clean up the failed attempt (a
  /// half-started hotspot, a Bluetooth host that never advertised) before
  /// raising another. The sheet never raises a link itself: null leaves a
  /// failed link with Close (and [onScanInstead]) only.
  final Future<RoomInviteLink?> Function()? onRetryLink;

  /// Swaps roles by hand: closes the sheet and has this phone scan the other
  /// one's code instead. Null hides the choice.
  final VoidCallback? onScanInstead;

  /// The newcomer's progress on this phone's link; see
  /// [showOneScanRoomInviteSheet].
  final ValueListenable<RoomInviteeProgress>? invitee;

  @override
  State<OneScanRoomInviteSheet> createState() => _OneScanRoomInviteSheetState();
}

class _OneScanRoomInviteSheetState extends State<OneScanRoomInviteSheet> {
  RoomRepository get _repository =>
      widget.repository ?? GetIt.instance<RoomRepository>();

  HotspotLinkKeeper? get _keeper =>
      widget.hotspotLinkKeeper ??
      (GetIt.instance.isRegistered<HotspotLinkKeeper>()
          ? GetIt.instance<HotspotLinkKeeper>()
          : null);

  TransferRepository? get _transfer =>
      widget.transferRepository ??
      (GetIt.instance.isRegistered<TransferRepository>()
          ? GetIt.instance<TransferRepository>()
          : null);

  String? _roomName;
  String? _roomInvite;
  HotspotCredentials? _credentials;
  bool _hostRecovering = false;
  bool _loading = true;

  /// A reason no retry can change (this phone may not invite at all).
  String? _error;

  /// Writing the code itself failed; Try again writes it afresh.
  bool _issueFailed = false;

  /// Bumped by every Try again, so a link from an attempt that was given up
  /// on cannot land on top of the one being made now.
  int _linkAttempt = 0;

  /// Set from the first Try again on, so the wait can say it is trying again.
  bool _retried = false;

  /// The code's ingredients, kept so the grant can be flipped in place.
  _InviteMint? _mint;

  /// Whether this phone may pass the invite right on at all. False hides the
  /// choice entirely rather than offering one that would be refused.
  bool _canGrant = false;

  /// Whether the code on screen lets its holder invite others.
  ///
  /// On by default (ITEM 10). A Room is a group of riders who know each
  /// other, and "my mate can't add his brother at the fuel stop" was the
  /// failure reported; the host who wants a closed group turns it off with
  /// one tap on the code itself. Guests are never invited from here.
  bool _grantInvites = true;
  bool _regranting = false;

  /// The link [OneScanRoomInviteSheet.link] brought up.
  RoomInviteLink? _hosted;
  bool _hostingPending = false;
  bool _hostingFailed = false;
  bool _shownReported = false;
  StreamSubscription<HotspotLinkState>? _stateSub;
  StreamSubscription<HotspotCredentials>? _credentialsSub;

  bool get _isTransportHost => _transfer?.sessionRole == SessionRole.host;

  /// What the arrival scene is showing. Starts at the code being read, so
  /// the brackets that framed the code are what fold into the link.
  JourneyStage _arrival = JourneyStage.scanned;

  /// Set when an arrival fell through and the code came back.
  bool _arrivalLost = false;

  RoomInviteeProgress get _invitee =>
      widget.invitee?.value ?? RoomInviteeProgress.waiting;

  void _onInvitee() {
    if (!mounted) return;
    final progress = _invitee;
    setState(() {
      switch (progress) {
        case RoomInviteeProgress.waiting:
          // Back to the code, which is still good, with a word that the last
          // try did not make it — not a silent jump.
          if (_arrival != JourneyStage.scanned) _arrivalLost = true;
          _arrival = JourneyStage.scanned;
        case RoomInviteeProgress.connecting:
          _arrivalLost = false;
          // The read beat plays first; the scene moves on to linking by
          // itself once it has landed.
          if (_arrival == JourneyStage.scanned) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _invitee != RoomInviteeProgress.connecting) {
                return;
              }
              setState(() => _arrival = JourneyStage.linking);
            });
          }
        case RoomInviteeProgress.connected:
          _arrivalLost = false;
          _arrival = JourneyStage.established;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final keeper = _keeper;
    if (keeper != null) {
      _syncKeeper(keeper);
      _stateSub = keeper.states.listen((_) {
        if (!mounted) return;
        setState(() => _syncKeeper(keeper));
      });
      _credentialsSub = keeper.credentialChanges.listen((credentials) {
        if (!mounted) return;
        setState(() {
          _credentials = _isTransportHost ? credentials : null;
          _hostRecovering = false;
        });
      });
    }
    widget.invitee?.addListener(_onInvitee);
    final link = widget.link;
    if (link != null) {
      _hostingPending = true;
      unawaited(_awaitHosting(link, _linkAttempt));
    }
    widget.dismissWhen?.then((_) => _dismiss());
    unawaited(_issue());
  }

  Future<void> _awaitHosting(
    Future<RoomInviteLink?> pending,
    int attempt,
  ) async {
    RoomInviteLink? link;
    try {
      link = await pending;
    } catch (_) {
      link = null;
    }
    if (!mounted || attempt != _linkAttempt) return;
    setState(() {
      _hostingPending = false;
      _hosted = link;
      _hostingFailed = link == null;
    });
    _reportShown();
  }

  /// Whether Try again can do anything about what failed.
  bool get _canRetry {
    if (_error != null) return false;
    if (_issueFailed) return true;
    if (!_hostingFailed) return false;
    return widget.onRetryLink != null;
  }

  /// Try again: the whole preparation over, in place.
  ///
  /// Whatever failed is redone and nothing that worked is: a code that was
  /// already signed keeps its seat (so nobody gains a second row on the
  /// roster), and a link that came up is kept. The tile on screen plays its
  /// failure backwards into the beacon and carries on from there.
  void _retry() {
    if (!_canRetry) return;
    HapticFeedback.selectionClick();
    final reissue = _issueFailed || _roomInvite == null;
    final relink = _hostingFailed;
    final attempt = ++_linkAttempt;
    setState(() {
      _retried = true;
      _issueFailed = false;
      if (reissue) _loading = true;
      if (relink) {
        _hostingFailed = false;
        _hostingPending = true;
      }
    });
    if (relink) unawaited(_awaitHosting(_relink(), attempt));
    if (reissue) unawaited(_issue());
  }

  /// A fresh link from the opener, which owns the radios: the sheet only
  /// wraps an already-issued membership and never starts a link itself.
  Future<RoomInviteLink?> _relink() async {
    final opener = widget.onRetryLink;
    if (opener == null) return null;
    return opener();
  }

  /// Closes the sheet and hands over to scanning the other phone's code.
  void _scanInstead() {
    final swap = widget.onScanInstead;
    if (swap == null) return;
    HapticFeedback.selectionClick();
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      Navigator.of(context).pop(false);
    } else if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
    swap();
  }

  /// Tells the opener, once, that a code carrying a network is on screen.
  void _reportShown() {
    if (_shownReported || widget.onShown == null) return;
    if (_roomInvite == null || _networkLink == null) return;
    _shownReported = true;
    widget.onShown!();
  }

  /// Closes this sheet, and only this sheet: something else may have been
  /// pushed over it meanwhile, and a plain pop would close that instead.
  void _dismiss() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// A live call's hotspot (which can be re-hosted with fresh credentials)
  /// wins over the link raised for this sheet.
  RoomInviteLink? get _networkLink {
    final live = _credentials;
    return live != null ? HotspotInviteLink(live) : _hosted;
  }

  void _syncKeeper(HotspotLinkKeeper keeper) {
    final host = _isTransportHost;
    _hostRecovering = host && keeper.state == HotspotLinkState.recovering;
    _credentials = host && keeper.state == HotspotLinkState.up
        ? keeper.credentials
        : null;
  }

  @override
  void didUpdateWidget(OneScanRoomInviteSheet old) {
    super.didUpdateWidget(old);
    if (old.invitee == widget.invitee) return;
    old.invitee?.removeListener(_onInvitee);
    widget.invitee?.addListener(_onInvitee);
  }

  @override
  void dispose() {
    widget.invitee?.removeListener(_onInvitee);
    unawaited(_stateSub?.cancel());
    unawaited(_credentialsSub?.cancel());
    super.dispose();
  }

  Future<void> _issue() async {
    try {
      final selectedId = await _repository.selectedRoomId();
      final saved = selectedId == null
          ? null
          : await _repository.get(selectedId);
      if (saved == null || !canInviteFrom(saved)) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = context.getString.people_cannot_invite;
        });
        return;
      }
      // The Room's name heads the sheet from the start, while the link and
      // the code are still on their way, so nothing above the code shifts
      // when it lands.
      if (!mounted) return;
      setState(() => _roomName = saved.room.name);

      if (RoomAccessPolicy.inviteRequiresPremium(
            saved.room.confirmedMembers.length,
          ) &&
          GetIt.instance.isRegistered<LicenseGate>() &&
          !await openSubscriptionGate(context, PremiumFeature.groupRooms)) {
        if (mounted) Navigator.of(context).pop(false);
        return;
      }
      if (!mounted) return;
      final invite = await _repository.issueInvite(
        saved.room.id,
        kind: RoomInvitationKind.trustedMembership,
        now: DateTime.now().toUtc(),
        ttl: const Duration(hours: 12),
      );
      final verified = await _repository.verifyAndRedeemInvite(
        invite,
        now: DateTime.now().toUtc(),
      );
      if (verified == null) {
        throw StateError('Room invite verification failed');
      }
      final fa =
          mounted && Localizations.localeOf(context).languageCode == 'fa';
      final accepted = await _repository.acceptVerifiedInvite(
        verified,
        displayName: heldSeatNameFor(fa: fa),
        acceptedAt: DateTime.now().toUtc(),
        pending: true,
        heldUntil: invite.expiresAt,
      );
      final memberId = RoomMemberId(invite.invitationId.substring(0, 24));
      final identity =
          widget.identityLifecycle ??
          RoomTransportIdentityLifecycle(
            store: PlatformRoomTransportIdentitySecureStore(),
          );
      final memberKeyPair = await identity.createPendingMemberKeyPair();
      final mint = _InviteMint(
        identity: identity,
        room: accepted,
        memberId: memberId,
        memberKeyPair: memberKeyPair,
        expiresAt: invite.expiresAt,
      );
      final canGrant = await identity.canGrantInvites(accepted);
      final grant = canGrant && _grantInvites;
      final bundle = await mint.sign(grantInvite: grant);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _mint = mint;
        _canGrant = canGrant;
        _grantInvites = grant;
        _roomName = accepted.room.name;
        _roomInvite = bundle.encode();
        _loading = false;
        _error = null;
      });
      _reportShown();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _issueFailed = true;
      });
    }
  }

  /// Re-signs the code on screen with or without the invite right.
  ///
  /// Same seat, same member, same key pair: only the certificate's grant
  /// changes, so a code someone has *already* scanned is unaffected and the
  /// roster does not gain a second row for one person.
  Future<void> _setGrant(bool value) async {
    final mint = _mint;
    if (mint == null || _regranting || value == _grantInvites) return;
    final previous = _grantInvites;
    setState(() {
      _grantInvites = value;
      _regranting = true;
    });
    try {
      final bundle = await mint.sign(grantInvite: value);
      if (!mounted) return;
      setState(() {
        _roomInvite = bundle.encode();
        _regranting = false;
      });
    } catch (_) {
      if (!mounted) return;
      // The code on screen still says what it said before; so must the row.
      setState(() {
        _grantInvites = previous;
        _regranting = false;
      });
    }
  }

  String? get _payload {
    final roomInvite = _roomInvite;
    if (roomInvite == null) return null;
    final link = _networkLink;
    // Asked for a link and none came up: a membership-only code would let
    // them into the Room and leave them with no way to reach this phone.
    if (widget.link != null && link == null) return null;
    return link == null ? roomInvite : link.payload(roomInvite);
  }

  /// Which link the wait is for.
  LinkPreparingKind get _linkKind {
    if (_hostRecovering) return LinkPreparingKind.hotspot;
    return widget.linkKind ??
        (widget.link != null
            ? LinkPreparingKind.hotspot
            : LinkPreparingKind.code);
  }

  /// Still waiting on the link, the code, or a hotspot being re-raised.
  bool get _preparing =>
      (_hostingPending && _error == null && !_issueFailed) ||
      _loading ||
      (_hostRecovering && _roomInvite != null);

  /// What went wrong, in one plain sentence, once nothing is pending.
  String _failureReason(BuildContext context) {
    final s = context.getString;
    if (_error case final error?) return error;
    if (_hostingFailed) {
      return _linkKind == LinkPreparingKind.bluetooth
          ? s.rcv_invite_bluetooth_failed
          : s.rcv_invite_host_failed;
    }
    return s.rcv_invite_issue_failed;
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
        // The sheet grows by the buttons' height once the code is up, rather
        // than jumping.
        child: AnimatedSize(
          duration: AppMotion.sheet,
          curve: AppMotion.easeOut,
          alignment: Alignment.bottomCenter,
          child: PhaseSwitcher(
            alignment: Alignment.center,
            child: _body(context),
          ),
        ),
      ),
    );
  }

  /// The two phones finding each other, where the code was.
  Widget _arrivalBody(BuildContext context) {
    final s = context.getString;
    final connected = _arrival == JourneyStage.established;
    return Column(
      key: const ValueKey('one-scan-room-invite-arrival'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(title: s.people_invite_title, subtitle: _roomName ?? ''),
        ConnectionJourney(
          key: const Key('one-scan-room-invite-journey'),
          stage: _arrival,
          link: _linkKind == LinkPreparingKind.bluetooth
              ? JourneyLink.bluetooth
              : JourneyLink.hotspot,
          title: connected
              ? s.rcv_invitee_connected_title
              : s.rcv_invitee_connecting_title,
          detail: connected
              ? s.rcv_invitee_connected_detail
              : s.rcv_invitee_connecting_detail,
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final preparing = _preparing;
    final payload = preparing ? null : _payload;
    final failed = !preparing && payload == null;
    if (payload != null && _invitee != RoomInviteeProgress.waiting) {
      return _arrivalBody(context);
    }
    // One layout for the wait, the code and a failure: the title, the code's
    // square and the line under it hold their places, and what changes
    // inside them changes in place — the beacon resolving into the code (or
    // faltering into a failure, and back again on Try again), the caption
    // into the hint or the reason, the buttons arriving last.
    return Column(
      key: const ValueKey('one-scan-room-invite-flow'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(
          title: context.getString.people_invite_title,
          subtitle: _roomName ?? '',
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            // As big as the sheet allows, up to 270: on a narrow phone the
            // card's brackets used to run into the sheet's edges.
            final room =
                constraints.maxWidth - LinkPreparingVisual.extentFor(0);
            final baseSize = math.min(270.0, room);
            // A long code (a member's delegated invite riding a Wi-Fi code)
            // gets a bigger tile rather than smaller squares, and grows into
            // it as the beacon resolves instead of jumping.
            final targetSize = payload == null
                ? baseSize
                : QrBrandPlan.sizeFor(payload, preferred: baseSize, max: room);
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(end: targetSize),
              duration: AppMotion.reduced(context)
                  ? Duration.zero
                  : AppMotion.sheet,
              curve: AppMotion.easeOut,
              builder: (context, qrSize, _) => Center(
                child: LinkPreparingVisual(
                  // Nothing to raise when this phone may not invite at all:
                  // the failure is told over the code it cannot write.
                  kind: _error != null ? LinkPreparingKind.code : _linkKind,
                  qrSize: qrSize,
                  failed: failed,
                  ready: payload == null
                      ? null
                      // A flip of the grant is a different code, and the swap
                      // says so: the old one recedes as the new one settles,
                      // instead of the modules silently rearranging under
                      // someone's camera.
                      : AnimatedSwitcher(
                          duration: AppMotion.reduced(context)
                              ? AppMotion.chip
                              : AppMotion.sheet,
                          switchInCurve: AppMotion.easeOut,
                          switchOutCurve: AppMotion.leaving,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: AppMotion.reduced(context)
                                    ? child
                                    : ScaleTransition(
                                        scale: Tween<double>(
                                          begin: 0.94,
                                          end: 1,
                                        ).animate(animation),
                                        child: child,
                                      ),
                              ),
                          child: KeyedSubtree(
                            key: ValueKey(_grantInvites),
                            child: GlowingQrCard(
                              key: const Key('one-scan-room-invite-qr'),
                              data: payload,
                              size: qrSize,
                            ),
                          ),
                        ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        PhaseSwitcher(
          child: failed
              ? _FailureCaption(
                  key: const Key('one-scan-room-invite-unavailable'),
                  title: _error != null
                      ? context.getString.people_invite_title
                      : context.getString.rcv_invite_failed_title,
                  reason: _failureReason(context),
                )
              : payload == null
              ? LinkPreparingCaption(
                  key: const Key('one-scan-room-invite-preparing'),
                  kind: _linkKind,
                  title: _retried
                      ? context.getString.rcv_invite_retrying
                      : null,
                )
              : Text(
                  _arrivalLost
                      ? context.getString.rcv_invitee_lost
                      : context.getString.people_invite_hint,
                  key: ValueKey(
                    _arrivalLost
                        ? 'one-scan-room-invite-lost'
                        : 'one-scan-room-invite-hint',
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
        ),
        if (payload != null && _canGrant) ...[
          const SizedBox(height: 14),
          RoomInviteGrantToggle(
            value: _grantInvites,
            enabled: !_regranting,
            onChanged: (value) => unawaited(_setGrant(value)),
          ),
        ],
        if (payload != null) ...[
          const SizedBox(height: 18),
          _InviteActions(payload: payload),
          if (widget.onScanInstead != null) ...[
            const SizedBox(height: 10),
            _ScanInsteadLink(onTap: _scanInstead),
          ],
        ],
        if (failed) ...[
          const SizedBox(height: 18),
          _FailureActions(
            onRetry: _canRetry ? _retry : null,
            onScanInstead: widget.onScanInstead == null || _error != null
                ? null
                : _scanInstead,
          ),
        ],
      ],
    );
  }
}

/// What failed, under the faltered beacon: a short headline and the reason.
class _FailureCaption extends StatelessWidget {
  const _FailureCaption({required this.title, required this.reason, super.key});

  final String title;
  final String reason;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          reason,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

/// Try again, big and first; the swap and the way out under it.
class _FailureActions extends StatelessWidget {
  const _FailureActions({required this.onRetry, required this.onScanInstead});

  final VoidCallback? onRetry;
  final VoidCallback? onScanInstead;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final retry = onRetry;
    final scan = onScanInstead;
    return StaggeredEntrance(
      builder: (context, children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            children[i],
          ],
        ],
      ),
      children: [
        if (retry != null)
          FilledButton.icon(
            key: const Key('one-scan-room-invite-retry'),
            onPressed: retry,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(
              s.reconnect_retry,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
        if (scan != null)
          OutlinedButton.icon(
            key: const Key('one-scan-room-invite-scan-instead'),
            onPressed: scan,
            icon: const Icon(Icons.photo_camera_rounded),
            label: Text(s.reconnect_switch_to_scan),
          ),
        TextButton(
          key: const Key('one-scan-room-invite-close'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(s.rcv_close),
        ),
      ],
    );
  }
}

/// The swap, offered quietly while the code is up: for when the newcomer's
/// phone could not join this one and is showing its own code instead.
class _ScanInsteadLink extends StatelessWidget {
  const _ScanInsteadLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.rcv_invite_scan_hint,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        TextButton.icon(
          key: const Key('one-scan-room-invite-scan-instead'),
          onPressed: onTap,
          icon: const Icon(Icons.photo_camera_rounded, size: 18),
          label: Text(
            s.reconnect_switch_to_scan,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Copy and Done, rising in once there is something to copy.
class _InviteActions extends StatelessWidget {
  const _InviteActions({required this.payload});

  final String payload;

  @override
  Widget build(BuildContext context) => StaggeredEntrance(
    builder: (context, children) => Row(
      children: [
        Expanded(child: children[0]),
        const SizedBox(width: 10),
        Expanded(child: children[1]),
      ],
    ),
    children: [
      OutlinedButton.icon(
        key: const Key('one-scan-room-invite-copy'),
        onPressed: () => Clipboard.setData(ClipboardData(text: payload)),
        icon: const Icon(Icons.copy_rounded),
        label: Text(context.getString.people_copy_invite),
      ),
      FilledButton.icon(
        key: const Key('one-scan-room-invite-done'),
        onPressed: () => Navigator.of(context).pop(false),
        icon: const Icon(Icons.check_rounded),
        label: Text(context.getString.people_done),
      ),
    ],
  );
}

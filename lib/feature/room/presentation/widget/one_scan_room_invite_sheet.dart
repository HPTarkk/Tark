import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
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

/// Opens the low-distraction Add person flow used from an active Room.
///
/// The normal path deliberately has exactly one actionable QR. When this
/// phone is the current hotspot host, that QR remains a standards-compliant
/// Wi-Fi payload but carries the durable Room invite as a Tark extension.
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
/// has proven themselves and the call is opening.
Future<bool> showOneScanRoomInviteSheet(
  BuildContext context, {
  RoomRepository? repository,
  RoomTransportIdentityLifecycle? identityLifecycle,
  HotspotLinkKeeper? hotspotLinkKeeper,
  TransferRepository? transferRepository,
  Future<RoomInviteLink?>? link,
  VoidCallback? onShown,
  Future<void>? dismissWhen,
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
        barrierColor: Colors.black.withValues(alpha: 0.62),
        builder: (_) => OneScanRoomInviteSheet(
          repository: repository,
          identityLifecycle: identityLifecycle,
          hotspotLinkKeeper: hotspotLinkKeeper,
          transferRepository: transferRepository,
          link: link,
          onShown: onShown,
          dismissWhen: dismissWhen,
        ),
      ) ??
      false;
}

class OneScanRoomInviteSheet extends StatefulWidget {
  const OneScanRoomInviteSheet({
    super.key,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.link,
    this.onShown,
    this.dismissWhen,
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

  /// Called once, when the code on screen carries a network to join.
  final VoidCallback? onShown;

  /// Completes when the sheet should close on its own (the call is opening).
  final Future<void>? dismissWhen;

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
  String? _error;

  /// The link [OneScanRoomInviteSheet.link] brought up.
  RoomInviteLink? _hosted;
  bool _hostingPending = false;
  bool _hostingFailed = false;
  bool _shownReported = false;
  StreamSubscription<HotspotLinkState>? _stateSub;
  StreamSubscription<HotspotCredentials>? _credentialsSub;

  bool get _isTransportHost => _transfer?.sessionRole == SessionRole.host;

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
    final link = widget.link;
    if (link != null) {
      _hostingPending = true;
      unawaited(_awaitHosting(link));
    }
    widget.dismissWhen?.then((_) => _dismiss());
    unawaited(_issue());
  }

  Future<void> _awaitHosting(Future<RoomInviteLink?> pending) async {
    RoomInviteLink? link;
    try {
      link = await pending;
    } catch (_) {
      link = null;
    }
    if (!mounted) return;
    setState(() {
      _hostingPending = false;
      _hosted = link;
      _hostingFailed = link == null;
    });
    _reportShown();
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
  void dispose() {
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
      if (saved == null ||
          saved.room.archived ||
          !saved.membership.active ||
          !saved.membership.canManageInvites) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = context.getString.people_cannot_invite;
        });
        return;
      }

      if (!mounted) return;
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
      final certificate = await identity.issueMemberCertificate(
        issuerRoom: accepted,
        memberId: memberId,
        memberPublicKey: memberKeyPair.publicKey,
      );
      final bundle = RoomDirectJoinBundle(
        memberId: memberId,
        snapshot: RoomAcceptedJoinSnapshot.fromSavedRoom(
          accepted,
          acceptedMemberId: memberId,
          grantsInviteManagement: false,
        ),
        memberKeyPair: memberKeyPair,
        certificate: certificate,
        expiresAt: invite.expiresAt,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
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
        _error = context.getString.people_issue_error;
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

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_hostingPending && _error == null) {
      return SizedBox(
        key: const Key('one-scan-room-invite-preparing'),
        height: 300,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(
              context.getString.reconnect_preparing,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    if (_loading || (_hostRecovering && _roomInvite != null)) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final payload = _payload;
    if (payload == null) {
      return SizedBox(
        key: const Key('one-scan-room-invite-unavailable'),
        height: 220,
        child: Center(
          child: Text(
            _error ??
                (_hostingFailed
                    ? context.getString.invite_host_failed
                    : context.getString.people_issue_error),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(
          title: context.getString.people_invite_title,
          subtitle: _roomName ?? '',
        ),
        const SizedBox(height: 16),
        Center(
          child: GlowingQrCard(
            key: const Key('one-scan-room-invite-qr'),
            data: payload,
            size: 270,
            branded:
                payload.length <= RoomDirectJoinBundle.brandableEncodedLength,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          context.getString.people_invite_hint,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('one-scan-room-invite-copy'),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: payload)),
                icon: const Icon(Icons.copy_rounded),
                label: Text(context.getString.people_copy_invite),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                key: const Key('one-scan-room-invite-done'),
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.check_rounded),
                label: Text(context.getString.people_done),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

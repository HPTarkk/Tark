import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

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
/// [bootstrapHost] is the pre-live creator path. It raises Tark's temporary
/// hotspot behind this loading sheet before the QR is minted, so Create Room →
/// Invite has the same one-scan contract as Add person inside an active call.
Future<void> showOneScanRoomInviteSheet(
  BuildContext context, {
  RoomRepository? repository,
  RoomTransportIdentityLifecycle? identityLifecycle,
  HotspotLinkKeeper? hotspotLinkKeeper,
  TransferRepository? transferRepository,
  bool bootstrapHost = false,
  PreLiveHotspotBootstrap? preLiveBootstrap,
}) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  barrierColor: Colors.black.withValues(alpha: 0.62),
  builder: (_) => OneScanRoomInviteSheet(
    repository: repository,
    identityLifecycle: identityLifecycle,
    hotspotLinkKeeper: hotspotLinkKeeper,
    transferRepository: transferRepository,
    bootstrapHost: bootstrapHost,
    preLiveBootstrap: preLiveBootstrap,
  ),
);

class OneScanRoomInviteSheet extends StatefulWidget {
  const OneScanRoomInviteSheet({
    super.key,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.bootstrapHost = false,
    this.preLiveBootstrap,
  });

  final RoomRepository? repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;

  /// True only when this sheet is opened by the creator before any transport
  /// exists. The normal in-call path already owns its live attachment and must
  /// never start another hotspot just because Add person was tapped.
  final bool bootstrapHost;

  /// Deterministic test seam around the transfer feature's hidden bridge.
  final PreLiveHotspotBootstrap? preLiveBootstrap;

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
  StreamSubscription<HotspotLinkState>? _stateSub;
  StreamSubscription<HotspotCredentials>? _credentialsSub;

  bool get _isTransportHost => _transfer?.sessionRole == SessionRole.host;

  /// A pre-live creator is known to be the bootstrap host before a live
  /// TransferRepository exists. Once live, the ordinary session role is the
  /// authority. Keeping those two facts explicit prevents an early keeper
  /// callback from clearing credentials the hidden bootstrap just produced.
  bool get _shouldCarryHotspot => widget.bootstrapHost || _isTransportHost;

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
          _credentials = _shouldCarryHotspot ? credentials : null;
          _hostRecovering = false;
        });
      });
    }
    unawaited(_issue());
  }

  void _syncKeeper(HotspotLinkKeeper keeper) {
    final host = _shouldCarryHotspot;
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

      // The creator's first invite needs a network before it needs a seat: the
      // one QR must contain both membership and the temporary carrier. This is
      // hidden behind the sheet rather than sending the user through Host / Join
      // screens. The transfer feature owns the actual radio state machine.
      if (widget.bootstrapHost && _credentials == null) {
        final credentials =
            await (widget.preLiveBootstrap ?? PreLiveHotspotBootstrap())
                .prepareHost();
        if (credentials == null) {
          throw StateError('Pre-live hotspot bootstrap failed');
        }
        if (!mounted) return;
        setState(() => _credentials = credentials);
      }

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
    final credentials = _credentials;
    return credentials == null
        ? roomInvite
        : credentials.qrPayload(roomInvite: roomInvite);
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
    if (_loading || (_hostRecovering && _roomInvite != null)) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final payload = _payload;
    if (payload == null) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Text(
            _error ?? context.getString.people_issue_error,
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
                onPressed: () => Navigator.of(context).pop(),
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

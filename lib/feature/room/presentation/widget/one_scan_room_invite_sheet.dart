import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/proximity/room_proximity_control_session_registry.dart';
import '../../data/proximity/room_proximity_join_carrier.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_acceptance_coordinator.dart';
import '../../domain/service/room_invite_join_exchange.dart';

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
  final bool bootstrapHost;
  final PreLiveHotspotBootstrap? preLiveBootstrap;

  @override
  State<OneScanRoomInviteSheet> createState() => _OneScanRoomInviteSheetState();
}

class _OneScanRoomInviteSheetState extends State<OneScanRoomInviteSheet> {
  RoomRepository get _repository =>
      widget.repository ?? GetIt.instance<RoomRepository>();

  final RoomProximityControlChannel _control = RoomProximityControlChannel();
  RoomProximityJoinIssuerSession? _issuerSession;
  bool _registryOwnsControl = false;

  String? _roomName;
  String? _roomInvite;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_issue());
  }

  @override
  void dispose() {
    if (!_registryOwnsControl) {
      unawaited(_issuerSession?.dispose());
      unawaited(_control.dispose());
    }
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

      final invite = await _repository.issueInvite(
        saved.room.id,
        kind: RoomInvitationKind.trustedMembership,
        now: DateTime.now().toUtc(),
        ttl: const Duration(hours: 12),
      );
      final identity =
          widget.identityLifecycle ??
          RoomTransportIdentityLifecycle(
            store: PlatformRoomTransportIdentitySecureStore(),
          );
      final exchange = RoomInviteJoinExchange(
        acceptance: RoomInviteAcceptanceCoordinator(_repository),
        requireMembershipReceipt: true,
        issueCertificate:
            ({
              required acceptedRoom,
              required memberId,
              required memberPublicKey,
            }) => identity.issueMemberCertificate(
              issuerRoom: acceptedRoom,
              memberId: memberId,
              memberPublicKey: memberPublicKey,
            ),
      );

      final issuerSession = RoomProximityJoinIssuerSession(
        channel: _control,
        invitation: invite,
        exchange: exchange,
        repository: _repository,
      );
      _issuerSession = issuerSession;

      // The native RFCOMM bridge owns one socket at a time. Add person is an
      // explicit handoff to a new control peer, so release the previous
      // proximity socket before asking native code to listen again. Durable
      // Room membership and an established Wi-Fi live attachment are separate
      // planes and remain intact.
      await RoomProximityControlSessionRegistry.instance.clear(
        roomId: saved.room.id,
      );
      await _control.host(rendezvousToken: invite.invitationId);
      await RoomProximityControlSessionRegistry.instance.adopt(
        roomId: saved.room.id,
        invitation: invite,
        channel: _control,
        disposeProtocol: issuerSession.dispose,
      );
      _registryOwnsControl = true;

      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _roomName = saved.room.name;
        _roomInvite = invite.encode();
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
    if (_loading) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final payload = _roomInvite;
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
            branded: true,
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

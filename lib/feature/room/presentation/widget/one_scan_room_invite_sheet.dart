import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../../transfer/domain/entity/room_rendezvous_identity.dart';
import '../../data/proximity/room_proximity_control_session_registry.dart';
import '../../data/proximity/room_proximity_join_carrier.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_acceptance_coordinator.dart';
import '../../domain/service/room_invite_join_exchange.dart';
import '../room_bluetooth_permissions.dart';
import '../room_member_display_name.dart';

export '../room_bluetooth_permissions.dart';

/// Completes with true when somebody joined through the invite, which is the
/// caller's cue to start the Room hand-off.
Future<bool> showOneScanRoomInviteSheet(
  BuildContext context, {
  RoomRepository? repository,
  RoomTransportIdentityLifecycle? identityLifecycle,
  HotspotLinkKeeper? hotspotLinkKeeper,
  TransferRepository? transferRepository,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (_) => OneScanRoomInviteSheet(
        repository: repository,
        identityLifecycle: identityLifecycle,
        hotspotLinkKeeper: hotspotLinkKeeper,
        transferRepository: transferRepository,
      ),
    ) ??
    false;

class OneScanRoomInviteSheet extends StatefulWidget {
  const OneScanRoomInviteSheet({
    super.key,
    this.repository,
    this.identityLifecycle,
    this.hotspotLinkKeeper,
    this.transferRepository,
    this.controlChannel,
    this.permissionGate,
  });

  final RoomRepository? repository;
  final RoomTransportIdentityLifecycle? identityLifecycle;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final TransferRepository? transferRepository;
  final RoomProximityControlChannel? controlChannel;
  final RoomInvitePermissionGate? permissionGate;

  @override
  State<OneScanRoomInviteSheet> createState() => _OneScanRoomInviteSheetState();
}

class _OneScanRoomInviteSheetState extends State<OneScanRoomInviteSheet> {
  /// How long the invite stays findable. Android grants discoverability for
  /// 300s at most (see `ClassicBluetoothEngine.requestDiscoverable`); past it
  /// the QR on screen still looks usable while nobody can reach this phone
  /// with it, which is worse than saying so.
  static const _visibleFor = Duration(seconds: 290);

  /// Long enough to read a name, short enough not to be waited on.
  static const _joinedBeat = Duration(milliseconds: 1400);

  RoomRepository get _repository =>
      widget.repository ?? GetIt.instance<RoomRepository>();

  HotspotCredentials? _currentLiveHotspotCredentials() {
    HotspotLinkKeeper? keeper = widget.hotspotLinkKeeper;
    if (keeper == null) {
      try {
        if (GetIt.instance.isRegistered<HotspotLinkKeeper>()) {
          keeper = GetIt.instance<HotspotLinkKeeper>();
        }
      } catch (_) {}
    }
    if (keeper == null || keeper.state != HotspotLinkState.up) return null;
    return keeper.credentials;
  }

  late RoomProximityControlChannel _control =
      widget.controlChannel ?? RoomProximityControlChannel();
  RoomProximityJoinIssuerSession? _issuerSession;
  bool _registryOwnsControl = false;

  /// Whether [_control] has been asked to host. A channel that got that far
  /// cannot be reused by a retry; one that never did can.
  bool _hostAttempted = false;

  RoomId? _roomId;
  Set<RoomMemberId> _confirmedAtIssue = const {};
  StreamSubscription<void>? _roomChanges;
  Timer? _visibility;

  String? _roomName;
  String? _roomInvite;
  String? _joinedName;
  bool _loading = true;
  bool _paused = false;
  String? _error;
  bool _retryable = true;
  bool _permissionError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_issue());
  }

  @override
  void dispose() {
    _visibility?.cancel();
    unawaited(_roomChanges?.cancel());
    if (!_registryOwnsControl) {
      unawaited(_issuerSession?.dispose());
      unawaited(_control.dispose());
    }
    super.dispose();
  }

  Future<void> _issue() async {
    var stage = 'load_room';
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
          _retryable = false;
          _error = context.getString.people_cannot_invite;
        });
        return;
      }

      stage = 'permissions';
      final permitted =
          await (widget.permissionGate ??
              ensureRoomInviteBluetoothPermissions)();
      if (!permitted) {
        throw const _RoomInvitePermissionDenied();
      }
      Logger.diagnostic('room_invite: permissions ok');

      stage = 'issue_invitation';
      final invite = await _repository.issueInvite(
        saved.room.id,
        kind: RoomInvitationKind.trustedMembership,
        now: DateTime.now().toUtc(),
        ttl: const Duration(hours: 12),
      );
      final rendezvous = await RoomRendezvousIdentity.derive(
        invite.invitationId,
      );
      Logger.diagnostic(
        'room_invite: issued correlation=${rendezvous.correlation}',
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
      stage = 'clear_previous_proximity';
      await RoomProximityControlSessionRegistry.instance.clear(
        roomId: saved.room.id,
      );
      stage = 'host_proximity';
      _hostAttempted = true;
      await _control.host(rendezvousToken: invite.invitationId);
      // Closed while Android's visibility prompt was up. Nothing has adopted
      // the socket, so dispose() already released it — adopting it now would
      // leave the registry holding a closed channel.
      if (!mounted) return;
      stage = 'adopt_proximity';
      await RoomProximityControlSessionRegistry.instance.adopt(
        roomId: saved.room.id,
        invitation: invite,
        channel: _control,
        disposeProtocol: issuerSession.dispose,
        currentHotspotCredentials: _currentLiveHotspotCredentials,
        issuer: true,
      );
      _registryOwnsControl = true;

      stage = 'render_invitation';
      if (!mounted) return;
      Logger.diagnostic(
        'room_invite: qr ready correlation=${rendezvous.correlation}',
      );
      HapticFeedback.mediumImpact();
      setState(() {
        _roomId = saved.room.id;
        _confirmedAtIssue = {
          for (final member in saved.room.confirmedMembers) member.id,
        };
        _roomName = saved.room.name;
        _roomInvite = invite.encode();
        _loading = false;
        _paused = false;
        _error = null;
        _permissionError = false;
      });
      _watchForArrival();
      _visibility?.cancel();
      _visibility = Timer(_visibleFor, _pause);
    } catch (error) {
      Logger.diagnostic(
        'room_invite: failed stage=$stage error=${_safeInviteError(error)}',
      );
      if (!mounted) return;
      final s = context.getString;
      setState(() {
        _loading = false;
        // The chip will not learn to advertise on a second try.
        _retryable =
            !(error is RoomProximityException &&
                error.failure == RoomProximityFailure.advertisingUnsupported);
        _permissionError = error is _RoomInvitePermissionDenied;
        _error = switch (error) {
          _RoomInvitePermissionDenied() => s.people_invite_permission,
          RoomProximityException(
            failure: RoomProximityFailure.discoverabilityDenied,
          ) =>
            s.people_invite_visible,
          RoomProximityException(
            failure: RoomProximityFailure.advertisingUnsupported,
          ) =>
            s.people_invite_unsupported,
          _ => s.people_issue_error,
        };
      });
    }
  }

  /// The host's half of "they come straight in": the moment the person who
  /// scanned is confirmed, start the same Room hand-off as the joiner.  Merely
  /// dismissing this sheet left the host at a passive lobby, so the joiner had
  /// nobody to answer its authenticated hotspot request and users were driven
  /// into the generic second-QR connection screen.
  void _watchForArrival() {
    unawaited(_roomChanges?.cancel());
    _roomChanges = _repository.changes.listen(
      (_) => unawaited(_checkArrival()),
    );
  }

  Future<void> _checkArrival() async {
    final roomId = _roomId;
    if (roomId == null || _joinedName != null) return;
    final SavedRoom? saved;
    try {
      saved = await _repository.get(roomId);
    } catch (_) {
      return;
    }
    if (!mounted || saved == null || _joinedName != null) return;
    final arrived = saved.room.confirmedMembers.where(
      (member) => !_confirmedAtIssue.contains(member.id),
    );
    if (arrived.isEmpty) return;
    _visibility?.cancel();
    HapticFeedback.heavyImpact();
    setState(() {
      _joinedName = roomMemberDisplayName(
        arrived.first,
        fa: Localizations.localeOf(context).languageCode == 'fa',
        unnamed: context.getString.people_unnamed,
      );
    });
    await Future<void>.delayed(_joinedBeat);
    if (!mounted) return;
    // As a sheet, hand the arrival back to whoever opened it. Navigating to
    // the walkie route from here did nothing: the lobby that opens this sheet
    // already *is* that route, go_router kept the page (its key ignores the
    // query), and the host sat on "joined" with the sheet still up while the
    // joiner waited a minute for a hotspot nobody was raising.
    if (ModalRoute.of(context) is PopupRoute) {
      Navigator.of(context).pop(true);
      return;
    }
    context.goNamed(
      AppRoutes.walkieName,
      queryParameters: const {'start': 'true'},
    );
  }

  void _pause() {
    if (!mounted || _joinedName != null || _roomInvite == null) return;
    setState(() => _paused = true);
  }

  /// Starts over with a fresh invite and, when the last attempt got as far as
  /// Bluetooth, a fresh socket. An adopted one is released by the registry
  /// clear inside [_issue]; one that never got adopted is released here.
  Future<void> _retry() async {
    HapticFeedback.selectionClick();
    _visibility?.cancel();
    await _roomChanges?.cancel();
    _roomChanges = null;
    if (_hostAttempted) {
      if (!_registryOwnsControl) {
        await _issuerSession?.dispose();
        await _control.dispose();
      }
      _control = widget.controlChannel ?? RoomProximityControlChannel();
      _hostAttempted = false;
    }
    _issuerSession = null;
    _registryOwnsControl = false;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _paused = false;
      _error = null;
      _permissionError = false;
      _roomInvite = null;
    });
    await _issue();
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
        child: AnimatedSwitcher(
          duration: AppMotion.card,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final s = context.getString;
    if (_loading) {
      return const SizedBox(
        key: ValueKey('invite-loading'),
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final joined = _joinedName;
    if (joined != null) {
      return _InviteJoined(key: const ValueKey('invite-joined'), name: joined);
    }
    final payload = _roomInvite;
    if (payload == null) {
      return _InviteFailure(
        key: const ValueKey('invite-failed'),
        message: _error ?? s.people_issue_error,
        onRetry: _retryable ? () => unawaited(_retry()) : null,
        onOpenSettings: _permissionError
            ? () => unawaited(openAppSettings())
            : null,
      );
    }
    return Column(
      key: const ValueKey('invite-showing'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitle(title: s.people_invite_title, subtitle: _roomName ?? ''),
        const SizedBox(height: 16),
        Center(
          child: _paused
              ? _InvitePaused(onShowAgain: () => unawaited(_retry()))
              : GlowingQrCard(
                  key: const Key('one-scan-room-invite-qr'),
                  data: payload,
                  size: 270,
                  branded: true,
                ),
        ),
        if (!_paused) ...[
          const SizedBox(height: 10),
          Text(
            s.people_invite_hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 18),
        // No copy button: the invite is redeemed by a camera standing next to
        // this phone, over Bluetooth, and nothing in the app can join from a
        // pasted string. A copied bearer invite could only ever leak.
        FilledButton.icon(
          key: const Key('one-scan-room-invite-done'),
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.check_rounded),
          label: Text(s.people_done),
        ),
      ],
    );
  }
}

class _InviteJoined extends StatelessWidget {
  const _InviteJoined({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: SizedBox(
        key: const Key('one-scan-room-invite-joined'),
        height: 300,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.green.withValues(alpha: 0.12),
                  border: Border.all(
                    color: AppColors.green.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  Icons.check_rounded,
                  color: AppColors.green,
                  size: 40,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                context.getString.people_invite_joined(name),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvitePaused extends StatelessWidget {
  const _InvitePaused({required this.onShowAgain});

  final VoidCallback onShowAgain;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      key: const Key('one-scan-room-invite-paused'),
      width: 270,
      height: 270,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer_off_outlined,
            color: AppColors.textSecondary,
            size: 36,
          ),
          const SizedBox(height: 12),
          Text(
            s.people_invite_paused,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('one-scan-room-invite-show-again'),
            onPressed: onShowAgain,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(s.people_invite_show_again),
          ),
        ],
      ),
    );
  }
}

class _InviteFailure extends StatelessWidget {
  const _InviteFailure({
    required this.message,
    this.onRetry,
    this.onOpenSettings,
    super.key,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final retry = onRetry;
    final settings = onOpenSettings;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.info_outline_rounded, color: AppColors.amber, size: 36),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          if (retry != null || settings != null) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                if (settings != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('one-scan-room-invite-settings'),
                      onPressed: settings,
                      icon: const Icon(Icons.settings_rounded),
                      label: Text(s.roomjoin_open_settings),
                    ),
                  ),
                if (settings != null && retry != null)
                  const SizedBox(width: 10),
                if (retry != null)
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('one-scan-room-invite-retry'),
                      onPressed: retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(s.retry),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

final class _RoomInvitePermissionDenied implements Exception {
  const _RoomInvitePermissionDenied();
}

String _safeInviteError(Object error) {
  if (error is RoomProximityException) return 'proximity:${error.failure.name}';
  if (error is PlatformException) return 'platform:${error.code}';
  if (error is _RoomInvitePermissionDenied) return 'permission_denied';
  if (error is FormatException) return 'format';
  if (error is StateError) return 'state';
  return error.runtimeType.toString();
}

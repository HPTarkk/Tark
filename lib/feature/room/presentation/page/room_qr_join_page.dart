import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/widget/qr_scanner_surface.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/proximity/room_proximity_control_session_registry.dart';
import '../../data/proximity/room_proximity_join_carrier.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/service/room_invite_join_orchestrator.dart';
import '../manager/room_list_cubit.dart';

class RoomQrJoinPage extends StatefulWidget {
  const RoomQrJoinPage({required this.cubit, super.key});

  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: Builder(
      builder: (context) =>
          RoomQrJoinPage(cubit: context.read<RoomListCubit>()),
    ),
  );

  final RoomListCubit cubit;

  @override
  State<RoomQrJoinPage> createState() => _RoomQrJoinPageState();
}

class _RoomQrJoinPageState extends State<RoomQrJoinPage> {
  String? _error;
  bool _joining = false;

  Future<bool> _onCode(String raw) async {
    if (_joining) return false;
    _joining = true;
    RoomProximityControlChannel? control;
    RoomProximityJoinCarrier? carrier;
    var registryOwnsControl = false;
    try {
      final invitation = RoomInvitation.decode(raw);
      if (invitation.isExpired) {
        throw const FormatException('expired room invite');
      }

      var myName = 'Tark';
      try {
        final stored = await GetIt.instance<SettingsRepository>().getMyName();
        if (stored.trim().isNotEmpty) myName = stored.trim();
      } catch (_) {}
      if (!mounted) return false;

      control = RoomProximityControlChannel();
      await control.connect(rendezvousToken: invitation.invitationId);
      if (!mounted) return false;
      carrier = RoomProximityJoinCarrier(
        channel: control,
        invitation: invitation,
      );
      final status = await widget.cubit.joinByInvite(
        invitation: invitation,
        displayName: myName,
        carrier: carrier,
      );
      if (!mounted) return false;
      if (status == RoomInviteJoinAttemptStatus.accepted) {
        await RoomProximityControlSessionRegistry.instance.adopt(
          roomId: invitation.roomId,
          invitation: invitation,
          channel: control,
          disposeProtocol: carrier.dispose,
        );
        registryOwnsControl = true;
        if (!mounted) return false;
        context.go(AppRoutes.walkiePath);
        return true;
      }
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    } on FormatException {
      if (!mounted) return false;
      return _notAnInvite(raw);
    } catch (_) {
      if (!mounted) return false;
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    } finally {
      if (!registryOwnsControl) {
        await carrier?.dispose();
        await control?.dispose();
      }
      _joining = false;
    }
  }

  bool _notAnInvite(String raw) {
    final network = ScannedCode.parse(raw);
    if (network != null) {
      context.push(ConnectRoute.forScannedNetwork(), extra: raw);
      return true;
    }

    // Builds before the proximity-control migration minted direct Room QR
    // payloads under this prefix. They are deliberately no longer imported as
    // membership, but a damaged/expired one is still recognisably a Tark Room
    // invite and should not be described as an unrelated QR code.
    if (raw.trimLeft().toLowerCase().startsWith('tark-room:')) {
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    }

    setState(() => _error = context.getString.roomjoin_not_our_code);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('room-join-one-scan'),
      label: context.getString.roomjoin_hint,
      child: QrScannerSurface(
        title: context.getString.roomjoin_title,
        hint: context.getString.roomjoin_hint,
        searchingLabel: context.getString.roomjoin_searching,
        lockedLabel: context.getString.roomjoin_locked,
        busyLabel: context.getString.roomjoin_joining,
        cameraDeniedLabel: context.getString.roomjoin_camera_denied,
        cameraFailedLabel: context.getString.roomjoin_camera_failed,
        openSettingsLabel: context.getString.roomjoin_open_settings,
        errorText: _error,
        onCode: _onCode,
      ),
    );
  }
}

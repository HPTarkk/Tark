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
import '../room_bluetooth_permissions.dart';

class RoomQrJoinPage extends StatefulWidget {
  const RoomQrJoinPage({
    required this.cubit,
    this.permissionGate,
    this.controlChannelFactory,
    super.key,
  });

  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: Builder(
      builder: (context) =>
          RoomQrJoinPage(cubit: context.read<RoomListCubit>()),
    ),
  );

  final RoomListCubit cubit;

  /// Seams for tests. Production asks for the Bluetooth permissions the
  /// rendezvous needs and dials over a fresh control channel.
  final RoomInvitePermissionGate? permissionGate;
  final RoomProximityControlChannel Function()? controlChannelFactory;

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

      // The rendezvous below scans for the host and dials it over Bluetooth.
      // Nothing on a clean install has asked for that yet, and without it the
      // scan simply finds nobody — so ask here, where the person has just
      // shown exactly the intent the prompt is about.
      final permitted =
          await (widget.permissionGate ??
              ensureRoomInviteBluetoothPermissions)();
      if (!mounted) return false;
      if (!permitted) {
        setState(
          () => _error = context.getString.roomjoin_bluetooth_permission,
        );
        return false;
      }

      var myName = 'Tark';
      try {
        final stored = await GetIt.instance<SettingsRepository>().getMyName();
        if (stored.trim().isNotEmpty) myName = stored.trim();
      } catch (_) {}
      if (!mounted) return false;

      control =
          (widget.controlChannelFactory ?? RoomProximityControlChannel.new)();
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
        // Straight on to connecting, over the socket that just carried the
        // join. Scanning was this person's whole part; stopping at the lobby
        // to ask "start?" would have two people coordinating a second tap
        // across two phones.
        context.goNamed(
          AppRoutes.walkieName,
          queryParameters: const {'start': 'true'},
        );
        return true;
      }
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    } on FormatException {
      if (!mounted) return false;
      return _notAnInvite(raw);
    } on RoomProximityException catch (error) {
      if (!mounted) return false;
      setState(() => _error = _proximityMessage(error.failure));
      return false;
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

  String _proximityMessage(RoomProximityFailure failure) {
    final s = context.getString;
    return switch (failure) {
      RoomProximityFailure.bluetoothOff => s.roomjoin_bluetooth_off,
      RoomProximityFailure.hostNotFound => s.roomjoin_host_not_found,
      RoomProximityFailure.discoverabilityDenied ||
      RoomProximityFailure.scanFailed ||
      RoomProximityFailure.hostSetupFailed ||
      RoomProximityFailure.dialFailed => s.roomjoin_not_joined,
    };
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
      setState(() => _error = context.getString.roomjoin_invalid);
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

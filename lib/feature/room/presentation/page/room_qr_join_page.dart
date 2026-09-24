import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/widget/qr_scanner_surface.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../../transfer/domain/entity/room_rendezvous_identity.dart';
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
    this.locationGate,
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
  final RoomScanLocationGate? locationGate;
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
      final rendezvous = await RoomRendezvousIdentity.derive(
        invitation.invitationId,
      );
      Logger.diagnostic(
        'room_join: qr decoded correlation=${rendezvous.correlation}',
      );

      // The rendezvous below scans for the host and dials it over Bluetooth.
      // Nothing on a clean install has asked for that yet, and without it the
      // scan simply finds nobody — so ask here, where the person has just
      // shown exactly the intent the prompt is about.
      final permitted =
          await (widget.permissionGate ??
              ensureRoomInviteBluetoothPermissions)();
      if (!mounted) return false;
      if (!permitted) {
        Logger.diagnostic(
          'room_join: permissions denied correlation=${rendezvous.correlation}',
        );
        setState(
          () => _error = context.getString.roomjoin_bluetooth_permission,
        );
        return false;
      }
      Logger.diagnostic(
        'room_join: permissions ok correlation=${rendezvous.correlation}',
      );
      final locationReady =
          await (widget.locationGate ?? roomScanLocationReady)();
      if (!mounted) return false;
      if (!locationReady) {
        Logger.diagnostic(
          'room_join: location off correlation=${rendezvous.correlation}',
        );
        setState(() => _error = context.getString.roomjoin_location_off);
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
        Logger.diagnostic(
          'room_join: membership confirmed correlation=${rendezvous.correlation}',
        );
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
      Logger.diagnostic(
        'room_join: proximity failed reason=${error.failure.name}',
      );
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
      RoomProximityFailure.advertisingUnsupported ||
      RoomProximityFailure.dialFailed => s.roomjoin_not_joined,
    };
  }

  bool _notAnInvite(String raw) {
    final network = ScannedCode.parse(raw);
    if (network != null) {
      context.push(ConnectRoute.forScannedNetwork(), extra: raw);
      return true;
    }

    // A Room invite that is expired, damaged or from another app version is
    // still a Tark invite. Calling it "not a Tarkk code" sent people looking
    // for some other QR on the host's phone when the fix was a fresh invite
    // or an update.
    switch (_inviteShape(raw)) {
      case _InviteShape.otherVersion:
        setState(() => _error = context.getString.roomjoin_other_version);
        return false;
      case _InviteShape.invite:
        setState(() => _error = context.getString.roomjoin_invalid);
        return false;
      case null:
        break;
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

  /// Whether [raw] is shaped like a Room invite, without trusting any of it.
  static _InviteShape? _inviteShape(String raw) {
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw.trim()))),
      );
      if (value is! Map<String, dynamic>) return null;
      if (!value.containsKey('invitationId') || !value.containsKey('roomId')) {
        return null;
      }
      return value['v'] == RoomInvitation.currentVersion
          ? _InviteShape.invite
          : _InviteShape.otherVersion;
    } catch (_) {
      return null;
    }
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

enum _InviteShape { invite, otherVersion }

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
import '../../../transfer/api/pre_live_hotspot_bootstrap.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../manager/room_list_cubit.dart';

/// One-scan Room entry. Membership is persisted before transport setup.
///
/// A current host can carry its Wi-Fi bootstrap and the durable Room invite in
/// the same standard `WIFI:` QR. Tark validates/persists the Room half first,
/// then hands that exact already-scanned payload to the hotspot bridge. The
/// camera never opens a second time and transport remains an implementation
/// detail rather than a user decision.
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

  /// Accepts a scanned payload, returning whether this screen is leaving.
  ///
  /// The surface stays locked and green on true and re-arms on false, so a bad
  /// code never strands the user on a dead camera — they simply point it at a
  /// fresh one.
  Future<bool> _onCode(String raw) async {
    if (_joining) return false;
    _joining = true;
    try {
      // A one-scan live invite is still a standards-compliant Wi-Fi QR; its
      // Room token is an opaque Tark extension. Ordinary Room QR codes have no
      // network wrapper, so the raw value remains the fallback.
      final scanned = ScannedCode.parse(raw);
      final roomRaw = scanned?.roomInvite ?? raw;
      final bundle = RoomDirectJoinBundle.decode(roomRaw);

      // Read before joining so the roster is right the first time it is drawn.
      // A name that appears a beat later reads as the app correcting itself.
      var myName = '';
      try {
        myName = await GetIt.instance<SettingsRepository>().getMyName();
      } catch (_) {
        // Joining offline must not depend on settings storage. Without a name
        // the host's placeholder stands, which is survivable; being unable to
        // join at all is not.
      }
      if (!mounted) return false;
      final joined = await widget.cubit.joinDirect(
        bundle,
        localDisplayName: myName,
      );
      if (!mounted) return false;
      if (joined) {
        final credentials = scanned?.credentials;
        if (credentials != null) {
          if (GetIt.instance.isRegistered<SessionRoleStore>()) {
            GetIt.instance<SessionRoleStore>().setRole(SessionRole.joiner);
          }
          final result = await PreLiveHotspotBootstrap().joinHost(credentials);
          if (!mounted) return false;
          if (result != HotspotJoinResult.joined) {
            setState(() => _error = context.getString.roomjoin_not_joined);
            return false;
          }
          if (GetIt.instance.isRegistered<TransferModeStore>()) {
            await GetIt.instance<TransferModeStore>().setMode(TransferMode.hotspot);
          }
          if (!mounted) return false;
          context.go('${AppRoutes.walkiePath}?ride=true&start=true');
        } else {
          context.go('${AppRoutes.walkiePath}?start=true');
        }
        return true;
      }
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    } on FormatException {
      if (!mounted) return false;
      return _notAnInvite(raw);
    } finally {
      _joining = false;
    }
  }

  /// What to do with a code that has no valid durable Room invite.
  ///
  /// Legacy/network-only Wi-Fi QR codes remain useful: they can still put the
  /// rider on the host's link even though they cannot establish durable Room
  /// membership. Current in-Room invites no longer need this fallback because
  /// they carry both halves in the one scanned payload.
  ///
  /// The payload rides in `extra` rather than in the query string on purpose:
  /// it contains the network's passphrase.
  bool _notAnInvite(String raw) {
    final network = ScannedCode.parse(raw);
    if (network != null) {
      context.push(ConnectRoute.forScannedNetwork(), extra: raw);
      // Leaving, so the frame stays locked rather than re-arming a camera
      // behind a page that is on its way out.
      return true;
    }
    // Nothing left to do but say so — and say the right one. "Invalid or
    // expired" is honest about a code that really is one of ours and a lie
    // about a bus ticket.
    setState(
      () => _error = RoomDirectJoinBundle.looksLikeInvite(raw)
          ? context.getString.roomjoin_invalid
          : context.getString.roomjoin_not_our_code,
    );
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

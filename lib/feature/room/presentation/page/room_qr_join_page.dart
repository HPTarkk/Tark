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
import '../../domain/entity/room_direct_join_bundle.dart';
import '../manager/room_list_cubit.dart';

/// One-scan Room entry. Membership is persisted before transport setup.
///
/// Wears the same viewfinder as the hotspot scanner and the same amber
/// brackets as the invite QR it is pointed at, so the handoff reads as one
/// instrument rather than three unrelated screens.
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

  /// Accepts a scanned payload, returning whether this screen is leaving.
  ///
  /// The surface stays locked and green on true and re-arms on false, so a bad
  /// code never strands the user on a dead camera — they simply point it at a
  /// fresh one.
  Future<bool> _onCode(String raw) async {
    try {
      final bundle = RoomDirectJoinBundle.decode(raw);
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
        context.go(AppRoutes.walkiePath);
        return true;
      }
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    } on FormatException {
      if (!mounted) return false;
      return _notAnInvite(raw);
    }
  }

  /// What to do with a code that decoded as anything but a Room invite.
  ///
  /// **There are two QR codes in this app.** The bridge shows the host's Wi-Fi
  /// credentials; the People sheet shows a Room invite. They are deliberately
  /// the same instrument at both ends — this page's own doc says it "wears the
  /// same viewfinder as the hotspot scanner and the same amber brackets as the
  /// invite QR", so the handoff reads as one thing — and that is precisely
  /// what makes them confusable. Nothing on either screen said which of the
  /// two it eats, so a rider standing in front of a perfectly good hotspot
  /// code was told their invite had expired.
  ///
  /// So the wrong pairing stops being an error and becomes a route. The code
  /// carries a network and, since the unified payload, the host's channel with
  /// it — and voice is filtered on the channel rather than on Room membership,
  /// so following it puts this phone on the host's network *and* in the host's
  /// conversation. Not a Room member, which is a different and durable thing;
  /// but heard, which is what somebody holding a camera up to a code is
  /// asking for.
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

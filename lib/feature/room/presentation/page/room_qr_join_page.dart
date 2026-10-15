import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/route_exit.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../../core/widget/journey_carry_over.dart';
import '../../../../core/widget/qr_scanner_surface.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../../domain/entity/room_invite_link.dart';
import '../bluetooth_invite_joiner.dart';
import '../manager/room_list_cubit.dart';

/// One-scan Room entry. Membership is persisted before transport setup.
///
/// A current host can carry its Wi-Fi bootstrap and the durable Room invite in
/// the same standard `WIFI:` QR. Tarkk validates/persists the Room half first,
/// then hands that exact already-scanned payload to the hotspot bridge. The
/// camera never opens a second time and transport remains an implementation
/// detail rather than a user decision.
class RoomQrJoinPage extends StatefulWidget {
  const RoomQrJoinPage({required this.cubit, this.bluetoothJoiner, super.key});

  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: Builder(
      builder: (context) =>
          RoomQrJoinPage(cubit: context.read<RoomListCubit>()),
    ),
  );

  final RoomListCubit cubit;

  /// Reaches the host of a Bluetooth invite. A seam for tests; the default
  /// uses the phone's radio.
  final BluetoothInviteJoiner? bluetoothJoiner;

  @override
  State<RoomQrJoinPage> createState() => _RoomQrJoinPageState();
}

class _RoomQrJoinPageState extends State<RoomQrJoinPage> {
  String? _error;
  bool _joining = false;

  /// Set once a valid invite has been read and saved and the phone is
  /// reaching the other one. The camera is gone from then on: the scanned
  /// code folds into the link being made, and a failure is told there, with
  /// the way back to a fresh camera, instead of as red text over a preview
  /// that keeps running behind a code it already read.
  _Journey? _journey;

  /// Bumps for every fresh scanner, so "Scan again" mounts a new camera
  /// rather than reviving the one that was released.
  int _scannerGeneration = 0;

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
      // Room token is an opaque Tarkk extension. Ordinary Room QR codes have no
      // network wrapper, so the raw value remains the fallback.
      final scanned = ScannedCode.parse(raw);
      final bluetooth = BluetoothInviteLink.tryParse(raw);
      final roomRaw = scanned?.roomInvite ?? bluetooth?.roomInvite ?? raw;
      final bundle = RoomDirectJoinBundle.decode(roomRaw);
      if (await widget.cubit.needsMoreRoomsAccess(
            existingRoom: bundle.snapshot.roomId,
          ) &&
          mounted &&
          !await openSubscriptionGate(context, PremiumFeature.extraRooms)) {
        return false;
      }
      if (!mounted) return false;
      final confirmed = bundle.snapshot.members
          .where((member) => !member.pending)
          .length;
      if (RoomAccessPolicy.requiresPremium(confirmed) &&
          GetIt.instance.isRegistered<LicenseGate>() &&
          !await openSubscriptionGate(context, PremiumFeature.groupRooms)) {
        return false;
      }
      if (!mounted) return false;

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
        if (bluetooth != null) {
          _beginJourney(JourneyLink.bluetooth, bundle.snapshot.roomName);
          final problem = await _joinOverBluetooth(bluetooth.link);
          if (!mounted) return true;
          if (problem != null) {
            _journeyFailed(problem);
            return true;
          }
          _enterChannel();
        } else if (credentials != null) {
          if (GetIt.instance.isRegistered<LicenseGate>() &&
              !await openSubscriptionGate(
                context,
                PremiumFeature.wifiTransport,
              )) {
            return false;
          }
          if (!mounted) return false;
          if (GetIt.instance.isRegistered<SessionRoleStore>()) {
            GetIt.instance<SessionRoleStore>().setRole(SessionRole.joiner);
          }
          _beginJourney(JourneyLink.hotspot, bundle.snapshot.roomName);
          final result = await PreLiveHotspotBootstrap().joinHost(credentials);
          if (!mounted) return true;
          if (result != HotspotJoinResult.joined) {
            _journeyFailed(_hotspotProblem(result));
            return true;
          }
          if (GetIt.instance.isRegistered<TransferModeStore>()) {
            final modes = GetIt.instance<TransferModeStore>();
            // Same reasoning as Bluetooth: a Bluetooth preference on this
            // phone would refuse the hotspot it was just handed.
            if (modes.pinnedMode == TransferMode.bluetooth) {
              await modes.setPinnedMode(null);
            }
            await modes.setMode(TransferMode.hotspot);
          }
          if (!mounted) return true;
          _enterChannel();
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
    } catch (error) {
      Logger.log('Room QR join failed: $error');
      if (!mounted) return false;
      if (_journey != null) {
        _journeyFailed(context.getString.roomjoin_not_joined);
        return true;
      }
      setState(() => _error = context.getString.roomjoin_not_joined);
      return false;
    } finally {
      _joining = false;
    }
  }

  void _beginJourney(JourneyLink link, String roomName) {
    setState(() {
      _error = null;
      _journey = _Journey(link: link, roomName: roomName);
    });
    // Let the scanned beat land, then show the link being made. The scene
    // queues the change itself until the tick is drawn.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final journey = _journey;
      if (!mounted || journey == null) return;
      if (journey.stage == JourneyStage.scanned) {
        setState(() => _journey = journey.copyWith(JourneyStage.linking));
      }
    });
  }

  void _journeyFailed(String problem) {
    final journey = _journey;
    if (journey == null) {
      setState(() => _error = problem);
      return;
    }
    setState(
      () => _journey = journey.copyWith(JourneyStage.failed, problem: problem),
    );
  }

  /// The network half is up: the channel's entry carries the same scene on
  /// through the Room's own handshake to the moment it opens.
  void _enterChannel() {
    final journey = _journey;
    context.go(
      '${AppRoutes.walkiePath}?ride=true&start=true',
      extra: journey == null
          ? null
          : JourneyCarryOver(link: journey.link, caption: journey.roomName),
    );
  }

  void _scanAgain() => setState(() {
    _journey = null;
    _error = null;
    _scannerGeneration++;
  });

  void _leave() => exitRouteTo(context, AppRoutes.landingPath);

  String _hotspotProblem(HotspotJoinResult result) {
    final s = context.getString;
    return switch (result) {
      HotspotJoinResult.wifiOff => s.reconnect_wifi_off,
      HotspotJoinResult.locationOff => s.roomjoin_location_off,
      _ => s.roomjoin_not_joined,
    };
  }

  /// The Bluetooth half of a one-scan invite, in words the rider can act on.
  /// Null once the audio link is up.
  ///
  /// Membership is already saved by now, so a failure here leaves a member
  /// who can simply scan again; nothing is half-joined.
  Future<String?> _joinOverBluetooth(BluetoothInviteLink link) async {
    if (GetIt.instance.isRegistered<SessionRoleStore>()) {
      GetIt.instance<SessionRoleStore>().setRole(SessionRole.joiner);
    }
    final result = await (widget.bluetoothJoiner ?? BluetoothInviteJoiner())
        .join(link);
    if (!mounted) return null;
    final s = context.getString;
    return switch (result) {
      BluetoothInviteJoinResult.joined => null,
      BluetoothInviteJoinResult.permissionDenied =>
        s.roomjoin_bluetooth_permission,
      BluetoothInviteJoinResult.locationOff => s.roomjoin_location_off,
      BluetoothInviteJoinResult.bluetoothOff => s.roomjoin_bluetooth_off,
      BluetoothInviteJoinResult.notFound => s.roomjoin_host_not_found,
    };
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
    final journey = _journey;
    return AnimatedSwitcher(
      duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.sheet,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      // The preview shrinks into the scene rather than cutting to it: the
      // camera's frame is where the tick is drawn.
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .94, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: journey == null
          ? KeyedSubtree(
              key: ValueKey('scanner-$_scannerGeneration'),
              child: _scanner(context),
            )
          : _journeyView(context, journey),
    );
  }

  Widget _journeyView(BuildContext context, _Journey journey) {
    final s = context.getString;
    final failed = journey.stage == JourneyStage.failed;
    return PopScope(
      key: const ValueKey('room-join-journey'),
      // Mid-link, back would strand a half-made connection; after a failure
      // it is simply the way out.
      canPop: failed,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: ConnectionJourney(
            stage: journey.stage,
            link: journey.link,
            caption: journey.roomName,
            title: switch (journey.stage) {
              JourneyStage.scanned => s.journey_scanned_title,
              JourneyStage.failed => s.journey_failed_title,
              _ => switch (journey.link) {
                JourneyLink.hotspot => s.journey_linking_hotspot_title,
                JourneyLink.bluetooth => s.journey_linking_bluetooth_title,
                JourneyLink.sharedWifi => s.journey_linking_wifi_title,
              },
            },
            detail: failed ? journey.problem : s.journey_linking_detail,
            actions: failed
                ? [
                    FilledButton(
                      key: const Key('room-join-scan-again'),
                      onPressed: _scanAgain,
                      child: Text(s.journey_scan_again),
                    ),
                    TextButton(
                      key: const Key('room-join-not-now'),
                      onPressed: _leave,
                      child: Text(s.journey_not_now),
                    ),
                  ]
                : const [],
          ),
        ),
      ),
    );
  }

  Widget _scanner(BuildContext context) {
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

class _Journey {
  const _Journey({
    required this.link,
    required this.roomName,
    this.stage = JourneyStage.scanned,
    this.problem,
  });

  final JourneyLink link;
  final String roomName;
  final JourneyStage stage;
  final String? problem;

  _Journey copyWith(JourneyStage stage, {String? problem}) =>
      _Journey(link: link, roomName: roomName, stage: stage, problem: problem);
}

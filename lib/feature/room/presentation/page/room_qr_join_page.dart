import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/entitlement/room_access_policy.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../../core/widget/qr_scanner_surface.dart';
import '../../../transfer/api/hotspot_invite_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/repository/room_rejoin_ticket_store.dart';
import '../../domain/entity/room.dart';
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
///
/// ## When the network half fails
///
/// By then this phone is already a member of the Room, so it is no longer
/// only the one that scans: it can be the one that shows a code. Failures are
/// counted for the visit; Try again (the same code, no camera) stays the
/// primary way forward until the second failure — or at once when the reason
/// says this phone cannot get onto the other phone's hotspot at all — and
/// then "Show my code instead" takes its place, with the other phone told to
/// swap too. It has to be told: until a link exists the two phones have no
/// way to agree on anything, so the inviting phone swaps by hand ("Scan their
/// code instead" on its invite sheet).
class RoomQrJoinPage extends StatefulWidget {
  const RoomQrJoinPage({
    required this.cubit,
    this.bluetoothJoiner,
    this.hotspotJoin,
    this.canShowCode,
    this.onShowCodeInstead,
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

  /// Reaches the host of a Bluetooth invite. A seam for tests; the default
  /// uses the phone's radio.
  final BluetoothInviteJoiner? bluetoothJoiner;

  /// Joins the inviting phone's hotspot. A seam for tests; the default is the
  /// Room's pre-live bootstrap.
  final Future<HotspotJoinResult> Function(HotspotCredentials)? hotspotJoin;

  /// Whether this phone can share a connection and so show a code of its own
  /// (Android). Null follows the platform; tests set it.
  final bool? canShowCode;

  /// Opens this phone's own code for [RoomId] after a failed join. Null opens
  /// the Room's guided reconnect on the showing side.
  final Future<void> Function(RoomId room)? onShowCodeInstead;

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

  /// The network half of the code that was read, kept so Try again can redo
  /// it without the camera.
  _NetworkHalf? _half;

  /// Failed network joins in this visit, across Try again and Scan again.
  int _failures = 0;

  bool get _canShowCode => widget.canShowCode ?? Platform.isAndroid;

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
          _half = _NetworkHalf(
            roomId: bundle.snapshot.roomId,
            roomName: bundle.snapshot.roomName,
            bluetooth: bluetooth,
          );
          _beginJourney(JourneyLink.bluetooth, bundle.snapshot.roomName);
          await _connect();
        } else if (credentials != null) {
          if (GetIt.instance.isRegistered<LicenseGate>() &&
              !await openSubscriptionGate(
                context,
                PremiumFeature.wifiTransport,
              )) {
            return false;
          }
          if (!mounted) return false;
          _half = _NetworkHalf(
            roomId: bundle.snapshot.roomId,
            roomName: bundle.snapshot.roomName,
            credentials: credentials,
          );
          _beginJourney(JourneyLink.hotspot, bundle.snapshot.roomName);
          await _connect();
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
        _journeyFailed(_JoinProblem.unknown);
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

  /// Runs the network half of [_half] — the first time, and on Try again.
  /// Membership is already saved, so this is only ever about reaching the
  /// other phone.
  Future<void> _connect() async {
    final half = _half;
    if (half == null) return;
    final bluetooth = half.bluetooth;
    try {
      final problem = bluetooth != null
          ? await _joinOverBluetooth(bluetooth.link)
          : await _joinHotspot(half.credentials!);
      if (!mounted) return;
      if (problem != null) {
        _journeyFailed(problem);
        return;
      }
      _enterChannel();
    } catch (error) {
      Logger.log('Room QR network join failed: $error');
      if (mounted) _journeyFailed(_JoinProblem.unknown);
    }
  }

  /// Joins the inviting phone's hotspot. Null once it is joined.
  Future<_JoinProblem?> _joinHotspot(HotspotCredentials credentials) async {
    if (GetIt.instance.isRegistered<SessionRoleStore>()) {
      GetIt.instance<SessionRoleStore>().setRole(SessionRole.joiner);
    }
    final join = widget.hotspotJoin;
    final result = join != null
        ? await join(credentials)
        : await PreLiveHotspotBootstrap().joinHost(credentials);
    if (!mounted) return null;
    if (result != HotspotJoinResult.joined) {
      return switch (result) {
        HotspotJoinResult.wifiOff => _JoinProblem.wifiOff,
        HotspotJoinResult.locationOff => _JoinProblem.locationOff,
        _ => _JoinProblem.declined,
      };
    }
    if (GetIt.instance.isRegistered<TransferModeStore>()) {
      final modes = GetIt.instance<TransferModeStore>();
      // Same reasoning as Bluetooth: a Bluetooth preference on this phone
      // would refuse the hotspot it was just handed.
      if (modes.pinnedMode == TransferMode.bluetooth) {
        await modes.setPinnedMode(null);
      }
      await modes.setMode(TransferMode.hotspot);
    }
    return null;
  }

  void _journeyFailed(_JoinProblem problem) {
    final journey = _journey;
    if (journey == null) {
      setState(() => _error = problem.explain(context.getString));
      return;
    }
    _failures++;
    Logger.diagnostic(
      'room_join: network half failed reason=${problem.name} '
      'count=$_failures',
    );
    setState(
      () => _journey = journey.copyWith(JourneyStage.failed, problem: problem),
    );
  }

  /// Try again: the same code, the same journey, no camera.
  void _retry() {
    final journey = _journey;
    if (journey == null || _half == null || _joining) return;
    HapticFeedback.selectionClick();
    _joining = true;
    setState(() => _journey = journey.copyWith(JourneyStage.linking));
    _connect().whenComplete(() => _joining = false);
  }

  /// Whether swapping roles is the better way forward now.
  bool _swapFirst(_Journey journey) =>
      _canSwap(journey) &&
      (_failures >= 2 || (journey.problem?.theirsUnreachable ?? false));

  /// Swapping needs this phone to share a connection, which is a hotspot.
  /// A Bluetooth invite is the free way in, and its recovery stays on
  /// Bluetooth rather than routing a free rider into a paid link.
  bool _canSwap(_Journey journey) =>
      _canShowCode && journey.link == JourneyLink.hotspot && _half != null;

  /// This phone is a member now, so it can be the one showing a code.
  Future<void> _showMyCode() async {
    final half = _half;
    if (half == null) return;
    HapticFeedback.selectionClick();
    Logger.diagnostic('room_join: swapping to show this phone code');
    final custom = widget.onShowCodeInstead;
    if (custom != null) {
      await custom(half.roomId);
      return;
    }
    // The Room's guided reconnect on the showing side. It is reached through
    // the way back into a Room (`rejoin`), told by a ticket that this phone
    // is the one sharing the connection — the same thing a phone that was
    // sharing before its app stopped is told.
    await RoomRejoinTicketStore().save(
      RoomRejoinTicket(
        roomId: half.roomId,
        mode: TransferMode.hotspot,
        side: SessionRole.host,
        at: DateTime.now(),
      ),
    );
    if (!mounted) return;
    context.go('${AppRoutes.walkiePath}?rejoin=true');
  }

  /// The network half is up: the channel's entry carries the same scene on
  /// through the Room's own handshake to the moment it opens.
  void _enterChannel() =>
      context.go('${AppRoutes.walkiePath}?ride=true&start=true');

  void _scanAgain() => setState(() {
    _journey = null;
    _error = null;
    _half = null;
    _scannerGeneration++;
  });

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.landingPath);
    }
  }

  /// The Bluetooth half of a one-scan invite. Null once the audio link is up.
  ///
  /// Membership is already saved by now, so a failure here leaves a member
  /// who can simply try again; nothing is half-joined.
  Future<_JoinProblem?> _joinOverBluetooth(BluetoothInviteLink link) async {
    if (GetIt.instance.isRegistered<SessionRoleStore>()) {
      GetIt.instance<SessionRoleStore>().setRole(SessionRole.joiner);
    }
    final result = await (widget.bluetoothJoiner ?? BluetoothInviteJoiner())
        .join(link);
    if (!mounted) return null;
    return switch (result) {
      BluetoothInviteJoinResult.joined => null,
      BluetoothInviteJoinResult.permissionDenied =>
        _JoinProblem.bluetoothPermission,
      BluetoothInviteJoinResult.locationOff => _JoinProblem.bluetoothLocation,
      BluetoothInviteJoinResult.bluetoothOff => _JoinProblem.bluetoothOff,
      BluetoothInviteJoinResult.notFound => _JoinProblem.bluetoothNotFound,
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
    final swapFirst = failed && _swapFirst(journey);
    final reason = journey.problem?.explain(s);
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
            detail: !failed
                ? s.journey_linking_detail
                : swapFirst
                ? '$reason\n${s.rcv_switch_hint}'
                : reason,
            actions: failed ? _recoveryActions(context, journey) : const [],
          ),
        ),
      ),
    );
  }

  /// The ways forward after a failed join, the better one first.
  List<Widget> _recoveryActions(BuildContext context, _Journey journey) {
    final s = context.getString;
    final swapFirst = _swapFirst(journey);
    final retry = _RecoveryButton(
      key: const Key('room-join-retry'),
      primary: !swapFirst,
      icon: Icons.refresh_rounded,
      label: s.reconnect_retry,
      onPressed: _retry,
    );
    final swap = _RecoveryButton(
      key: const Key('room-join-show-code'),
      primary: swapFirst,
      icon: Icons.qr_code_2_rounded,
      label: s.reconnect_switch_to_show,
      onPressed: () => _showMyCode(),
    );
    return [
      if (swapFirst) swap else retry,
      if (swapFirst) retry else if (_canSwap(journey)) swap,
      Row(
        children: [
          Expanded(
            child: TextButton(
              key: const Key('room-join-scan-again'),
              onPressed: _scanAgain,
              child: Text(s.journey_scan_again),
            ),
          ),
          Expanded(
            child: TextButton(
              key: const Key('room-join-not-now'),
              onPressed: _leave,
              child: Text(s.journey_not_now),
            ),
          ),
        ],
      ),
    ];
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

/// A filled primary or an outlined secondary, so the two recovery choices can
/// trade places without either one changing what it is.
class _RecoveryButton extends StatelessWidget {
  const _RecoveryButton({
    required this.primary,
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final bool primary;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    const padding = EdgeInsets.symmetric(vertical: 15);
    final text = Text(
      label,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
    );
    return primary
        ? FilledButton.icon(
            onPressed: onPressed,
            style: FilledButton.styleFrom(padding: padding, shape: shape),
            icon: Icon(icon),
            label: text,
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(padding: padding, shape: shape),
            icon: Icon(icon),
            label: text,
          );
  }
}

/// What was read off the code for reaching the other phone: one of the two.
class _NetworkHalf {
  const _NetworkHalf({
    required this.roomId,
    required this.roomName,
    this.credentials,
    this.bluetooth,
  });

  final RoomId roomId;
  final String roomName;
  final HotspotCredentials? credentials;
  final ({BluetoothInviteLink link, String roomInvite})? bluetooth;
}

/// Why the network half failed, as far as this phone can tell.
enum _JoinProblem {
  wifiOff,
  locationOff,

  /// Android would not put this phone on the other phone's hotspot. Asking
  /// again rarely changes that; showing this phone's code usually does.
  declined,
  bluetoothPermission,
  bluetoothLocation,
  bluetoothOff,
  bluetoothNotFound,

  /// Something threw; nothing more specific is known.
  unknown;

  /// Whether the reason says the other phone's connection cannot be joined
  /// from this one, so swapping roles should be offered first, at once.
  bool get theirsUnreachable => this == declined;

  String explain(AppLocalizations s) => switch (this) {
    wifiOff => s.rcv_reason_wifi_off,
    locationOff => s.rcv_reason_location_off,
    declined => s.rcv_reason_declined,
    bluetoothPermission => s.rcv_reason_bt_permission,
    bluetoothLocation => s.roomjoin_location_off,
    bluetoothOff => s.rcv_reason_bt_off,
    bluetoothNotFound => s.rcv_reason_bt_not_found,
    unknown => s.roomjoin_not_joined,
  };
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
  final _JoinProblem? problem;

  _Journey copyWith(JourneyStage stage, {_JoinProblem? problem}) =>
      _Journey(link: link, roomName: roomName, stage: stage, problem: problem);
}

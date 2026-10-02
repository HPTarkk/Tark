import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../data/repository/room_hotspot_history.dart';
import '../../domain/entity/room.dart';
import '../../domain/service/room_pre_live_announcer.dart';

/// What the phone that stayed in a live Room can do for someone who dropped
/// out, so that neither of them has to leave the Room and start over.
enum RoomAwayHelp {
  /// This phone shares the connection and still holds it up: show its code,
  /// for the other phone to scan if it cannot get back on by itself.
  showCode,

  /// The person who dropped was the one sharing the connection. It went with
  /// their app, so their phone shows a new code and this one scans it.
  scanCode,

  /// Nothing to do here: on a home Wi-Fi or a Bluetooth call the other phone
  /// finds its own way back, and in a bigger Room someone else shares.
  none,
}

/// Picks the [RoomAwayHelp] for one member who dropped out. Pure, so the rule
/// can be tested without a phone.
RoomAwayHelp resolveRoomAwayHelp({
  required TransferMode? mode,
  required SessionRole? side,
  required bool sharingNow,
  required bool memberWasSharing,
}) {
  if (mode != TransferMode.hotspot) return RoomAwayHelp.none;
  if (side == SessionRole.host && sharingNow) return RoomAwayHelp.showCode;
  if (side == SessionRole.joiner && memberWasSharing) {
    return RoomAwayHelp.scanCode;
  }
  return RoomAwayHelp.none;
}

/// Hands the live screen the one thing it cannot do on its own: swap itself
/// for the camera, scan the code a returning phone shows, and come back live.
class RoomLiveRejoinScope extends InheritedWidget {
  const RoomLiveRejoinScope({
    required this.onScanPeerCode,
    required super.child,
    super.key,
  });

  final VoidCallback onScanPeerCode;

  static RoomLiveRejoinScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RoomLiveRejoinScope>();

  @override
  bool updateShouldNotify(RoomLiveRejoinScope oldWidget) =>
      oldWidget.onScanPeerCode != onScanPeerCode;
}

/// The line and the one button under a member who dropped out.
///
/// It says who the Room is waiting for, and offers the code only when this
/// phone actually has a part to play in getting them back.
class RoomAwayMemberHelp extends StatefulWidget {
  const RoomAwayMemberHelp({
    required this.room,
    required this.member,
    required this.name,
    required this.back,
    super.key,
  });

  final SavedRoom room;
  final RoomMember member;
  final String name;

  /// Flips to true when the member is heard again, so an open code sheet can
  /// say so and close itself.
  final ValueListenable<bool> back;

  @override
  State<RoomAwayMemberHelp> createState() => _RoomAwayMemberHelpState();
}

class _RoomAwayMemberHelpState extends State<RoomAwayMemberHelp> {
  RoomAwayHelp _help = RoomAwayHelp.none;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final getIt = GetIt.instance;
    final mode = getIt.isRegistered<TransferModeStore>()
        ? getIt<TransferModeStore>().mode
        : null;
    final side = getIt.isRegistered<SessionRoleStore>()
        ? getIt<SessionRoleStore>().role
        : null;
    final keeper = getIt.isRegistered<HotspotLinkKeeper>()
        ? getIt<HotspotLinkKeeper>()
        : null;
    var memberWasSharing = false;
    if (mode == TransferMode.hotspot && side == SessionRole.joiner) {
      try {
        final host = await RoomHotspotHistory().lastHost(widget.room.room.id);
        memberWasSharing = host == widget.member.id;
      } catch (_) {
        // Unknown is "no": a scan button that scans for nobody is worse than
        // none at all.
      }
    }
    if (!mounted) return;
    setState(
      () => _help = resolveRoomAwayHelp(
        mode: mode,
        side: side,
        sharingNow: keeper?.credentials != null,
        memberWasSharing: memberWasSharing,
      ),
    );
  }

  void _act() {
    HapticFeedback.selectionClick();
    switch (_help) {
      case RoomAwayHelp.showCode:
        unawaited(
          showRoomRejoinCodeSheet(
            context,
            room: widget.room,
            name: widget.name,
            back: widget.back,
          ),
        );
      case RoomAwayHelp.scanCode:
        RoomLiveRejoinScope.maybeOf(context)?.onScanPeerCode();
      case RoomAwayHelp.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final canScan = RoomLiveRejoinScope.maybeOf(context) != null;
    final help = _help == RoomAwayHelp.scanCode && !canScan
        ? RoomAwayHelp.none
        : _help;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.room_member_waiting_back(widget.name),
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        AnimatedSize(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: AnimatedSwitcher(
            duration: AppMotion.card,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            child: help == RoomAwayHelp.none
                ? const SizedBox(width: double.infinity)
                : Padding(
                    key: ValueKey('room-away-help-${help.name}'),
                    padding: const EdgeInsets.only(top: 10),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: _HelpPill(
                        key: Key(
                          'room-away-${help.name}-${widget.member.id.value}',
                        ),
                        icon: help == RoomAwayHelp.showCode
                            ? Icons.qr_code_2_rounded
                            : Icons.qr_code_scanner_rounded,
                        label: help == RoomAwayHelp.showCode
                            ? s.room_rejoin_show_code
                            : s.room_rejoin_scan_code(widget.name),
                        onTap: _act,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _HelpPill extends StatelessWidget {
  const _HelpPill({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.7)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: AppColors.amber),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The code a returning phone scans to get back on this phone's shared
/// connection, opened over the live screen so this phone never leaves it.
///
/// It follows the connection: if Android replaces it while the sheet is up,
/// the new code takes its place. When the person is heard again the sheet
/// says so and closes by itself.
Future<void> showRoomRejoinCodeSheet(
  BuildContext context, {
  required SavedRoom room,
  required String name,
  required ValueListenable<bool> back,
}) => showModalBottomSheet<void>(
  context: context,
  routeSettings: const RouteSettings(name: 'RoomRejoinCodeSheet'),
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  barrierColor: Colors.black.withValues(alpha: 0.62),
  builder: (_) => _RejoinCodeSheet(room: room, name: name, back: back),
);

class _RejoinCodeSheet extends StatefulWidget {
  const _RejoinCodeSheet({
    required this.room,
    required this.name,
    required this.back,
  });

  final SavedRoom room;
  final String name;
  final ValueListenable<bool> back;

  @override
  State<_RejoinCodeSheet> createState() => _RejoinCodeSheetState();
}

class _RejoinCodeSheetState extends State<_RejoinCodeSheet> {
  /// Long enough to see the check, short enough not to be in the way of the
  /// call that just came back.
  static const _backHold = Duration(milliseconds: 1400);

  HotspotLinkKeeper? _keeper;
  HotspotCredentials? _credentials;
  StreamSubscription<HotspotCredentials>? _changes;
  Timer? _closeTimer;
  bool _isBack = false;

  @override
  void initState() {
    super.initState();
    if (GetIt.instance.isRegistered<HotspotLinkKeeper>()) {
      final keeper = GetIt.instance<HotspotLinkKeeper>();
      _keeper = keeper;
      _credentials = keeper.credentials;
      _changes = keeper.credentialChanges.listen((credentials) {
        if (mounted) setState(() => _credentials = credentials);
      });
    }
    widget.back.addListener(_onBack);
    _onBack();
  }

  void _onBack() {
    if (!widget.back.value || _isBack || !mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _isBack = true);
    _closeTimer = Timer(_backHold, () {
      if (mounted) Navigator.maybePop(context);
    });
  }

  @override
  void dispose() {
    widget.back.removeListener(_onBack);
    _closeTimer?.cancel();
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final credentials = _credentials ?? _keeper?.credentials;
    return SheetShell(
      topFraction: 0.1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
        child: PhaseSwitcher(
          child: _isBack
              ? _BackMark(
                  key: const ValueKey('rejoin-code-back'),
                  label: s.room_rejoin_code_back(widget.name),
                )
              : StaggeredEntrance(
                  key: const ValueKey('rejoin-code'),
                  builder: (context, children) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                  children: [
                    Text(
                      s.room_rejoin_code_title(widget.name),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: AnimatedSwitcher(
                        duration: AppMotion.card,
                        switchInCurve: AppMotion.easeOut,
                        switchOutCurve: AppMotion.leaving,
                        child: credentials == null
                            ? SizedBox(
                                key: const ValueKey('rejoin-code-waiting'),
                                width: 230,
                                height: 230,
                                child: Center(
                                  child: Text(
                                    s.reconnect_preparing,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              )
                            : GlowingQrCard(
                                key: ValueKey(
                                  'rejoin-code-${credentials.ssid}',
                                ),
                                data: credentials.qrPayload(
                                  channel: RoomPreLiveAnnouncer.channelFor(
                                    widget.room.room.id,
                                  ),
                                ),
                                size: 230,
                                branded: true,
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    StepRow(
                      index: 1,
                      icon: Icons.touch_app_rounded,
                      text: s.room_rejoin_code_step_open(widget.name),
                    ),
                    const SizedBox(height: 10),
                    StepRow(
                      index: 2,
                      icon: Icons.qr_code_scanner_rounded,
                      text: s.room_rejoin_code_step_scan,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The member came back: one check mark, the only place the overshoot curve
/// is allowed, then the sheet gets out of the way.
class _BackMark extends StatelessWidget {
  const _BackMark({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1),
          duration: AppMotion.entrance,
          curve: AppMotion.reduced(context)
              ? AppMotion.easeOut
              : Curves.easeOutBack,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.green.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.green, width: 1.5),
            ),
            child: Icon(Icons.check_rounded, size: 38, color: AppColors.green),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

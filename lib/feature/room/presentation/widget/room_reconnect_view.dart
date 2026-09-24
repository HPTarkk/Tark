import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_scanner_surface.dart';
import '../../../../core/widget/qr_widgets.dart';

/// Which half of a reconnect this phone is doing.
enum RoomReconnectSide {
  /// This phone shares the connection and shows the code.
  show,

  /// This phone opens the camera and scans the other phone's code.
  scan,
}

enum RoomReconnectPhase { preparing, waiting, connecting, failed }

/// Everything the reconnect screen shows. Immutable; the entry replaces it.
@immutable
class RoomReconnectModel {
  const RoomReconnectModel({
    required this.side,
    required this.peerName,
    this.phase = RoomReconnectPhase.preparing,
    this.qrData,
    this.message,
    this.canSwitch = true,
  });

  final RoomReconnectSide side;

  /// The other person, as this phone knows them. Used in every instruction so
  /// nobody has to work out which phone "the host" is.
  final String peerName;
  final RoomReconnectPhase phase;

  /// The code to show, on the [RoomReconnectSide.show] side once it is ready.
  final String? qrData;

  /// A plain-words problem or hint. On the scan side it rides the scanner's
  /// error card; on the show side it replaces the steps when [phase] failed.
  final String? message;
  final bool canSwitch;

  RoomReconnectModel copyWith({
    RoomReconnectPhase? phase,
    String? qrData,
    String? message,
    bool clearMessage = false,
  }) => RoomReconnectModel(
    side: side,
    peerName: peerName,
    phase: phase ?? this.phase,
    qrData: qrData ?? this.qrData,
    message: clearMessage ? null : message ?? this.message,
    canSwitch: canSwitch,
  );
}

/// The guided "connect these two phones" screen a Room shows when Start finds
/// no link between them.
///
/// It never asks the user to choose a role, a network or a hotspot. One phone
/// is shown a code and told whose phone to hold it up to; the other gets a
/// camera and is told whose code to point it at. Which phone does which is
/// decided before this screen opens, the same way on both phones, and a small
/// switch covers the rare case where that guess is wrong.
class RoomReconnectView extends StatelessWidget {
  const RoomReconnectView({
    required this.model,
    required this.onScan,
    required this.onSwitch,
    required this.onRetry,
    required this.onBack,
    super.key,
  });

  final RoomReconnectModel model;
  final Future<bool> Function(String raw) onScan;
  final VoidCallback onSwitch;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    // The scanner's close button and system back both mean "not now": back to
    // the Room, never out of it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onBack();
      },
      child: AnimatedSwitcher(
        duration: AppMotion.card,
        switchInCurve: AppMotion.easeOut,
        switchOutCurve: AppMotion.leaving,
        child: model.side == RoomReconnectSide.scan
            ? _ScanSide(
                key: const ValueKey('room-reconnect-scan'),
                model: model,
                onScan: onScan,
                onSwitch: onSwitch,
              )
            : _ShowSide(
                key: const ValueKey('room-reconnect-show'),
                model: model,
                onSwitch: onSwitch,
                onRetry: onRetry,
                onBack: onBack,
              ),
      ),
    );
  }
}

class _ScanSide extends StatelessWidget {
  const _ScanSide({
    required this.model,
    required this.onScan,
    required this.onSwitch,
    super.key,
  });

  final RoomReconnectModel model;
  final Future<bool> Function(String raw) onScan;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Stack(
      children: [
        Positioned.fill(
          child: QrScannerSurface(
            title: s.reconnect_scan_title,
            hint: s.reconnect_scan_hint(model.peerName),
            searchingLabel: s.reconnect_scan_searching,
            lockedLabel: s.reconnect_scan_locked,
            busyLabel: s.reconnect_scan_busy,
            cameraDeniedLabel: s.roomjoin_camera_denied,
            cameraFailedLabel: s.roomjoin_camera_failed,
            openSettingsLabel: s.roomjoin_open_settings,
            errorText: model.message,
            onCode: onScan,
          ),
        ),
        if (model.canSwitch)
          Positioned(
            left: 24,
            right: 24,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
            child: Center(
              child: _SwitchButton(
                key: const Key('room-reconnect-switch'),
                label: s.reconnect_switch_to_show,
                icon: Icons.qr_code_2_rounded,
                onTap: onSwitch,
                onDark: true,
              ),
            ),
          ),
      ],
    );
  }
}

class _ShowSide extends StatelessWidget {
  const _ShowSide({
    required this.model,
    required this.onSwitch,
    required this.onRetry,
    required this.onBack,
    super.key,
  });

  final RoomReconnectModel model;
  final VoidCallback onSwitch;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('room-reconnect-back'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: onBack,
                    icon: Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? Icons.arrow_forward_rounded
                          : Icons.arrow_back_rounded,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      s.reconnect_show_title(model.peerName),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: AnimatedSwitcher(
                  duration: AppMotion.card,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.leaving,
                  child: _body(context),
                ),
              ),
            ),
            if (model.canSwitch && model.phase != RoomReconnectPhase.connecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: _SwitchButton(
                  key: const Key('room-reconnect-switch'),
                  label: s.reconnect_switch_to_scan,
                  icon: Icons.photo_camera_rounded,
                  onTap: onSwitch,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final s = context.getString;
    switch (model.phase) {
      case RoomReconnectPhase.preparing:
        return _StatusBlock(
          key: const ValueKey('preparing'),
          icon: null,
          text: s.reconnect_preparing,
        );
      case RoomReconnectPhase.connecting:
        return _StatusBlock(
          key: const ValueKey('connecting'),
          icon: Icons.check_circle_rounded,
          iconColor: AppColors.green,
          text: s.reconnect_connecting,
        );
      case RoomReconnectPhase.failed:
        return Column(
          key: const ValueKey('failed'),
          children: [
            const SizedBox(height: 32),
            Icon(Icons.sync_problem_rounded, size: 48, color: AppColors.amber),
            const SizedBox(height: 16),
            Text(
              model.message ?? s.reconnect_host_failed,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('room-reconnect-retry'),
              onPressed: () {
                HapticFeedback.selectionClick();
                onRetry();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(s.reconnect_retry),
            ),
          ],
        );
      case RoomReconnectPhase.waiting:
        final data = model.qrData;
        return Column(
          key: const ValueKey('waiting'),
          children: [
            if (data != null)
              Semantics(
                image: true,
                label: s.reconnect_show_step_hold,
                child: GlowingQrCard(data: data, size: 232, branded: true),
              ),
            const SizedBox(height: 20),
            _WaitingPulse(text: s.reconnect_waiting(model.peerName)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  StepRow(
                    index: 1,
                    icon: Icons.touch_app_rounded,
                    text: s.reconnect_show_step_start(model.peerName),
                  ),
                  const SizedBox(height: 12),
                  Divider(color: AppColors.border, height: 1),
                  const SizedBox(height: 12),
                  StepRow(
                    index: 2,
                    icon: Icons.photo_camera_rounded,
                    text: s.reconnect_show_step_hold,
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _StatusBlock extends StatelessWidget {
  const _StatusBlock({
    required this.icon,
    required this.text,
    this.iconColor,
    super.key,
  });

  final IconData? icon;
  final Color? iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Column(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: icon == null
                ? CircularProgressIndicator(
                    strokeWidth: 3,
                    color: AppColors.amber,
                  )
                : Icon(icon, size: 56, color: iconColor ?? AppColors.amber),
          ),
          const SizedBox(height: 20),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A softly breathing dot beside the waiting line, so a screen that is
/// genuinely waiting on another person never reads as frozen.
class _WaitingPulse extends StatefulWidget {
  const _WaitingPulse({required this.text});

  final String text;

  @override
  State<_WaitingPulse> createState() => _WaitingPulseState();
}

class _WaitingPulseState extends State<_WaitingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _breath.value = 1;
      _breath.stop();
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: widget.text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: Tween<double>(begin: 0.35, end: 1).animate(
                CurvedAnimation(parent: _breath, curve: Curves.easeInOut),
              ),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: AppColors.amber,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                widget.text,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchButton extends StatelessWidget {
  const _SwitchButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.onDark = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final color = onDark ? Colors.white : AppColors.textSecondary;
    return TextButton.icon(
      onPressed: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      style: TextButton.styleFrom(
        foregroundColor: color,
        backgroundColor: onDark ? Colors.black.withAlpha(110) : null,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

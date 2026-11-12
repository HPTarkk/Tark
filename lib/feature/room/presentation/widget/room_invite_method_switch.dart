import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/room_invite_link.dart';

/// "How should they connect?" — chosen by the host, on the code itself.
///
/// Two segments on one track, Hotspot and Bluetooth, with a thumb that
/// travels between them. Picking one re-makes the code under it, so what is
/// on screen is always the method the other phone will use; there is no
/// second screen and nothing to remember from Settings.
///
/// One line under the track says what the pick means for the person holding
/// the phone (range, and that a hotspot here does not share internet), never
/// how it works.
///
/// Motion: the thumb rides a spring and can be dragged; it follows the
/// finger, and on release settles on whichever side it is nearer (or was
/// flung toward). A pick the opener refuses — a locked method whose paywall
/// was closed — springs back, because the thumb always settles on [value].
/// Under reduced motion it moves in a short straight ease instead.
class RoomInviteMethodSwitch extends StatefulWidget {
  const RoomInviteMethodSwitch({
    required this.value,
    required this.onChanged,
    this.hotspotLocked = false,
    this.bluetoothIsFree = false,
    super.key,
  });

  final RoomInviteMethod value;
  final ValueChanged<RoomInviteMethod> onChanged;

  /// Hotspot needs a subscription this phone does not have. The segment
  /// stays tappable: the tap is what opens the plans.
  final bool hotspotLocked;

  /// Whether to say Bluetooth is the free way, which only means something
  /// where something is sold.
  final bool bluetoothIsFree;

  @override
  State<RoomInviteMethodSwitch> createState() => _RoomInviteMethodSwitchState();
}

class _RoomInviteMethodSwitchState extends State<RoomInviteMethodSwitch>
    with SingleTickerProviderStateMixin {
  static const _height = 46.0;
  static const _inset = 4.0;

  /// A little under critical damping: one small overshoot, then still.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 520,
    damping: 34,
  );

  /// 0 = on Hotspot (the reading start), 1 = on Bluetooth (the reading end).
  late final AnimationController _thumb = AnimationController.unbounded(
    vsync: this,
    value: _target,
  );

  bool _dragging = false;

  double get _target => widget.value == RoomInviteMethod.bluetooth ? 1 : 0;

  @override
  void didUpdateWidget(RoomInviteMethodSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_dragging) _settle();
  }

  @override
  void dispose() {
    _thumb.dispose();
    super.dispose();
  }

  /// Brings the thumb to rest on [RoomInviteMethodSwitch.value], carrying
  /// [velocity] (in track-widths per second) from a fling.
  void _settle({double velocity = 0}) {
    final target = _target;
    if (AppMotion.reduced(context)) {
      _thumb.animateTo(
        target,
        duration: AppMotion.chip,
        curve: AppMotion.easeOut,
      );
      return;
    }
    if ((_thumb.value - target).abs() < 0.001 && velocity.abs() < 0.01) {
      _thumb.value = target;
      return;
    }
    _thumb.animateWith(
      SpringSimulation(_spring, _thumb.value, target, velocity),
    );
  }

  void _pick(RoomInviteMethod method) {
    if (method == widget.value) {
      _settle();
      return;
    }
    HapticFeedback.selectionClick();
    widget.onChanged(method);
    // Refused, or decided later: until [value] changes the thumb belongs
    // where it was.
    if (mounted) _settle();
  }

  void _dragBy(double delta, double travel) {
    if (travel <= 0) return;
    final sign = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    _thumb.value = (_thumb.value + sign * delta / travel).clamp(-0.06, 1.06);
  }

  void _dragEnd(double velocity, double travel) {
    _dragging = false;
    final sign = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    final perSecond = travel <= 0 ? 0.0 : sign * velocity / travel;
    final flung = perSecond.abs() > 1.2;
    final toBluetooth = flung ? perSecond > 0 : _thumb.value > 0.5;
    final method = toBluetooth
        ? RoomInviteMethod.bluetooth
        : RoomInviteMethod.hotspot;
    if (method == widget.value) {
      _settle(velocity: perSecond);
      return;
    }
    HapticFeedback.selectionClick();
    widget.onChanged(method);
    if (mounted) _settle(velocity: perSecond);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final bluetooth = widget.value == RoomInviteMethod.bluetooth;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: s.invite_method_label,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segment = (constraints.maxWidth - _inset * 2) / 2;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) {
                  _dragging = true;
                  _thumb.stop();
                },
                onHorizontalDragUpdate: (details) =>
                    _dragBy(details.primaryDelta ?? 0, segment),
                onHorizontalDragEnd: (details) =>
                    _dragEnd(details.primaryVelocity ?? 0, segment),
                onHorizontalDragCancel: () {
                  _dragging = false;
                  _settle();
                },
                child: Container(
                  key: const Key('room-invite-method-switch'),
                  height: _height,
                  padding: const EdgeInsets.all(_inset),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Stack(
                    children: [
                      AnimatedBuilder(
                        animation: _thumb,
                        builder: (context, child) {
                          final t = _thumb.value;
                          // Stretches a touch mid-flight, the way something
                          // with a little give does, and is exact at rest.
                          final stretch =
                              1 + 0.10 * math.sin(math.pi * t.clamp(0.0, 1.0));
                          return Align(
                            alignment: AlignmentDirectional(t * 2 - 1, 0),
                            child: SizedBox(
                              width: segment,
                              height: double.infinity,
                              child: Transform.scale(
                                scaleX: stretch,
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.amber.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppColors.amber.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Row(
                          children: [
                            _Segment(
                              key: const Key('room-invite-method-hotspot'),
                              thumb: _thumb,
                              at: 0,
                              icon: Icons.wifi_tethering_rounded,
                              label: s.invite_method_hotspot,
                              selected: !bluetooth,
                              locked: widget.hotspotLocked,
                              onTap: () => _pick(RoomInviteMethod.hotspot),
                            ),
                            _Segment(
                              key: const Key('room-invite-method-bluetooth'),
                              thumb: _thumb,
                              at: 1,
                              icon: Icons.bluetooth_rounded,
                              label: s.invite_method_bluetooth,
                              selected: bluetooth,
                              locked: false,
                              onTap: () => _pick(RoomInviteMethod.bluetooth),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        PhaseSwitcher(
          child: Text(
            bluetooth
                ? (widget.bluetoothIsFree
                      ? s.invite_method_bluetooth_note_free
                      : s.invite_method_bluetooth_note)
                : s.invite_method_hotspot_note,
            key: ValueKey('room-invite-method-note-${widget.value.name}'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

/// One half of the track. Its ink warms to amber as the thumb arrives under
/// it and cools as it leaves, read straight off the thumb's position so a
/// drag tints both labels continuously.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.thumb,
    required this.at,
    required this.icon,
    required this.label,
    required this.selected,
    required this.locked,
    required this.onTap,
    super.key,
  });

  final Animation<double> thumb;

  /// Where on the track this segment sits: 0 or 1.
  final double at;
  final IconData icon;
  final String label;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: locked ? '$label. ${s.invite_method_locked}' : label,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedBuilder(
            animation: thumb,
            builder: (context, _) {
              final near = (1 - (thumb.value - at).abs()).clamp(0.0, 1.0);
              final color = Color.lerp(
                AppColors.textSecondary,
                AppColors.amber,
                near,
              )!;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (locked) ...[
                    const SizedBox(width: 5),
                    Icon(
                      Icons.lock_rounded,
                      size: 12,
                      color: AppColors.amber.withValues(alpha: 0.8),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

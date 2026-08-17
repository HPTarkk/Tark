import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';

/// The "switch Wi-Fi off" advisory on the hotspot host screen.
///
/// ## Why this is a card and not a toast
///
/// It is asking someone to turn off the thing most people assume is *how the
/// app works*, moments after telling them the app needs a network. That is a
/// counter-intuitive request, and a counter-intuitive request gets ignored
/// unless it explains itself — so the card shows the mechanism rather than
/// asserting a rule, and answers the objection ("won't that kill my channel?")
/// before it is raised.
///
/// It cannot do the thing itself: `setWifiEnabled` has been a no-op returning
/// false for non-system apps since Android 10. The entire job is asking well
/// and making the switch one tap away.
class HotspotWifiNote extends StatelessWidget {
  /// The OS has already taken the hotspot down once. Changes the copy from a
  /// prediction into an explanation of what the user just watched happen.
  final bool afterDrop;

  final VoidCallback onOpenWifi;
  final VoidCallback onDismiss;

  const HotspotWifiNote({
    super.key,
    required this.afterDrop,
    required this.onOpenWifi,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    // Amber while it is advice; red once the thing it warned about has already
    // cost the user their hotspot. Same card, different standing.
    final tint = afterDrop ? AppColors.red : AppColors.amber;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tint.withAlpha(110)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The diagram is the argument. Text alone has to be believed; this
          // can be watched.
          _RadioContentionStrip(tint: tint),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      afterDrop
                          ? Icons.error_outline_rounded
                          : Icons.wifi_tethering_error_rounded,
                      color: tint,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        afterDrop
                            ? s.hotspot_wifi_note_title_dropped
                            : s.hotspot_wifi_note_title,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  afterDrop
                      ? s.hotspot_wifi_note_body_dropped
                      : s.hotspot_wifi_note_body,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                // The objection, answered before it is raised. Being asked to
                // switch off Wi-Fi by a networking app reads as self-defeating
                // until you know the channel never used Wi-Fi in the first
                // place — and someone who doesn't know that will not tap.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.verified_rounded,
                      color: AppColors.green.withAlpha(210),
                      size: 13,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        s.hotspot_wifi_note_reassure,
                        style: TextStyle(
                          color: AppColors.green.withAlpha(210),
                          fontSize: 10.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _NoteButton(
                        label: s.hotspot_wifi_note_action,
                        icon: Icons.wifi_off_rounded,
                        tint: tint,
                        filled: true,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onOpenWifi();
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    _NoteButton(
                      label: s.hotspot_wifi_note_dismiss,
                      tint: AppColors.textSecondary,
                      filled: false,
                      onTap: onDismiss,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color tint;
  final bool filled;
  final VoidCallback onTap;

  const _NoteButton({
    required this.label,
    this.icon,
    required this.tint,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: filled ? 14 : 12, vertical: 11),
        decoration: BoxDecoration(
          color: filled ? tint.withAlpha(26) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: filled ? tint.withAlpha(140) : AppColors.border,
            width: filled ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, color: tint, size: 14),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tint,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mechanism, drawn: **one radio, two claimants.**
///
/// A single node in the middle is this phone's Wi-Fi chip. To the right, warm
/// arcs are the hotspot it is serving. To the left, cool arcs are a remembered
/// network sweeping back into range. The cool sweep travels in, reaches the
/// node — and the warm arcs go out. Then it resets and does it again.
///
/// That is exactly what `isStaApConcurrencySupported == false` means, and it is
/// far easier to watch than to read. The loop deliberately runs slowly and
/// resolves back to the healthy state rather than ending on the failure: this
/// is a card someone reads for ten seconds, and a diagram stuck on a dead
/// hotspot would read as a status rather than a warning.
///
/// **Low-end budget:** strokes and arcs only — no blur, no shader, no
/// `ClipPath`, and the animation drives the painter through `repaint:` so no
/// widget in this subtree rebuilds per frame.
class _RadioContentionStrip extends StatefulWidget {
  final Color tint;

  const _RadioContentionStrip({required this.tint});

  @override
  State<_RadioContentionStrip> createState() => _RadioContentionStripState();
}

class _RadioContentionStripState extends State<_RadioContentionStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  )..repeat();

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Container(
      height: 104,
      width: double.infinity,
      // Its own ground and a closing edge, so the strip reads as a diagram
      // panel rather than as loose ornament floating above the text.
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ContentionPainter(
                progress: _loop,
                warm: widget.tint,
                cool: AppColors.textSecondary,
                surface: AppColors.surface,
                rtl: rtl,
              ),
            ),
          ),
          // The two claimants, named by icon rather than by text: this widget
          // would otherwise need two more translated strings to say things
          // ("Wi-Fi", "your hotspot") that these glyphs already say in every
          // language, and the body copy names them anyway.
          _Station(
            alignLeft: !rtl,
            icon: Icons.wifi_rounded,
            color: AppColors.textSecondary,
          ),
          _Station(
            alignLeft: rtl,
            icon: Icons.wifi_tethering_rounded,
            color: widget.tint,
          ),
        ],
      ),
    );
  }
}

/// One end of the diagram — the network pulling at the radio, or the hotspot
/// being served by it.
class _Station extends StatelessWidget {
  final bool alignLeft;
  final IconData icon;
  final Color color;

  const _Station({
    required this.alignLeft,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(
          left: alignLeft ? 18 : 0,
          right: alignLeft ? 0 : 18,
        ),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.card,
            shape: BoxShape.circle,
            border: Border.all(color: color.withAlpha(120)),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}

class _ContentionPainter extends CustomPainter {
  /// Angular width of a signal arc. Shared with the reach calculation, which
  /// needs it to know how tall an arc of a given radius will be.
  static const double _spread = math.pi * 0.56;

  final Animation<double> progress;
  final Color warm;
  final Color cool;
  final Color surface;

  /// Persian reads right to left, so the intruding network sweeps from the
  /// side the reader starts on and the hotspot sits where their eye ends up —
  /// otherwise the diagram tells the story backwards.
  final bool rtl;

  _ContentionPainter({
    required this.progress,
    required this.warm,
    required this.cool,
    required this.surface,
    required this.rtl,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final cx = size.width / 2;
    final cy = size.height / 2;

    // ── Phases ───────────────────────────────────────────────────────────
    // 0.00–0.45  calm: the hotspot serves, nothing is contending
    // 0.45–0.70  the remembered network sweeps in
    // 0.70–0.82  handover: warm collapses as cool takes the node
    // 0.82–1.00  recovery back to calm, so the loop never rests on failure
    final sweep = ((t - 0.45) / 0.25).clamp(0.0, 1.0);
    final seized = ((t - 0.70) / 0.12).clamp(0.0, 1.0);
    final recover = ((t - 0.82) / 0.18).clamp(0.0, 1.0);

    // Warm strength: full until the handover, gone through it, back on recovery.
    final warmStrength = (1.0 - seized) + recover * seized;

    final dir = rtl ? -1.0 : 1.0;

    // How far an arc may reach. Bounded on both axes, and the vertical bound is
    // the one that actually bites: an arc of radius r spanning [_spread] rises
    // r·sin(spread/2) above the centre line, so a radius chosen only against
    // the card's width runs straight out of the strip and gets clipped by its
    // edge — which reads as a drawing mistake rather than a signal.
    final reach = math.min(
      (size.width / 2) - 46.0,
      ((size.height / 2) - 8.0) / math.sin(_spread / 2),
    );

    // Hotspot arcs — the side we are serving. Fanning out toward its station.
    for (int i = 0; i < 4; i++) {
      final radius = 18.0 + i * (reach - 18.0) / 3.5;
      // Each ring breathes on its own phase, so the healthy state looks alive
      // rather than frozen.
      final breathe = 0.5 + 0.5 * math.sin((t * 2 * math.pi) - i * 0.6);
      final alpha = (warmStrength * breathe * 225).clamp(0.0, 255.0).round();
      if (alpha <= 2) continue;
      _arc(canvas, Offset(cx, cy), radius, dir, warm.withAlpha(alpha), 2.2);
    }

    // The intruding network — arcs marching in on the radio from the far side.
    if (sweep > 0) {
      for (int i = 0; i < 3; i++) {
        // Travel inward: starts out by its own station, closes on the node.
        final travel = (sweep - i * 0.13).clamp(0.0, 1.0);
        if (travel <= 0) continue;
        final radius = reach - (reach - 17.0) * Curves.easeIn.transform(travel);
        final fade = (1.0 - recover) * (0.4 + 0.6 * travel);
        final alpha = (fade * 255).clamp(0.0, 255.0).round();
        if (alpha <= 2) continue;
        _arc(canvas, Offset(cx, cy), radius, -dir, cool.withAlpha(alpha), 2.4);
      }
    }

    // The radio itself, last so nothing draws over it. It takes the colour of
    // whoever currently owns it — which is the whole point of the picture.
    final owner = Color.lerp(cool, warm, warmStrength.clamp(0.0, 1.0))!;
    canvas.drawCircle(Offset(cx, cy), 11, Paint()..color = surface);
    canvas.drawCircle(
      Offset(cx, cy),
      11,
      Paint()
        ..color = owner
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      3.6,
      Paint()..color = owner.withAlpha((warmStrength * 90 + 165).round()),
    );
  }

  /// One signal arc opening toward [dir] (+1 right, -1 left).
  void _arc(
    Canvas canvas,
    Offset centre,
    double radius,
    double dir,
    Color c,
    double width,
  ) {
    if (radius <= 1) return;
    final start = (dir > 0 ? 0.0 : math.pi) - _spread / 2;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      start,
      _spread,
      false,
      Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ContentionPainter old) =>
      old.warm != warm ||
      old.cool != cool ||
      old.surface != surface ||
      old.rtl != rtl;
}

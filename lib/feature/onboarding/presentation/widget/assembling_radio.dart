import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/widget/tark_mark.dart';
import '../../../transfer/api/transfer_api.dart';
import 'onboarding_palette.dart';

/// The gamified heart of the journey: a handheld radio that *builds itself*
/// one component per beat, so finishing a beat visibly earns the next piece of
/// your unit. By the launch beat it powers on and starts transmitting.
///
///   beat 0 tune      → the chassis drops in
///   beat 1 welcome   → the antenna telescopes up
///   beat 2 callsign  → the screen lights and shows your handle
///   beat 3 transport → your link module clips onto the side
///   beat 4 launch    → PTT + LED go live and the unit keys up on air
///
/// Every part reveals itself with an easeOutBack pop the moment its beat is
/// reached and then stays, so backing up and forward re-earns the same pieces.
/// Stateless — the page owns the ambient clocks (all 0..1) so the radio breathes
/// in sync with the horizon, mesh, and CTA.
class AssemblingRadio extends StatelessWidget {
  /// Current beat (0..4); each part keys its reveal off this.
  final int step;

  /// 0..1 breathing loop — glow on live parts.
  final double glow;

  /// 0..1 continuous loop — screen scanline + transmit rings.
  final double scan;

  /// 0..1 one-shot fired on every beat change — a whole-unit settle blip.
  final double kick;

  /// The handle typed on the callsign beat; drives the screen readout.
  final String callsign;

  /// The chosen transport; picks the side module's glyph.
  final TransferMode mode;

  const AssemblingRadio({
    super.key,
    required this.step,
    required this.glow,
    required this.scan,
    required this.kick,
    required this.callsign,
    required this.mode,
  });

  static const _antennaUp = 1; // welcome
  static const _screenOn = 2; // callsign
  static const _linked = 3; // transport
  static const _powered = 4; // launch

  @override
  Widget build(BuildContext context) {
    final kicking = kick > 0 && kick < 1;
    final blip = kicking ? 1 + 0.05 * sin(pi * kick) : 1.0;
    final powered = step >= _powered;

    return Transform.scale(
      scale: blip,
      child: SizedBox(
        width: 158,
        height: 214,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // Transmit rings escape the antenna tip once the unit is on air.
            if (powered)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _TransmitPainter(
                      t: scan,
                      origin: const Offset(34, 4),
                      color: Onb.amber,
                    ),
                  ),
                ),
              ),
            _antenna(),
            _body(context, powered),
            _transportModule(),
          ],
        ),
      ),
    );
  }

  // ── Antenna: telescopes up out of the chassis on the welcome beat ──────────

  Widget _antenna() {
    return Positioned(
      left: 26,
      top: 2,
      child: _reveal(
        on: step >= _antennaUp,
        duration: const Duration(milliseconds: 620),
        builder: (t) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.diagonal3Values(1, t.clamp(0.0, 1.0), 1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tip bead — glows once the unit is live.
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Onb.amber,
                    boxShadow: step >= _powered
                        ? [
                            BoxShadow(
                              color: Onb.amber.withAlpha(
                                (120 * glow).toInt(),
                              ),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
                Container(
                  width: 6,
                  height: 58,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Onb.amber, Onb.amberDim],
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Chassis + all face components ──────────────────────────────────────────

  Widget _body(BuildContext context, bool powered) {
    return Positioned(
      top: 56,
      child: _reveal(
        on: step >= 0,
        duration: const Duration(milliseconds: 640),
        builder: (t) {
          final e = t.clamp(0.0, 1.0);
          return Opacity(
            opacity: e,
            child: Transform.translate(
              offset: Offset(0, 18 * (1 - t)),
              child: Transform.scale(
                scale: 0.92 + 0.08 * e,
                child: _chassis(context, powered),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _chassis(BuildContext context, bool powered) {
    return Container(
      width: 128,
      height: 152,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(Onb.panel, Colors.white, 0.04)!,
            Onb.panelHi,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: powered
              ? Onb.amber.withAlpha((110 + 90 * glow).toInt())
              : Onb.line,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(90),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
          if (powered)
            BoxShadow(
              color: Onb.amber.withAlpha((40 * glow).toInt()),
              blurRadius: 26,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topRow(powered),
          const SizedBox(height: 7),
          _grille(),
          const SizedBox(height: 8),
          Expanded(child: _screen(context)),
          const SizedBox(height: 8),
          _pttButton(powered),
        ],
      ),
    );
  }

  // LED (left) + channel knob (right).
  Widget _topRow(bool powered) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // On-air LED.
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: powered
                ? Onb.green
                : Onb.textDim.withAlpha(90),
            boxShadow: powered
                ? [
                    BoxShadow(
                      color: Onb.green.withAlpha((160 * glow).toInt()),
                      blurRadius: 8,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
        ),
        // Channel knob.
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [Onb.line, Onb.panelHi],
              center: const Alignment(-0.4, -0.4),
            ),
            border: Border.all(color: Onb.line, width: 1),
          ),
          child: Center(
            child: Container(
              width: 2,
              height: 6,
              decoration: BoxDecoration(
                color: Onb.amber.withAlpha(200),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Speaker grille: three slim bars.
  Widget _grille() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 5; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Container(
            width: 4,
            height: 8 + (i.isEven ? 2 : 0),
            decoration: BoxDecoration(
              color: Onb.ink.withAlpha(160),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ],
    );
  }

  // ── Screen: dark until the callsign beat, then lit with your handle ────────

  Widget _screen(BuildContext context) {
    final on = step >= _screenOn;
    return _reveal(
      on: on,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOut,
      builder: (t) {
        final lit = t.clamp(0.0, 1.0);
        return Container(
          decoration: BoxDecoration(
            color: Color.lerp(
              Onb.ink,
              Color.lerp(Onb.ink, Onb.amber, 0.16)!,
              lit,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Color.lerp(
                Onb.line,
                Onb.amber.withAlpha((120 + 60 * glow).toInt()),
                lit,
              )!,
              width: 1,
            ),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: Onb.amber.withAlpha((40 * glow * lit).toInt()),
                      blurRadius: 12,
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Scanline sweep while lit.
              if (on)
                Align(
                  alignment: Alignment(0, -1 + 2 * ((scan * 1.0) % 1.0)),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Onb.amber.withAlpha(0),
                          Onb.amber.withAlpha((34 * glow).toInt()),
                          Onb.amber.withAlpha(0),
                        ],
                      ),
                    ),
                  ),
                ),
              Center(
                child: Opacity(
                  opacity: lit,
                  child: _screenContent(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _screenContent(BuildContext context) {
    final name = callsign.trim();
    if (name.isEmpty) {
      // Standby: brand mark waiting for a handle.
      return TarkMark(
        size: 26,
        pulse: glow,
        color: Onb.amber,
        colorDim: Onb.amberDim,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'CALLSIGN',
          style: TextStyle(
            color: Onb.amber.withAlpha(150),
            fontSize: 6.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              name.toUpperCase(),
              maxLines: 1,
              style: TextStyle(
                color: Onb.amber,
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── PTT (push-to-talk): the big side button; keys up on launch ─────────────

  Widget _pttButton(bool powered) {
    return Container(
      height: 22,
      decoration: BoxDecoration(
        color: powered
            ? Onb.amber.withAlpha((60 + 60 * glow).toInt())
            : Onb.ink.withAlpha(120),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: powered
              ? Onb.amber.withAlpha((140 + 80 * glow).toInt())
              : Onb.line,
          width: 1,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.podcasts_rounded,
          size: 13,
          color: powered ? Onb.amber : Onb.textDim.withAlpha(120),
        ),
      ),
    );
  }

  // ── Transport module: clips onto the right flank on the transport beat ─────

  Widget _transportModule() {
    final on = step >= _linked;
    return Positioned(
      right: 4,
      top: 96,
      child: _reveal(
        on: on,
        duration: const Duration(milliseconds: 560),
        builder: (t) {
          final e = t.clamp(0.0, 1.0);
          return Opacity(
            opacity: e,
            child: Transform.translate(
              offset: Offset(26 * (1 - t), 0),
              child: Transform.scale(scale: 0.7 + 0.3 * e, child: _moduleChip()),
            ),
          );
        },
      ),
    );
  }

  Widget _moduleChip() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Onb.panel,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: Onb.amber.withAlpha((90 + 60 * glow).toInt()),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Onb.amber.withAlpha((30 * glow).toInt()),
            blurRadius: 10,
          ),
        ],
      ),
      child: Icon(_modeIcon, size: 16, color: Onb.amber),
    );
  }

  IconData get _modeIcon => switch (mode) {
    TransferMode.bluetooth => Icons.bluetooth_rounded,
    TransferMode.wifi => Icons.wifi_rounded,
    TransferMode.hotspot => Icons.wifi_tethering_rounded,
    TransferMode.guest => Icons.qr_code_rounded,
  };

  // ── reveal helper ──────────────────────────────────────────────────────────

  /// Animates a part in when [on] flips true — an easeOutBack pop by default —
  /// and holds it. The whole radio already repaints every frame off the page's
  /// ambient clocks, so building content inside [builder] costs nothing extra.
  Widget _reveal({
    required bool on,
    required Duration duration,
    Curve curve = Curves.easeOutBack,
    required Widget Function(double t) builder,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: on ? 1.0 : 0.0),
      duration: duration,
      curve: curve,
      builder: (_, t, _) => builder(t),
    );
  }
}

/// Concentric rings streaming off the antenna once the unit is on air — the
/// visible "keyed up and transmitting" reward on the launch beat.
class _TransmitPainter extends CustomPainter {
  final double t;
  final Offset origin;
  final Color color;

  const _TransmitPainter({
    required this.t,
    required this.origin,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    const maxR = 70.0;
    for (var i = 0; i < 3; i++) {
      final f = (t + i / 3) % 1.0;
      final r = 10 + maxR * Curves.easeOut.transform(f);
      final alpha = ((1 - f) * (1 - f) * 130).toInt();
      if (alpha <= 2) continue;
      canvas.drawCircle(origin, r, paint..color = color.withAlpha(alpha));
    }
  }

  @override
  bool shouldRepaint(_TransmitPainter old) =>
      old.t != t || old.origin != origin || old.color != color;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import 'qr_widgets.dart';

/// The app's one camera surface for reading a QR code.
///
/// Every scanner in the product is this widget wearing different labels: the
/// hotspot handshake, and Room entry. That is the whole point — a code shown
/// by [GlowingQrCard] and the thing reading it are drawn with the same amber
/// brackets, the same travelling scanline and the same chasing frame light, so
/// the two ends of a handoff look like one instrument rather than two screens
/// that happen to be in the same app.
///
/// Built against the Galaxy S8+ floor: no mask blurs, no per-frame `ClipPath`,
/// four controllers total, and the HUD is painted in one `CustomPainter` whose
/// only per-frame inputs are three doubles.
class QrScannerSurface extends StatefulWidget {
  const QrScannerSurface({
    required this.title,
    required this.hint,
    required this.searchingLabel,
    required this.lockedLabel,
    required this.cameraDeniedLabel,
    required this.cameraFailedLabel,
    required this.openSettingsLabel,
    required this.onCode,
    this.busyLabel,
    this.errorText,
    super.key,
  });

  /// Small caps title floating over the preview, between close and torch.
  final String title;

  /// One line under the readout saying what to point the camera at.
  final String hint;

  /// Readout while hunting, and once a code is in hand.
  final String searchingLabel;
  final String lockedLabel;

  final String cameraDeniedLabel;
  final String cameraFailedLabel;
  final String openSettingsLabel;

  /// Shown in place of [lockedLabel] while [onCode] is still running — the
  /// window between "we read it" and "you are in", which on a Room join is a
  /// key derivation and two storage writes and is absolutely long enough to
  /// need saying out loud.
  final String? busyLabel;

  /// A failed attempt. Setting this rings the frame red and floats a card
  /// under the window; the scanner re-arms so the user can simply try again.
  final String? errorText;

  /// Handles a decoded payload.
  ///
  /// Return true when the caller is navigating away — the frame stays green
  /// and locked, because re-arming a scanner on a screen that is leaving reads
  /// as the scan having failed. Return false to re-arm for another try.
  final Future<bool> Function(String value) onCode;

  @override
  State<QrScannerSurface> createState() => _QrScannerSurfaceState();
}

class _QrScannerSurfaceState extends State<QrScannerSurface>
    with TickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    // Every code this app reads is a QR. Skipping the other symbologies keeps
    // the detector from chewing frames on formats that cannot appear here.
    formats: const [BarcodeFormat.qrCode],
  );

  /// Scanline crossing the window, same cadence as the QR card's own sweep.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  /// Slow breathing shared by the brackets and the status dot.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  /// Light chasing around the frame — the radar's cadence, so "still looking"
  /// reads the same here as it does on the Bluetooth side.
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..repeat();

  /// Runs on a hit: the frame snaps green and rings out.
  late final AnimationController _lock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  /// Runs on a rejected code: the frame snaps red and rings out. Same shape as
  /// [_lock] on purpose — the user has learned that a ring means "that was
  /// read", and the colour is what says whether it was any good.
  late final AnimationController _fail = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  /// True from the moment a code is read until it is accepted or rejected.
  bool _handling = false;

  /// True once a code has been accepted. Terminal: the camera is done.
  bool _settled = false;

  @override
  void didUpdateWidget(QrScannerSurface old) {
    super.didUpdateWidget(old);
    // A new error is a new event even if the text is identical — the user may
    // have scanned the same expired code twice — so it always re-rings.
    if (widget.errorText != null && widget.errorText != old.errorText) {
      _fail.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    _pulse.dispose();
    _orbit.dispose();
    _lock.dispose();
    _fail.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || _settled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;

      _handling = true;
      // Land the hit before doing anything else. A screen that changes the
      // instant the code is framed reads as a glitch; the buzz and the green
      // ring say "got it" so whatever happens next is not a surprise.
      HapticFeedback.mediumImpact();
      _sweep.stop();
      await _lock.forward();
      if (!mounted) return;
      setState(() {});

      final accepted = await widget.onCode(value);
      if (!mounted) return;

      if (accepted) {
        setState(() => _settled = true);
        return;
      }
      // Rejected: give the camera back. The sweep restarting is the clearest
      // possible signal that the scanner is live again.
      HapticFeedback.heavyImpact();
      await _lock.reverse();
      if (!mounted) return;
      _sweep.repeat(reverse: true);
      _handling = false;
      setState(() {});
      return;
    }
  }

  bool get _busy => _handling && !_settled;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // The camera runs edge to edge, so the system chrome is always sitting
      // on video — light icons regardless of the app theme.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            // Square window, generous on big screens, never crowding the
            // chrome or the readout on small ones. Height gets a say too:
            // sized off the width alone, a landscape phone ends up with a
            // window taller than the screen and the readout pushed off it.
            final side = math.min(
              math.min(
                constraints.maxWidth * 0.72,
                constraints.maxHeight * 0.46,
              ),
              300.0,
            );
            final window = Rect.fromCenter(
              center: Offset(
                constraints.maxWidth / 2,
                constraints.maxHeight * 0.40,
              ),
              width: side,
              height: side,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  // Whole preview is a focus target: a QR on a phone screen a
                  // hand's length away is exactly what autofocus hunts on.
                  // Taps get through because the HUD above ignores pointers.
                  tapToFocus: true,
                  errorBuilder: (context, error) => ScannerErrorPanel(
                    message:
                        error.errorCode ==
                            MobileScannerErrorCode.permissionDenied
                        ? widget.cameraDeniedLabel
                        : widget.cameraFailedLabel,
                    actionLabel:
                        error.errorCode ==
                            MobileScannerErrorCode.permissionDenied
                        ? widget.openSettingsLabel
                        : null,
                    onAction: openAppSettings,
                  ),
                ),
                // The HUD is a sibling here rather than MobileScanner's
                // overlayBuilder. That builder only runs once the camera
                // reports a first frame, so everything before it — the
                // permission sheet on first open, and the warm-up after —
                // was a bare black screen with no viewfinder on it, which
                // reads as a broken camera rather than one starting up.
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _controller,
                  builder: (context, scanner, child) =>
                      scanner.error == null ? child! : const SizedBox.shrink(),
                  child: IgnorePointer(
                    child: _Viewfinder(
                      window: window,
                      sweep: _sweep,
                      pulse: _pulse,
                      orbit: _orbit,
                      lock: _lock,
                      fail: _fail,
                      busy: _busy,
                      searchingLabel: widget.searchingLabel,
                      lockedLabel: _busy && widget.busyLabel != null
                          ? widget.busyLabel!
                          : widget.lockedLabel,
                      hint: widget.hint,
                      errorText: widget.errorText,
                    ),
                  ),
                ),
                // Outside the scanner so the way out stays tappable even when
                // the camera failed.
                _ScannerChrome(title: widget.title, controller: _controller),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Everything painted over the live preview: scrim with the window punched
/// out, reticle, chasing frame light, scanline, brackets and status readout.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({
    required this.window,
    required this.sweep,
    required this.pulse,
    required this.orbit,
    required this.lock,
    required this.fail,
    required this.busy,
    required this.searchingLabel,
    required this.lockedLabel,
    required this.hint,
    required this.errorText,
  });

  final Rect window;
  final Animation<double> sweep;
  final Animation<double> pulse;
  final Animation<double> orbit;
  final Animation<double> lock;
  final Animation<double> fail;
  final bool busy;
  final String searchingLabel;
  final String lockedLabel;
  final String hint;
  final String? errorText;

  /// Height of the scanline strip, including its fading tail.
  static const double _band = 64;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final green = AppColors.green;
    final red = AppColors.red;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrim, reticle and frame in one painter: they share the geometry and
        // all move together, so splitting them would only cost layers.
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([pulse, orbit, lock, fail]),
            builder: (context, _) => CustomPaint(
              painter: _ViewfinderPainter(
                window: window,
                // A full sine off a non-reversing controller, so the breath
                // never pauses at the turn the way a reversing one does.
                glow: 0.5 - 0.5 * math.cos(pulse.value * 2 * math.pi),
                orbit: orbit.value,
                lock: lock.value,
                fail: fail.value,
                accent: amber,
                hit: green,
                miss: red,
              ),
            ),
          ),
        ),
        // Scanline gets its own layer so sweeping it only shuffles a cached
        // strip around instead of repainting the frame every tick.
        Positioned.fromRect(
          rect: window,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_ViewfinderPainter.radius),
            child: FadeTransition(
              // Tween.animate rather than a CurvedAnimation: this rebuilds
              // whenever the camera state ticks, and a CurvedAnimation would
              // leave a status listener on the controller each time.
              opacity: Tween<double>(begin: 1, end: 0).animate(lock),
              // Load-bearing, and it is what this widget's extraction lost:
              // the builder below returns a `Positioned`, which needs a
              // `Stack` as its nearest render-object ancestor. Without one the
              // whole strip throws on mount, and in a release build Flutter
              // fills its place with `RenderErrorBox` — an almost-opaque light
              // grey — clipped to exactly this rounded window. That is the
              // "white veil over the code" and the "missing radar": one fault,
              // both symptoms, and the only reason the frame light survived is
              // that it is painted by the sibling above.
              //
              // `AnimatedBuilder` is not a render-object widget, so the
              // `Positioned` still resolves to this `Stack` and the per-frame
              // work stays one parent-data write.
              child: Stack(
                // The ClipRRect above already owns the edge; a second rect
                // clip here would only cost a layer to say the same thing.
                clipBehavior: Clip.none,
                fit: StackFit.expand,
                children: [
                  AnimatedBuilder(
                    animation: sweep,
                    builder: (context, child) {
                      // Position the bright edge, not the strip, so the tail
                      // can swap sides at the turn without the edge jumping.
                      final edge =
                          Curves.easeInOut.transform(sweep.value) *
                          window.height;
                      // The sweep ping-pongs, so the tail has to ping-pong
                      // with it: it drags behind the edge on the way down and
                      // behind it again on the way up, never ahead of it.
                      final up = sweep.status == AnimationStatus.reverse;
                      return Positioned(
                        top: up ? edge : edge - _band,
                        left: 0,
                        right: 0,
                        child: Transform.flip(flipY: up, child: child!),
                      );
                    },
                    child: const RepaintBoundary(
                      child: _Scanline(
                        key: Key('qr-scanner-sweep'),
                        height: _band,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Brackets float outside the frame and breathe with the pulse — the
        // same painter the QR card wears, so the code and the thing reading it
        // are visibly a matched pair.
        Positioned.fromRect(
          rect: window.inflate(11),
          child: AnimatedBuilder(
            animation: Listenable.merge([pulse, lock, fail]),
            builder: (context, _) {
              final breath = 0.5 - 0.5 * math.cos(pulse.value * 2 * math.pi);
              final hit = Curves.easeOutCubic.transform(lock.value);
              final miss = Curves.easeOutCubic.transform(fail.value);
              return CustomPaint(
                painter: CornerBracketsPainter(
                  color: Color.lerp(Color.lerp(amber, green, hit)!, red, miss)!,
                  length: 30 + breath * 6 + hit * 16,
                  stroke: 3.5 + hit,
                  radius: 20,
                ),
              );
            },
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          top: window.bottom + 30,
          child: Column(
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([pulse, lock]),
                builder: (context, _) {
                  final locked = lock.value > 0.05;
                  final color = locked ? green : amber;
                  final breath =
                      0.5 - 0.5 * math.cos(pulse.value * 2 * math.pi);
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (busy)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 10),
                          child: SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(color),
                            ),
                          ),
                        )
                      else
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsetsDirectional.only(end: 10),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            boxShadow: [
                              BoxShadow(
                                color: color.withAlpha(
                                  locked ? 200 : 70 + (breath * 110).round(),
                                ),
                                blurRadius: 8 + breath * 7,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      Flexible(
                        child: Text(
                          locked ? lockedLabel : searchingLabel,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withAlpha(180),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              // The failure card grows in under the hint rather than replacing
              // anything, so the instruction the user still needs stays put.
              AnimatedSize(
                duration: AppMotion.card,
                curve: AppMotion.easeOut,
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: AppMotion.card,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.leaving,
                  child: errorText == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          key: ValueKey<String>(errorText!),
                          padding: const EdgeInsets.only(top: 18),
                          child: _ScanErrorCard(message: errorText!),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A rejected scan, floated under the viewfinder.
class _ScanErrorCard extends StatelessWidget {
  const _ScanErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('room-join-error'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: AppColors.red.withAlpha(30),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.red.withAlpha(120)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 17, color: AppColors.red),
        const SizedBox(width: 9),
        Flexible(
          child: Text(
            message,
            style: TextStyle(
              color: Colors.white.withAlpha(226),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Fading tail with a bright, glowing edge — the strip that travels the window.
///
/// Built travelling downwards, tail on top. The caller flips it for the upward
/// half of the sweep, so the tail is always the trailing end.
class _Scanline extends StatelessWidget {
  const _Scanline({required this.height, super.key});

  final double height;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.amber;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [accent.withAlpha(0), accent.withAlpha(56)],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
          Container(
            height: 2,
            decoration: BoxDecoration(
              color: accent,
              boxShadow: [
                BoxShadow(
                  color: accent.withAlpha(170),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter({
    required this.window,
    required this.glow,
    required this.orbit,
    required this.lock,
    required this.fail,
    required this.accent,
    required this.hit,
    required this.miss,
  });

  final Rect window;

  /// 0..1 breathing, shared with the brackets and the status dot.
  final double glow;

  /// 0..1 position of the light chasing around the frame.
  final double orbit;

  /// 0..1 hit animation: amber turns green and rings out.
  final double lock;

  /// 0..1 miss animation: amber turns red and rings out.
  final double fail;

  final Color accent;
  final Color hit;
  final Color miss;

  /// Corner rounding of the window, shared with the scanline's clip.
  static const double radius = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color.lerp(Color.lerp(accent, hit, lock)!, miss, fail)!;
    final rrect = RRect.fromRectAndRadius(
      window,
      const Radius.circular(radius),
    );

    // Darken everything outside the window, so the feed reads as one framed
    // instrument instead of a wall of video.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(rrect),
      ),
      Paint()..color = Colors.black.withAlpha(168),
    );

    // Instrument furniture: thirds grid, centre crosshair, ticks off each
    // edge. Faint enough that it never competes with the code being framed.
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withAlpha(24);
    for (final f in const [1 / 3, 2 / 3]) {
      final x = window.left + window.width * f;
      final y = window.top + window.height * f;
      canvas.drawLine(
        Offset(x, window.top + 14),
        Offset(x, window.bottom - 14),
        grid,
      );
      canvas.drawLine(
        Offset(window.left + 14, y),
        Offset(window.right - 14, y),
        grid,
      );
    }

    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = color.withAlpha(95);
    final centre = window.center;
    canvas.drawLine(centre.translate(-7, 0), centre.translate(7, 0), tick);
    canvas.drawLine(centre.translate(0, -7), centre.translate(0, 7), tick);
    canvas.drawLine(
      Offset(centre.dx, window.top),
      Offset(centre.dx, window.top + 11),
      tick,
    );
    canvas.drawLine(
      Offset(centre.dx, window.bottom),
      Offset(centre.dx, window.bottom - 11),
      tick,
    );
    canvas.drawLine(
      Offset(window.left, centre.dy),
      Offset(window.left + 11, centre.dy),
      tick,
    );
    canvas.drawLine(
      Offset(window.right, centre.dy),
      Offset(window.right - 11, centre.dy),
      tick,
    );

    // Hairline frame that breathes...
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withAlpha(56 + (glow * 44).round()),
    );

    // ...with one bright segment chasing around it.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..shader = SweepGradient(
          transform: GradientRotation(orbit * 2 * math.pi),
          colors: [
            color.withAlpha(0),
            color.withAlpha(0),
            color.withAlpha(235),
            color.withAlpha(0),
            color.withAlpha(0),
          ],
          stops: const [0, 0.62, 0.75, 0.88, 1],
        ).createShader(window),
    );

    // Hit and miss ring out identically; only the colour differs, because the
    // gesture the user made was the same and only the answer changed.
    _ring(canvas, rrect, lock, hit);
    _ring(canvas, rrect, fail, miss);
  }

  void _ring(Canvas canvas, RRect rrect, double value, Color color) {
    if (value == 0) return;
    final t = Curves.easeOut.transform(value);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        window.inflate(t * 28),
        Radius.circular(radius + t * 28),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - t)
        ..color = color.withAlpha((225 * (1 - t)).round()),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = color.withAlpha((70 * (1 - t)).round()),
    );
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) =>
      old.glow != glow ||
      old.orbit != orbit ||
      old.lock != lock ||
      old.fail != fail ||
      old.window != window ||
      old.accent != accent;
}

/// Close and torch, floating over the preview. Lives above the scanner rather
/// than inside its overlay so it survives a camera error.
class _ScannerChrome extends StatelessWidget {
  const _ScannerChrome({required this.title, required this.controller});

  final String title;
  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.close_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.of(context).maybePop();
                },
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: controller,
                builder: (context, state, _) {
                  // Also the state a failed camera reports, which is why the
                  // button simply reserves its space instead of collapsing.
                  if (state.torchState == TorchState.unavailable) {
                    return const SizedBox(width: 44);
                  }
                  final on = state.torchState == TorchState.on;
                  return GlassIconButton(
                    icon: on
                        ? Icons.flashlight_on_rounded
                        : Icons.flashlight_off_rounded,
                    active: on,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      controller.toggleTorch();
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A round control that reads over live video: dark glass, hairline ring,
/// amber when it is doing something.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    super.key,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = active ? AppColors.amber : Colors.white;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: AppMotion.chip,
        curve: AppMotion.easeOut,
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? AppColors.amber.withAlpha(40)
              : Colors.black.withAlpha(110),
          border: Border.all(color: tint.withAlpha(active ? 160 : 52)),
        ),
        child: Icon(icon, color: tint, size: 20),
      ),
    );
  }
}

/// Full-bleed panel shown when the camera itself will not start.
class ScannerErrorPanel extends StatelessWidget {
  const ScannerErrorPanel({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.red.withAlpha(24),
                  border: Border.all(color: AppColors.red.withAlpha(120)),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.red.withAlpha(50),
                      blurRadius: 26,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.no_photography_rounded,
                  color: AppColors.red,
                  size: 34,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withAlpha(220),
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 22),
                GestureDetector(
                  onTap: onAction,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.amber.withAlpha(25),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.amber.withAlpha(140),
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      actionLabel!,
                      style: TextStyle(
                        color: AppColors.amber,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

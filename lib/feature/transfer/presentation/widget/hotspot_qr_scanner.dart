import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';

/// Fullscreen viewfinder for the host's Wi-Fi QR, on both platforms — the app
/// never sends the user to the system camera, because a code read there can
/// only be acted on in Settings, outside the flow.
///
/// Dressed as the receiving end of the host's [GlowingQrCard]: same amber
/// brackets and travelling scanline, plus the chasing frame light that echoes
/// the Bluetooth radar sweep. The two ends of the handshake look like one
/// instrument.
///
/// Pops the raw scanned string, or null if the user backed out.
class HotspotQrScannerPage extends StatefulWidget {
  const HotspotQrScannerPage({super.key});

  /// Opens the scanner and returns what was read (null when dismissed).
  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const HotspotQrScannerPage()),
      );

  @override
  State<HotspotQrScannerPage> createState() => _HotspotQrScannerPageState();
}

class _HotspotQrScannerPageState extends State<HotspotQrScannerPage>
    with TickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    // Wi-Fi codes are always QR; skipping the other symbologies keeps the
    // detector from chewing frames on formats that can't appear here.
    formats: const [BarcodeFormat.qrCode],
  );

  /// Scanline crossing the window, same cadence as the host's QR card.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  /// Slow breathing shared by the brackets and the status dot.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  /// Light chasing around the frame — the radar's cadence, so "still looking"
  /// reads the same here as it does on the Bluetooth side.
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..repeat();

  /// Runs once, on a hit: the frame snaps green and rings out before we pop.
  late final AnimationController _lock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  bool _done = false;

  @override
  void dispose() {
    _sweep.dispose();
    _pulse.dispose();
    _orbit.dispose();
    _lock.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _done = true;
      // Land the hit before leaving. A screen that vanishes the instant the
      // code is framed reads as a glitch; the buzz and the green ring say
      // "got it" so the next screen isn't a surprise.
      HapticFeedback.mediumImpact();
      _sweep.stop();
      await _lock.forward();
      if (!mounted) return;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
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
                constraints.maxHeight * 0.42,
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
                  // Whole preview is a focus target: QR on a phone screen a
                  // hand's length away is exactly what autofocus hunts on.
                  // Taps get through because the HUD above ignores pointers.
                  tapToFocus: true,
                  errorBuilder: (context, error) => _ScannerError(
                    message:
                        error.errorCode ==
                            MobileScannerErrorCode.permissionDenied
                        ? s.hotspot_scan_camera_denied
                        : s.hotspot_scan_camera_failed,
                    actionLabel:
                        error.errorCode ==
                            MobileScannerErrorCode.permissionDenied
                        ? s.hotspot_open_settings
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
                // Hidden only on a hard error, where the error card owns
                // the screen.
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
                      searchingLabel: s.hotspot_scan_searching,
                      lockedLabel: s.hotspot_scan_locked,
                      hint: s.hotspot_scan_hint,
                    ),
                  ),
                ),
                // Outside the scanner so the way out stays tappable even when
                // the camera failed.
                _ScannerChrome(
                  title: s.hotspot_scan_host,
                  controller: _controller,
                ),
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
  final Rect window;
  final Animation<double> sweep;
  final Animation<double> pulse;
  final Animation<double> orbit;
  final Animation<double> lock;
  final String searchingLabel;
  final String lockedLabel;
  final String hint;

  /// Height of the scanline strip, including its fading tail.
  static const double _band = 64;

  const _Viewfinder({
    required this.window,
    required this.sweep,
    required this.pulse,
    required this.orbit,
    required this.lock,
    required this.searchingLabel,
    required this.lockedLabel,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final green = AppColors.green;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrim, reticle and frame in one painter: they share the geometry and
        // all three move together, so splitting them would only cost layers.
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([pulse, orbit, lock]),
            builder: (context, _) => CustomPaint(
              painter: _ViewfinderPainter(
                window: window,
                glow: Curves.easeInOut.transform(pulse.value),
                orbit: orbit.value,
                lock: lock.value,
                accent: amber,
                hit: green,
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
              child: Stack(
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
                      child: _Scanline(height: _band),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Brackets float outside the frame and breathe with the pulse — the
        // same painter the host's QR card wears, so the code and the thing
        // reading it are visibly a matched pair.
        Positioned.fromRect(
          rect: window.inflate(11),
          child: AnimatedBuilder(
            animation: Listenable.merge([pulse, lock]),
            builder: (context, _) {
              final breath = Curves.easeInOut.transform(pulse.value);
              final hit = Curves.easeOutCubic.transform(lock.value);
              return CustomPaint(
                painter: CornerBracketsPainter(
                  color: Color.lerp(amber, green, hit)!,
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
                  final breath = Curves.easeInOut.transform(pulse.value);
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
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
                      const SizedBox(width: 10),
                      Text(
                        locked ? lockedLabel : searchingLabel,
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
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
            ],
          ),
        ),
      ],
    );
  }
}

/// Fading tail with a bright, glowing edge — the strip that travels the window.
///
/// Built travelling downwards, tail on top. The caller flips it for the upward
/// half of the sweep, so the tail is always the trailing end.
class _Scanline extends StatelessWidget {
  final double height;

  const _Scanline({required this.height});

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
  final Rect window;

  /// 0..1 breathing, shared with the brackets and the status dot.
  final double glow;

  /// 0..1 position of the light chasing around the frame.
  final double orbit;

  /// 0..1 hit animation: amber turns green and rings out.
  final double lock;

  final Color accent;
  final Color hit;

  /// Corner rounding of the window, shared with the scanline's clip.
  static const double radius = 22;

  _ViewfinderPainter({
    required this.window,
    required this.glow,
    required this.orbit,
    required this.lock,
    required this.accent,
    required this.hit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color.lerp(accent, hit, lock)!;
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

    if (lock == 0) return;

    // Hit: a ring pushes out of the frame and the window flashes green.
    final t = Curves.easeOut.transform(lock);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        window.inflate(t * 28),
        Radius.circular(radius + t * 28),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - t)
        ..color = hit.withAlpha((225 * (1 - t)).round()),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = hit.withAlpha((70 * (1 - t)).round()),
    );
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) =>
      old.glow != glow ||
      old.orbit != orbit ||
      old.lock != lock ||
      old.window != window ||
      old.accent != accent;
}

/// Close and torch, floating over the preview. Lives above the scanner rather
/// than inside its overlay so it survives a camera error.
class _ScannerChrome extends StatelessWidget {
  final String title;
  final MobileScannerController controller;

  const _ScannerChrome({required this.title, required this.controller});

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
              _GlassButton(
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
                  return _GlassButton(
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

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _GlassButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final tint = active ? AppColors.amber : Colors.white;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
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

class _ScannerError extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback onAction;

  const _ScannerError({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

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

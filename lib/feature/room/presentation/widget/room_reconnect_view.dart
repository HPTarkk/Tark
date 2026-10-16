import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../../core/widget/link_preparing_visual.dart';
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

/// Why the scanning side's last attempt failed, when the entry knows.
///
/// Optional: without it the screen counts failures itself. With it, a reason
/// that says this phone cannot get onto the other phone's connection at all
/// ([joinDeclined]) offers the swap first straight away instead of after the
/// second failure.
enum RoomReconnectProblem {
  wifiOff,
  locationOff,

  /// Android would not put this phone on the other phone's connection.
  joinDeclined,

  /// The link came up but nobody answered on it in time.
  noAnswer,
}

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
    this.wifiOff = false,
    this.problem,
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

  /// Scan side only: this phone's Wi-Fi is off. Joining the other phone's
  /// connection needs it, so the screen asks for it before the camera opens —
  /// scanning first and only then finding out was the dead end this replaces.
  /// The showing side never needs Wi-Fi: it is the one sharing.
  final bool wifiOff;

  /// Why the last scan-side attempt failed, when known. Cleared with
  /// [message].
  final RoomReconnectProblem? problem;

  RoomReconnectModel copyWith({
    RoomReconnectPhase? phase,
    String? qrData,
    String? message,
    bool clearMessage = false,
    bool? wifiOff,
    RoomReconnectProblem? problem,
  }) => RoomReconnectModel(
    side: side,
    peerName: peerName,
    phase: phase ?? this.phase,
    qrData: qrData ?? this.qrData,
    message: clearMessage ? null : message ?? this.message,
    canSwitch: canSwitch,
    wifiOff: wifiOff ?? this.wifiOff,
    problem: clearMessage ? problem : problem ?? this.problem,
  );
}

/// The guided "connect these two phones" screen a Room shows when Start finds
/// no link between them.
///
/// It never asks the user to choose a role, a network or a hotspot. One phone
/// is shown a code and told whose phone to hold it up to; the other gets a
/// camera and is told whose code to point it at. Which phone does which is
/// decided before this screen opens, the same way on both phones.
///
/// ## Swapping sides
///
/// Both sides carry a clear way to swap, and the swap is one object turning
/// over: the scanner's brackets close in and flip into the code's frame (or
/// the other way round) while the screen behind them turns on its vertical
/// axis, and the instructions re-flow in after it.
///
/// Until a link exists the two phones cannot tell each other anything, so a
/// swap on one phone is never seen by the other: each swaps by hand. The
/// screen says so where it matters — the scanning side, after its second
/// failure (or at once when this phone cannot get onto the other's connection
/// at all), puts "Show my code instead" first and tells the rider the other
/// phone has to scan; the showing side, once its code has been up a while
/// with nobody arriving, asks whether the other phone is showing a code too.
class RoomReconnectView extends StatefulWidget {
  const RoomReconnectView({
    required this.model,
    required this.onScan,
    required this.onSwitch,
    required this.onRetry,
    required this.onBack,
    this.onTurnOnWifi,
    super.key,
  });

  final RoomReconnectModel model;
  final Future<bool> Function(String raw) onScan;
  final VoidCallback onSwitch;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  /// Opens the system's Wi-Fi switch, for [RoomReconnectModel.wifiOff].
  final VoidCallback? onTurnOnWifi;

  /// How long a code may be up with nobody arriving before the showing side
  /// suggests the other phone may be showing a code too.
  static const showLinger = Duration(seconds: 40);

  @override
  State<RoomReconnectView> createState() => _RoomReconnectViewState();
}

class _RoomReconnectViewState extends State<RoomReconnectView> {
  /// Failed attempts on the scanning side since this phone last swapped.
  int _scanFailures = 0;

  /// The code has been up for [RoomReconnectView.showLinger] with nobody.
  bool _lingered = false;
  Timer? _linger;

  @override
  void initState() {
    super.initState();
    _syncLinger();
  }

  @override
  void didUpdateWidget(RoomReconnectView old) {
    super.didUpdateWidget(old);
    final was = old.model;
    final now = widget.model;
    if (was.side != now.side) {
      // A fresh side is a fresh start: the count was about the other one.
      _scanFailures = 0;
      _lingered = false;
    } else if (now.side == RoomReconnectSide.scan) {
      final failedNow =
          now.phase == RoomReconnectPhase.failed &&
          was.phase != RoomReconnectPhase.failed;
      // A rejected join is reported on the camera's own error card.
      final rejectedNow =
          now.phase == RoomReconnectPhase.waiting &&
          now.message != null &&
          now.message != was.message &&
          was.phase == RoomReconnectPhase.waiting;
      if (failedNow || rejectedNow) _scanFailures++;
    }
    _syncLinger();
  }

  void _syncLinger() {
    final model = widget.model;
    final waiting =
        model.side == RoomReconnectSide.show &&
        model.phase == RoomReconnectPhase.waiting &&
        model.canSwitch;
    if (!waiting) {
      _linger?.cancel();
      _linger = null;
      if (model.side == RoomReconnectSide.show &&
          model.phase == RoomReconnectPhase.preparing) {
        _lingered = false;
      }
      return;
    }
    if (_linger != null || _lingered) return;
    _linger = Timer(RoomReconnectView.showLinger, () {
      if (mounted) setState(() => _lingered = true);
    });
  }

  @override
  void dispose() {
    _linger?.cancel();
    super.dispose();
  }

  /// Whether swapping is now the better way forward on the scanning side.
  bool get _swapFirst {
    final model = widget.model;
    if (!model.canSwitch || model.side != RoomReconnectSide.scan) return false;
    return _scanFailures >= 2 ||
        model.problem == RoomReconnectProblem.joinDeclined;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final swapFirst = _swapFirst;
    // The scanner's close button and system back both mean "not now": back to
    // the Room, never out of it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
      },
      child: _RoleMorph(
        side: model.side,
        // Changes within one side are a quiet crossfade; the morph is kept
        // for the side itself changing.
        child: AnimatedSwitcher(
          duration: AppMotion.card,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          child: model.side == RoomReconnectSide.scan && model.wifiOff
              ? _WifiNeeded(
                  key: const ValueKey('room-reconnect-wifi'),
                  model: model,
                  onTurnOnWifi: widget.onTurnOnWifi,
                  onSwitch: widget.onSwitch,
                  onBack: widget.onBack,
                )
              : model.side == RoomReconnectSide.scan &&
                    (model.phase == RoomReconnectPhase.connecting ||
                        model.phase == RoomReconnectPhase.failed)
              ? _ScanJourney(
                  key: const ValueKey('room-reconnect-journey'),
                  model: model,
                  swapFirst: swapFirst,
                  onScanAgain: widget.onRetry,
                  onSwitch: widget.onSwitch,
                  onBack: widget.onBack,
                )
              : model.side == RoomReconnectSide.show &&
                    model.phase == RoomReconnectPhase.failed
              ? _ShowJourney(
                  key: const ValueKey('room-reconnect-show-failed'),
                  model: model,
                  onRetry: widget.onRetry,
                  onSwitch: widget.onSwitch,
                  onBack: widget.onBack,
                )
              : model.side == RoomReconnectSide.scan
              ? _ScanSide(
                  key: const ValueKey('room-reconnect-scan'),
                  model: model,
                  swapFirst: swapFirst,
                  onScan: widget.onScan,
                  onSwitch: widget.onSwitch,
                )
              : _ShowSide(
                  key: const ValueKey('room-reconnect-show'),
                  model: model,
                  lingered: _lingered,
                  onSwitch: widget.onSwitch,
                  onRetry: widget.onRetry,
                  onBack: widget.onBack,
                ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- role morph

/// What the morph lends the screens inside it: where the show side's code
/// frame is (so the flight can land on it), and how far the incoming side
/// has arrived (so its instructions can re-flow in one after another).
class _MorphScope extends InheritedWidget {
  const _MorphScope({
    required this.cardKey,
    required this.arrival,
    required super.child,
    super.key,
  });

  final GlobalKey cardKey;

  /// 0..1 while a side is arriving; complete otherwise.
  final Animation<double> arrival;

  static _MorphScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MorphScope>();

  @override
  bool updateShouldNotify(_MorphScope old) =>
      old.cardKey != cardKey || old.arrival != arrival;
}

/// Turns one side of the reconnect into the other as a single object.
///
/// The side that is leaving dims (the camera goes dark) and turns away on its
/// vertical axis; the brackets that framed the camera lift off it, close in
/// and flip over into the frame of the code (or the code's frame lifts off,
/// opens out and flips into the scanner's window); the arriving side turns in
/// behind them, and its instructions re-flow in a short stagger. The turn
/// runs towards the reading end, so it mirrors in right-to-left.
///
/// Under reduced motion it is a plain, short crossfade.
///
/// Cost: two transformed layers and one small painter for one 860 ms beat,
/// then nothing — the controller is idle between swaps.
class _RoleMorph extends StatefulWidget {
  const _RoleMorph({required this.side, required this.child});

  final RoomReconnectSide side;
  final Widget child;

  static const duration = Duration(milliseconds: 860);

  @override
  State<_RoleMorph> createState() => _RoleMorphState();
}

class _RoleMorphState extends State<_RoleMorph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: _RoleMorph.duration,
    value: 1,
  );

  /// The side on its way out, with the last thing it showed.
  RoomReconnectSide? _outgoingSide;
  Widget? _outgoing;

  /// One root per side, inside its transform, so positions measured in it are
  /// the untransformed layout.
  final _roots = {
    RoomReconnectSide.scan: GlobalKey(debugLabel: 'reconnect-scan-root'),
    RoomReconnectSide.show: GlobalKey(debugLabel: 'reconnect-show-root'),
  };
  final _cardKey = GlobalKey(debugLabel: 'reconnect-code-frame');

  late final Animation<double> _arrival = CurvedAnimation(
    parent: _t,
    curve: const Interval(0.5, 1),
  );

  /// The leaving side's lines fold away in the reverse order, last first,
  /// before it turns.
  late final Animation<double> _departure = ReverseAnimation(
    CurvedAnimation(parent: _t, curve: const Interval(0, 0.42)),
  );

  @override
  void initState() {
    super.initState();
    _t.addStatusListener((status) {
      if (status == AnimationStatus.completed && _outgoing != null) {
        setState(() {
          _outgoing = null;
          _outgoingSide = null;
        });
      }
    });
  }

  @override
  void didUpdateWidget(_RoleMorph old) {
    super.didUpdateWidget(old);
    if (old.side == widget.side) return;
    _outgoingSide = old.side;
    _outgoing = old.child;
    HapticFeedback.selectionClick();
    _t.duration = AppMotion.reduced(context)
        ? AppMotion.card
        : _RoleMorph.duration;
    _t.forward(from: 0);
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// The bracket box a side shows, in this widget's coordinates.
  ///
  /// Read while painting, when every layer has been laid out for the frame;
  /// a side's position is measured inside its own turn, so it is where its
  /// frame sits on screen once it faces the rider.
  Rect _bracketsOf(RoomReconnectSide side, Size size, double topInset) {
    if (side == RoomReconnectSide.show) {
      final card = _cardKey.currentContext?.findRenderObject();
      final root = _roots[side]!.currentContext?.findRenderObject();
      if (card is RenderBox &&
          root is RenderBox &&
          card.attached &&
          root.attached &&
          card.hasSize) {
        final topLeft = card.localToGlobal(Offset.zero, ancestor: root);
        return topLeft & card.size;
      }
      // Not laid out yet: where the code's frame sits on a phone.
      final extent = LinkPreparingVisual.extentFor(_ShowSide.qrSize);
      return Rect.fromLTWH(
        (size.width - extent) / 2,
        topInset + 64,
        extent,
        extent,
      );
    }
    return QrScannerSurface.bracketsFor(size);
  }

  Widget _layer(
    RoomReconnectSide side,
    Widget child, {
    required bool incoming,
  }) {
    final reduced = AppMotion.reduced(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Turning towards the show side spins one way, back to the camera the
    // other; mirrored in right-to-left.
    final toShow = widget.side == RoomReconnectSide.show;
    final dir = (toShow ? 1.0 : -1.0) * (rtl ? -1.0 : 1.0);
    final root = KeyedSubtree(key: _roots[side], child: child);
    final morphing = _outgoing != null && !reduced;
    return _MorphScope(
      key: ValueKey(side),
      cardKey: _cardKey,
      arrival: !morphing
          ? kAlwaysCompleteAnimation
          : incoming
          ? _arrival
          : _departure,
      child: AnimatedBuilder(
        animation: _t,
        child: root,
        builder: (context, root) {
          final t = _t.value;
          final settled = !_t.isAnimating && t == 1;
          if (settled) return root!;
          if (reduced) {
            return IgnorePointer(
              ignoring: !incoming,
              child: Opacity(opacity: incoming ? t : 1 - t, child: root),
            );
          }
          // Each half owns the screen alone, so nothing a finder or a tap
          // reaches is ever doubled.
          final visible = incoming ? t >= 0.5 : t < 0.5;
          final double angle;
          final double scale;
          if (incoming) {
            final p = Curves.easeOutCubic.transform(_span(t, 0.5, 1));
            angle = -dir * (1 - p) * math.pi / 2;
            scale = 0.94 + 0.06 * p;
          } else {
            final p = Curves.easeInCubic.transform(_span(t, 0, 0.5));
            angle = dir * p * math.pi / 2;
            scale = 1 - 0.06 * p;
          }
          // The camera (or the code) goes dark as it turns away; the arriving
          // side comes up out of the same dark.
          final dark = incoming
              ? 0.6 * (1 - _span(t, 0.5, 0.8))
              : 0.7 * _span(t, 0, 0.4);
          return Offstage(
            offstage: !visible,
            child: IgnorePointer(
              ignoring: !incoming,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0011)
                  ..rotateY(angle)
                  ..scaleByDouble(scale, scale, 1, 1),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    root!,
                    if (dark > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: AppColors.background.withValues(alpha: dark),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outgoing = _outgoing;
    final outgoingSide = _outgoingSide;
    final reduced = AppMotion.reduced(context);
    final topInset = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      // What shows through while a side is edge-on.
      color: AppColors.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (outgoing != null && outgoingSide != null)
            _layer(outgoingSide, outgoing, incoming: false),
          _layer(widget.side, widget.child, incoming: true),
          if (outgoing != null && !reduced)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _BracketFlightPainter(
                    progress: _t,
                    from: (size) => _bracketsOf(outgoingSide!, size, topInset),
                    to: (size) => _bracketsOf(widget.side, size, topInset),
                    color: AppColors.amber,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The one continuous object of a swap: four corner brackets that lift off
/// one side's frame, close in, flip over on their vertical axis and settle on
/// the other side's frame.
class _BracketFlightPainter extends CustomPainter {
  _BracketFlightPainter({
    required this.progress,
    required this.from,
    required this.to,
    required this.color,
  }) : super(repaint: progress);

  final Animation<double> progress;

  /// Where each side's frame is, for the painted size. Asked at paint time,
  /// when the layers under it have been laid out.
  final Rect Function(Size size) from;
  final Rect Function(Size size) to;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final from = this.from(size);
    final to = this.to(size);
    // Fade in over the real brackets it lifts off, out onto the ones it lands
    // on, so the hand-over at both ends is invisible.
    final alpha = math.min(_span(t, 0, 0.08), 1 - _span(t, 0.9, 1));
    if (alpha <= 0) return;
    final travel = AppMotion.easeInOut.transform(_span(t, 0.08, 0.92));
    var rect = Rect.lerp(from, to, travel)!;
    // Closing in on the way: the frame contracts through the middle of the
    // flight before opening out to its new size.
    final squeeze = 1 - 0.22 * math.sin(math.pi * travel);
    rect = Rect.fromCenter(
      center: rect.center,
      width: rect.width * squeeze,
      height: rect.height * squeeze,
    );
    // The flip: edge-on at the middle, where the two sides swap over.
    final flip = math.cos(math.pi * _span(t, 0.15, 0.85)).abs();
    final width = math.max(rect.width * flip, 2.0);
    final drawn = Rect.fromCenter(
      center: rect.center,
      width: width,
      height: rect.height,
    );
    // Brighter and a touch heavier while edge-on: the hinge of the swap.
    final hinge = 1 - flip;
    canvas.save();
    canvas.translate(drawn.left, drawn.top);
    CornerBracketsPainter(
      color: color.withValues(alpha: alpha * (0.85 + 0.15 * hinge)),
      length: math.min(30, width / 2),
      stroke: 3.5 + 1.2 * hinge,
      radius: math.min(18, width / 2),
    ).paint(canvas, drawn.size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BracketFlightPainter old) =>
      old.progress != progress || old.color != color;
}

/// One line of instructions re-flowing in after a swap, [index] places down
/// the stagger. Does nothing outside a swap.
class _Reflow extends StatelessWidget {
  const _Reflow({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final arrival = _MorphScope.of(context)?.arrival;
    if (arrival == null || arrival == kAlwaysCompleteAnimation) return child;
    return AnimatedBuilder(
      animation: arrival,
      child: child,
      builder: (context, child) {
        final start = 0.15 + index * 0.13;
        final p = Curves.easeOutBack.transform(
          _span(arrival.value, start, math.min(1, start + 0.55)),
        );
        if (p >= 1) return child!;
        return Opacity(
          opacity: p.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, AppMotion.rise * 1.4 * (1 - p)),
            child: child,
          ),
        );
      },
    );
  }
}

double _span(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);

// ----------------------------------------------------------------- sides

class _ScanSide extends StatelessWidget {
  const _ScanSide({
    required this.model,
    required this.swapFirst,
    required this.onScan,
    required this.onSwitch,
    super.key,
  });

  final RoomReconnectModel model;
  final bool swapFirst;
  final Future<bool> Function(String raw) onScan;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    // The scanner is its own Scaffold, so what floats over it sits outside
    // any Material: its text came out in the fallback style, yellow
    // underline and no app font (2026-10-16). One transparent Material
    // under the whole stack gives it the theme's text.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
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
              // The entry's own words win; otherwise the reason it reported,
              // said plainly over the camera that just failed to get anywhere.
              errorText:
                  model.message ??
                  switch (model.problem) {
                    RoomReconnectProblem.wifiOff => s.rcv_reason_wifi_off,
                    RoomReconnectProblem.locationOff =>
                      s.rcv_reason_location_off,
                    RoomReconnectProblem.joinDeclined => s.rcv_reason_declined,
                    RoomReconnectProblem.noAnswer || null => null,
                  },
              onCode: onScan,
            ),
          ),
          if (model.canSwitch)
            Positioned(
              left: 20,
              right: 20,
              bottom: 20 + MediaQuery.paddingOf(context).bottom,
              child: _Reflow(
                index: 1,
                child: AnimatedSwitcher(
                  duration: AppMotion.sheet,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.leaving,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: swapFirst
                      ? _SwapSuggestion(
                          key: const ValueKey('swap-first'),
                          hint:
                              model.problem == RoomReconnectProblem.joinDeclined
                              ? s.rcv_scan_declined_hint(model.peerName)
                              : s.rcv_scan_switch_hint(model.peerName),
                          label: s.reconnect_switch_to_show,
                          icon: Icons.qr_code_2_rounded,
                          onTap: onSwitch,
                        )
                      : Center(
                          key: const ValueKey('swap-quiet'),
                          child: _SwitchButton(
                            key: const Key('room-reconnect-switch'),
                            label: s.reconnect_switch_to_show,
                            icon: Icons.qr_code_2_rounded,
                            onTap: onSwitch,
                            onDark: true,
                          ),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The swap, promoted: a short reason and the one button that acts on it,
/// floating over the camera.
class _SwapSuggestion extends StatelessWidget {
  const _SwapSuggestion({
    required this.hint,
    required this.label,
    required this.icon,
    required this.onTap,
    super.key,
  });

  final String hint;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(190),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.amber.withAlpha(110)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('room-reconnect-switch'),
            onPressed: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: Icon(icon),
            label: Text(
              label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

/// The scan side once a code was read: the camera is gone and the link it
/// asked for is drawn being made, then locking in or snapping with the way
/// forward. One scene for both, so a failure lands where the rider is already
/// looking.
class _ScanJourney extends StatelessWidget {
  const _ScanJourney({
    required this.model,
    required this.swapFirst,
    required this.onScanAgain,
    required this.onSwitch,
    required this.onBack,
    super.key,
  });

  final RoomReconnectModel model;
  final bool swapFirst;
  final VoidCallback onScanAgain;
  final VoidCallback onSwitch;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final failed = model.phase == RoomReconnectPhase.failed;
    // The entry's own words first, then the reason it reported, in plain
    // language, and only then the generic line.
    final reason =
        model.message ??
        switch (model.problem) {
          RoomReconnectProblem.wifiOff => s.rcv_reason_wifi_off,
          RoomReconnectProblem.locationOff => s.rcv_reason_location_off,
          RoomReconnectProblem.joinDeclined => s.rcv_reason_declined,
          RoomReconnectProblem.noAnswer => s.rcv_reason_no_answer,
          null => s.reconnect_join_failed,
        };
    final scanAgain = FilledButton(
      key: const Key('room-reconnect-scan-again'),
      onPressed: onScanAgain,
      child: Text(s.journey_scan_again),
    );
    final swap = swapFirst
        ? FilledButton.icon(
            key: const Key('room-reconnect-switch'),
            onPressed: onSwitch,
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(s.reconnect_switch_to_show),
          )
        : OutlinedButton.icon(
            key: const Key('room-reconnect-switch'),
            onPressed: onSwitch,
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(s.reconnect_switch_to_show),
          );
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ConnectionJourney(
          stage: failed ? JourneyStage.failed : JourneyStage.linking,
          link: JourneyLink.hotspot,
          caption: model.peerName,
          title: failed ? s.journey_failed_title : s.journey_handshake_title,
          detail: !failed
              ? s.journey_handshake_detail
              : swapFirst
              ? '$reason\n${s.rcv_scan_switch_hint(model.peerName)}'
              : reason,
          actions: failed
              ? [
                  if (swapFirst && model.canSwitch) swap,
                  if (swapFirst && model.canSwitch)
                    OutlinedButton(
                      key: const Key('room-reconnect-scan-again'),
                      onPressed: onScanAgain,
                      child: Text(s.journey_scan_again),
                    )
                  else
                    scanAgain,
                  if (!swapFirst && model.canSwitch) swap,
                  TextButton(
                    key: const Key('room-reconnect-not-now'),
                    onPressed: onBack,
                    child: Text(s.journey_not_now),
                  ),
                ]
              : const [],
        ),
      ),
    );
  }
}

/// The show side when its code could not be made or nobody arrived on it:
/// the same scene the scan side fails in, the link drawn reaching for the
/// other phone and snapping, with the reason and the way forward under it.
/// A bare icon and a sentence read as the app giving up (2026-10-16).
class _ShowJourney extends StatelessWidget {
  const _ShowJourney({
    required this.model,
    required this.onRetry,
    required this.onSwitch,
    required this.onBack,
    super.key,
  });

  final RoomReconnectModel model;
  final VoidCallback onRetry;
  final VoidCallback onSwitch;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ConnectionJourney(
          stage: JourneyStage.failed,
          link: JourneyLink.hotspot,
          caption: model.peerName,
          title: s.journey_failed_title,
          detail: model.message ?? s.reconnect_host_failed,
          actions: [
            FilledButton.icon(
              key: const Key('room-reconnect-retry'),
              onPressed: () {
                HapticFeedback.selectionClick();
                onRetry();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(s.reconnect_retry),
            ),
            if (model.canSwitch)
              OutlinedButton.icon(
                key: const Key('room-reconnect-switch'),
                onPressed: onSwitch,
                icon: const Icon(Icons.photo_camera_rounded),
                label: Text(s.reconnect_switch_to_scan),
              ),
            TextButton(
              key: const Key('room-reconnect-not-now'),
              onPressed: onBack,
              child: Text(s.journey_not_now),
            ),
          ],
        ),
      ),
    );
  }
}

/// The scan side, before the camera: this phone's Wi-Fi is off, and joining
/// the other phone's connection needs it on.
///
/// Says what is needed, why (and that no internet is involved), and offers
/// the one control that fixes it. The entry watches the radio and swaps the
/// camera in by itself the moment Wi-Fi is on, so there is no "done" to press.
class _WifiNeeded extends StatelessWidget {
  const _WifiNeeded({
    required this.model,
    required this.onTurnOnWifi,
    required this.onSwitch,
    required this.onBack,
    super.key,
  });

  final RoomReconnectModel model;
  final VoidCallback? onTurnOnWifi;
  final VoidCallback onSwitch;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final turnOn = onTurnOnWifi;
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
                      // Mirrors itself in right-to-left (matchTextDirection).
                      Icons.arrow_back_rounded,
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
                padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                child: Column(
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.amber.withValues(alpha: 0.12),
                        border: Border.all(
                          color: AppColors.amber.withValues(alpha: 0.55),
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.wifi_off_rounded,
                        size: 40,
                        color: AppColors.amber,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      s.reconnect_wifi_needed_title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.reconnect_wifi_needed_body(model.peerName),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (turnOn != null)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('room-reconnect-turn-on-wifi'),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            turnOn();
                          },
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: const Icon(Icons.wifi_rounded),
                          label: Text(
                            s.reconnect_wifi_needed_action,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Text(
                      s.reconnect_wifi_needed_waiting,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (model.canSwitch)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: _Reflow(
                  index: 1,
                  child: _SwitchButton(
                    key: const Key('room-reconnect-switch'),
                    label: s.reconnect_switch_to_show,
                    icon: Icons.qr_code_2_rounded,
                    onTap: onSwitch,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ShowSide extends StatelessWidget {
  const _ShowSide({
    required this.model,
    required this.lingered,
    required this.onSwitch,
    required this.onRetry,
    required this.onBack,
    super.key,
  });

  final RoomReconnectModel model;

  /// The code has been up a while and nobody has arrived.
  final bool lingered;
  final VoidCallback onSwitch;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  static const double qrSize = 232;

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
                      // Mirrors itself in right-to-left (matchTextDirection), so it
                      // already points the way back in Persian.
                      Icons.arrow_back_rounded,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _Reflow(
                      index: 0,
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
                child: _Reflow(
                  index: 3,
                  child: AnimatedSize(
                    duration: AppMotion.sheet,
                    curve: AppMotion.easeOut,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (lingered) ...[
                          Text(
                            s.rcv_show_switch_hint(model.peerName),
                            key: const Key('room-reconnect-linger-hint'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        _SwitchButton(
                          key: const Key('room-reconnect-switch'),
                          label: s.reconnect_switch_to_scan,
                          icon: Icons.photo_camera_rounded,
                          onTap: onSwitch,
                          emphasised: lingered,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final s = context.getString;
    final morph = _MorphScope.of(context);
    switch (model.phase) {
      case RoomReconnectPhase.connecting:
        return _StatusBlock(
          key: const ValueKey('connecting'),
          icon: Icons.check_circle_rounded,
          iconColor: AppColors.green,
          text: s.reconnect_connecting,
        );
      case RoomReconnectPhase.failed:
        // Told by [_ShowJourney] instead.
        return const SizedBox.shrink(key: ValueKey('failed'));
      case RoomReconnectPhase.preparing:
      case RoomReconnectPhase.waiting:
        // One widget for the wait and the code, so the beacon resolves into
        // the code in place instead of the two crossfading.
        final data = model.phase == RoomReconnectPhase.waiting
            ? model.qrData
            : null;
        final preparing = data == null;
        return Column(
          key: const ValueKey('code'),
          children: [
            LinkPreparingVisual(
              // The frame a swap's brackets fly to and from.
              key: morph?.cardKey,
              kind: LinkPreparingKind.hotspot,
              qrSize: qrSize,
              ready: data == null
                  ? null
                  : Semantics(
                      image: true,
                      label: s.reconnect_show_step_hold,
                      child: GlowingQrCard(data: data, size: qrSize),
                    ),
            ),
            if (preparing) ...[
              const SizedBox(height: 16),
              const _Reflow(
                index: 1,
                child: LinkPreparingCaption(
                  key: Key('room-reconnect-preparing'),
                  kind: LinkPreparingKind.hotspot,
                ),
              ),
            ],
            if (!preparing) ...[
              const SizedBox(height: 20),
              _Reflow(
                index: 1,
                child: _WaitingPulse(text: s.reconnect_waiting(model.peerName)),
              ),
              const SizedBox(height: 20),
              _Reflow(
                index: 2,
                child: Container(
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
              ),
            ],
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

/// The swap, always one clear tap away: an outlined pill with the icon of the
/// side it leads to. [emphasised] fills it in amber when the screen thinks the
/// swap is likely what is needed.
class _SwitchButton extends StatelessWidget {
  const _SwitchButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.onDark = false,
    this.emphasised = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool onDark;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final foreground = emphasised
        ? AppColors.amber
        : onDark
        ? Colors.white
        : AppColors.textPrimary;
    return AnimatedContainer(
      duration: AppMotion.sheet,
      curve: AppMotion.easeOut,
      decoration: BoxDecoration(
        color: emphasised
            ? AppColors.amber.withAlpha(30)
            : onDark
            ? Colors.black.withAlpha(150)
            : AppColors.card,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: emphasised
              ? AppColors.amber
              : onDark
              ? Colors.white.withAlpha(90)
              : AppColors.border,
          width: emphasised ? 1.6 : 1.2,
        ),
      ),
      child: TextButton.icon(
        onPressed: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
        icon: Icon(
          icon,
          size: 19,
          color: emphasised || !onDark ? AppColors.amber : Colors.white,
        ),
        label: Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

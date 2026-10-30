import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../data/store_launcher.dart';
import '../../data/update_checker.dart';
import '../../domain/entity/update_feed.dart';
import 'update_visuals.dart';

/// Checks for a newer build once per launch and, if there is one, puts the
/// prompt over the app.
///
/// Sits in `MaterialApp.builder`, above the navigator, so the prompt belongs
/// to no route: nothing can push over a required update, and an optional one
/// does not end up in the back stack.
///
/// When it shows is the whole design:
/// - **Never on the splash.** The splash is the app's first impression, and
///   the check is still in flight anyway.
/// - **Optional: only on the home and room-list screens.** It waits there
///   rather than interrupting a channel — a prompt over a live conversation
///   costs someone the thing they opened the app for.
/// - **Required: anywhere after the splash.** The version is past its
///   minimum; continuing would be worse than stopping.
/// - **Failure: never.** No signal, a bad file, a slow host — the app never
///   learns there was a question.
class UpdateGate extends StatefulWidget {
  const UpdateGate({
    required this.child,
    required this.location,
    required this.locationChanges,
    super.key,
  });

  final Widget child;

  /// The router's current path.
  final String Function() location;

  /// Fires when [location] may have changed.
  final Listenable locationChanges;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  UpdateOffer? _offer;
  bool _optionalDone = false;

  /// Set once the required screen fully covers the app, which then leaves the
  /// tree: nothing underneath stays reachable, the back gesture included.
  bool _appRetired = false;

  static const _optionalHomes = {AppRoutes.landingPath, AppRoutes.roomsPath};

  @override
  void initState() {
    super.initState();
    widget.locationChanges.addListener(_onLocation);
    unawaited(_check());
  }

  @override
  void didUpdateWidget(UpdateGate old) {
    super.didUpdateWidget(old);
    if (old.locationChanges != widget.locationChanges) {
      old.locationChanges.removeListener(_onLocation);
      widget.locationChanges.addListener(_onLocation);
    }
  }

  @override
  void dispose() {
    widget.locationChanges.removeListener(_onLocation);
    super.dispose();
  }

  Future<void> _check() async {
    final offer = await GetIt.instance<UpdateChecker>().check();
    if (!mounted || offer == null) return;
    setState(() => _offer = offer);
  }

  void _onLocation() {
    if (_offer != null && mounted) setState(() {});
  }

  bool get _showRequired =>
      _offer?.urgency == UpdateUrgency.required &&
      widget.location() != AppRoutes.splashPath;

  bool get _showOptional =>
      _offer?.urgency == UpdateUrgency.optional &&
      !_optionalDone &&
      _optionalHomes.contains(widget.location());

  void _later() {
    final offer = _offer;
    if (offer != null) unawaited(GetIt.instance<UpdateChecker>().snooze(offer));
    setState(() => _optionalDone = true);
  }

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    return Stack(
      children: [
        if (!_appRetired) Positioned.fill(child: widget.child),
        if (offer != null && _showOptional)
          Positioned.fill(
            child: _OptionalPrompt(
              offer: offer,
              onLater: _later,
              onOpened: () => setState(() => _optionalDone = true),
            ),
          ),
        if (offer != null && _showRequired)
          Positioned.fill(
            child: _RequiredPrompt(
              offer: offer,
              onCovered: () => setState(() => _appRetired = true),
            ),
          ),
      ],
    );
  }
}

/// Opens the store and reports whether it worked; shared by both prompts.
mixin _StoreAction<T extends StatefulWidget> on State<T> {
  bool busy = false;
  bool failed = false;

  Future<bool> openStore(UpdateOffer offer) async {
    HapticFeedback.lightImpact();
    setState(() {
      busy = true;
      failed = false;
    });
    final opened = await GetIt.instance<StoreLauncher>().openListing(
      offer.feed.url,
    );
    if (mounted) {
      setState(() {
        busy = false;
        failed = !opened;
      });
    }
    return opened;
  }
}

String _languageOf(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

// ── Optional ────────────────────────────────────────────────────────────────

/// Where each beat of the optional sheet's arrival sits on its one shared
/// controller, so every piece agrees on the order without talking to the
/// others.
///
/// The order is the story of the update: the transmitter powers on and sends
/// one pulse across the sheet, the headline tunes in line by line, the
/// installed version is struck through and the new one counts over it, the
/// notes tick off, and only then does the button land — with its first glint
/// — and the way out appear.
abstract final class _Arrival {
  static const duration = Duration(milliseconds: 1500);

  static const disc = Interval(0.02, 0.34, curve: Curves.easeOutBack);
  static const discFade = Interval(0.02, 0.14);
  static const pulse = Interval(0.12, 0.62);

  /// Eyebrow, title, body: one after another.
  static Interval line(int i) {
    final start = 0.16 + 0.05 * i;
    return Interval(start, start + 0.3, curve: AppMotion.easeOut);
  }

  static const hop = Interval(0.3, 0.84);
  static const notes = Interval(0.4, 0.92);
  static const action = Interval(0.6, 0.9, curve: Curves.easeOutBack);
  static const actionFade = Interval(0.6, 0.74);
  static const later = Interval(0.76, 1, curve: AppMotion.easeOut);
}

class _OptionalPrompt extends StatefulWidget {
  const _OptionalPrompt({
    required this.offer,
    required this.onLater,
    required this.onOpened,
  });

  final UpdateOffer offer;
  final VoidCallback onLater;
  final VoidCallback onOpened;

  @override
  State<_OptionalPrompt> createState() => _OptionalPromptState();
}

class _OptionalPromptState extends State<_OptionalPrompt>
    with TickerProviderStateMixin, _StoreAction {
  /// Where the sheet sits: 0 off the bottom edge, 1 docked. Unbounded so the
  /// spring can carry it a hair past docked and settle, and so a drag can
  /// stretch it upward against resistance.
  late final AnimationController _sheet = AnimationController.unbounded(
    vsync: this,
  );

  /// The content's entrance, read by every piece through [_Arrival].
  late final AnimationController _show = AnimationController(
    vsync: this,
    duration: _Arrival.duration,
  );

  /// A little under-damped: it lands with the faintest overshoot, which is
  /// what makes it read as something with weight rather than a slide.
  static final _rise = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 260,
    ratio: 0.8,
  );

  /// Critically damped on the way out: it never bounces off the bottom edge.
  static final _fall = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 640,
    ratio: 1,
  );

  /// In sheet-heights: a hair from the edge is off screen already, so the
  /// spring stops there instead of creeping through its last pixel.
  static const _gone = Tolerance(distance: 0.004, velocity: 0.05);

  final _sheetKey = GlobalKey();
  final _emblemKey = GlobalKey();
  final _pulseCentre = ValueNotifier<Offset?>(null);

  bool _started = false;
  bool _leaving = false;

  /// The drag's own position before resistance, so letting go above the
  /// docked line springs back from where the finger actually is.
  double _dragRaw = 1;

  @override
  void initState() {
    super.initState();
    // A beat after the home screen settles, so the prompt arrives on a page
    // rather than with it.
    // Built only then, too, so the content's entrance plays while the sheet
    // rises instead of unseen before it.
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _started = true);
      _open();
      _show.forward();
      _locateEmblem();
    });
  }

  @override
  void dispose() {
    _sheet.dispose();
    _show.dispose();
    _pulseCentre.dispose();
    super.dispose();
  }

  bool get _reduced => AppMotion.reduced(context);

  void _open() {
    if (_reduced) {
      _sheet.animateTo(1, duration: AppMotion.sheet, curve: AppMotion.easeOut);
    } else {
      _sheet.animateWith(SpringSimulation(_rise, _sheet.value, 1, 0));
    }
  }

  /// Where the emblem's centre sits inside the sheet, for the power-on
  /// pulse. Measured rather than assumed, so a larger text scale or a
  /// narrower phone still sends the pulse out of the disc.
  void _locateEmblem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sheet = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
      final emblem =
          _emblemKey.currentContext?.findRenderObject() as RenderBox?;
      if (!mounted || sheet == null || emblem == null) return;
      _pulseCentre.value = emblem.localToGlobal(
        emblem.size.center(Offset.zero),
        ancestor: sheet,
      );
    });
  }

  Future<void> _leave(VoidCallback then, {double velocity = 0}) async {
    if (_leaving) return;
    _leaving = true;
    if (_reduced) {
      await _sheet.animateTo(
        0,
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
      );
    } else {
      // Aimed a touch past the edge so the spring's tail is spent off screen
      // rather than creeping the last pixel.
      await _sheet.animateWith(
        SpringSimulation(
          _fall,
          _sheet.value,
          -0.02,
          velocity,
          tolerance: _gone,
        ),
      );
    }
    if (mounted) then();
  }

  Future<void> _update() async {
    if (await openStore(widget.offer)) unawaited(_leave(widget.onOpened));
  }

  double get _sheetHeight =>
      (_sheetKey.currentContext?.findRenderObject() as RenderBox?)
          ?.size
          .height ??
      0;

  void _dragStart(DragStartDetails _) {
    if (_leaving) return;
    _sheet.stop();
    _dragRaw = _sheet.value;
  }

  void _dragUpdate(DragUpdateDetails details) {
    final height = _sheetHeight;
    if (_leaving || height <= 0) return;
    _dragRaw -= details.primaryDelta! / height;
    // Down follows the finger exactly; up past docked gives way less and
    // less, so the sheet can be tugged but never pulled loose.
    final over = _dragRaw - 1;
    _sheet.value = over <= 0 ? _dragRaw : 1 + 0.1 * over / (over + 0.1);
  }

  void _dragEnd(DragEndDetails details) {
    final height = _sheetHeight;
    if (_leaving || height <= 0) return;
    // Sheet-heights per second, upward positive like the controller.
    final velocity = -details.velocity.pixelsPerSecond.dy / height;
    final flung = velocity < -1.4;
    final pulledDown = _sheet.value < 0.62 && velocity < 0.6;
    if (flung || pulledDown) {
      HapticFeedback.selectionClick();
      unawaited(_leave(widget.onLater, velocity: velocity));
    } else if (_reduced) {
      _sheet.animateTo(1, duration: AppMotion.card, curve: AppMotion.easeOut);
    } else {
      _sheet.animateWith(SpringSimulation(_rise, _sheet.value, 1, velocity));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) return const SizedBox.shrink();
    final s = context.getString;
    final feed = widget.offer.feed;
    final reduced = _reduced;
    final insets = MediaQuery.paddingOf(context);
    Animation<double> cue(Curve interval) =>
        CurvedAnimation(parent: _show, curve: interval);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _EmblemArrival(
          disc: cue(_Arrival.disc),
          fade: cue(_Arrival.discFade),
          reduced: reduced,
          child: BroadcastEmblem(key: _emblemKey, size: 84),
        ),
        const SizedBox(height: 14),
        _Rising(
          progress: cue(_Arrival.line(0)),
          reduced: reduced,
          child: _Eyebrow(text: s.update_eyebrow),
        ),
        const SizedBox(height: 6),
        _Rising(
          progress: cue(_Arrival.line(1)),
          reduced: reduced,
          child: _Title(
            text: s.update_title(feed.latestVersion.localized(context)),
          ),
        ),
        const SizedBox(height: 8),
        _Rising(
          progress: cue(_Arrival.line(2)),
          reduced: reduced,
          child: _Body(text: s.update_body),
        ),
        const SizedBox(height: 16),
        VersionHop(
          from: widget.offer.installedVersion,
          to: feed.latestVersion,
          arrival: cue(_Arrival.hop),
        ),
        const SizedBox(height: 16),
        ReleaseNotes(
          heading: s.update_whats_new,
          lines: feed.notesFor(_languageOf(context)),
          arrival: cue(_Arrival.notes),
        ),
      ],
    );

    // Pinned under the scrolling content, so on a short screen or with long
    // notes the way forward and the way out are never below the fold.
    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Landing(
          progress: cue(_Arrival.action),
          fade: cue(_Arrival.actionFade),
          reduced: reduced,
          child: SheenButton(
            key: const Key('update-action'),
            label: s.update_action,
            icon: Icons.system_update_alt_rounded,
            busy: busy,
            startAfter: _show,
            onTap: _update,
          ),
        ),
        _OpenFailed(visible: failed),
        FadeTransition(
          opacity: cue(_Arrival.later),
          child: TextButton(
            key: const Key('update-later'),
            onPressed: () => _leave(widget.onLater),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(
              s.update_later,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );

    final sheet = Stack(
      key: _sheetKey,
      clipBehavior: Clip.none,
      children: [
        Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          // Keeps the power-on pulse on the sheet: it washes across it, never
          // out over the app behind.
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            // Uniform on purpose, as on the troubleshooting sheet: a rounded
            // box can only be stroked with one colour.
            border: Border.all(color: AppColors.amber.withValues(alpha: 0.22)),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _PowerOnPainter(
                        progress: cue(_Arrival.pulse),
                        centre: _pulseCentre,
                        color: AppColors.amber,
                        reduced: reduced,
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Grabber(),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                      child: content,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 2 + insets.bottom),
                    child: actions,
                  ),
                ],
              ),
            ],
          ),
        ),
        // Below the docked edge, so the spring's overshoot and an upward tug
        // lift the sheet without opening a gap under it.
        Positioned(
          left: 0,
          right: 0,
          bottom: -120,
          height: 121,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.symmetric(
                vertical: BorderSide(
                  color: AppColors.amber.withValues(alpha: 0.22),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => _leave(widget.onLater),
              child: AnimatedBuilder(
                animation: _sheet,
                builder: (context, _) => ColoredBox(
                  color: Colors.black.withValues(
                    alpha: 0.6 * _sheet.value.clamp(0.0, 1.0),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: GestureDetector(
                key: const Key('update-sheet'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _dragStart,
                onVerticalDragUpdate: _dragUpdate,
                onVerticalDragEnd: _dragEnd,
                child: AnimatedBuilder(
                  animation: _sheet,
                  builder: (context, child) {
                    final v = _sheet.value;
                    if (reduced) {
                      // The arrival keeps its fade and loses its travel; a
                      // drag still moves it, since that is the finger's.
                      return Opacity(opacity: v.clamp(0.0, 1.0), child: child);
                    }
                    return FractionalTranslation(
                      translation: Offset(0, 1 - v),
                      child: child,
                    );
                  },
                  child: sheet,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 38,
      height: 4,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// Fades and lifts one piece of the sheet into place.
class _Rising extends StatelessWidget {
  const _Rising({
    required this.progress,
    required this.reduced,
    required this.child,
  });

  final Animation<double> progress;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: progress, child: child);
    if (reduced) return faded;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, AppMotion.rise * (1 - progress.value)),
        child: child,
      ),
      child: faded,
    );
  }
}

/// The transmitter switching on: the disc drops into place with a little
/// overshoot as its waves come up.
class _EmblemArrival extends StatelessWidget {
  const _EmblemArrival({
    required this.disc,
    required this.fade,
    required this.reduced,
    required this.child,
  });

  final Animation<double> disc;
  final Animation<double> fade;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: fade, child: child);
    if (reduced) return faded;
    return AnimatedBuilder(
      animation: disc,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, -10 * (1 - disc.value)),
        child: Transform.scale(scale: 0.5 + 0.5 * disc.value, child: child),
      ),
      child: faded,
    );
  }
}

/// The primary action landing: it rises, overshoots a little and settles,
/// so it arrives as the answer to everything above it.
class _Landing extends StatelessWidget {
  const _Landing({
    required this.progress,
    required this.fade,
    required this.reduced,
    required this.child,
  });

  final Animation<double> progress;
  final Animation<double> fade;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: fade, child: child);
    if (reduced) return faded;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final v = progress.value;
        return Transform.translate(
          offset: Offset(0, 18 * (1 - v)),
          child: Transform.scale(scale: 0.92 + 0.08 * v, child: child),
        );
      },
      child: faded,
    );
  }
}

/// The one pulse the transmitter sends when it powers on: two rings leaving
/// the disc and washing across the whole sheet, so the sheet itself reads
/// as having received the broadcast. Plays once; nothing here loops.
class _PowerOnPainter extends CustomPainter {
  _PowerOnPainter({
    required this.progress,
    required this.centre,
    required this.color,
    required this.reduced,
  }) : super(repaint: Listenable.merge([progress, centre]));

  final Animation<double> progress;
  final ValueListenable<Offset?> centre;
  final Color color;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final c = centre.value;
    if (reduced || c == null || t <= 0 || t >= 1) return;
    final far = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((corner) => (corner - c).distance).reduce(math.max);
    final paint = Paint()..style = PaintingStyle.stroke;
    for (var i = 0; i < 2; i++) {
      // The second ring trails the first, like an echo.
      final local = ((t - i * 0.18) / (1 - 0.18)).clamp(0.0, 1.0);
      if (local <= 0 || local >= 1) continue;
      final eased = AppMotion.easeOut.transform(local);
      final strength = (1 - local) * (i == 0 ? 0.55 : 0.3);
      paint
        ..strokeWidth = 2.4 - 1.6 * local
        ..color = color.withValues(alpha: strength);
      canvas.drawCircle(c, 24 + (far - 24) * eased, paint);
    }
  }

  @override
  bool shouldRepaint(_PowerOnPainter old) =>
      old.color != color || old.reduced != reduced;
}

// ── Required ────────────────────────────────────────────────────────────────

class _RequiredPrompt extends StatefulWidget {
  const _RequiredPrompt({required this.offer, required this.onCovered});

  final UpdateOffer offer;

  /// Called once the screen fully covers the app.
  final VoidCallback onCovered;

  @override
  State<_RequiredPrompt> createState() => _RequiredPromptState();
}

class _RequiredPromptState extends State<_RequiredPrompt>
    with TickerProviderStateMixin, _StoreAction {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );

  /// Where the emblem sits, so the radar and the reveal both centre on it
  /// whatever the screen height or the length of the notes.
  final _stackKey = GlobalKey();
  final _emblemKey = GlobalKey();
  final _focus = ValueNotifier<Offset?>(null);

  void _locateEmblem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final emblem =
          _emblemKey.currentContext?.findRenderObject() as RenderBox?;
      if (!mounted || stack == null || emblem == null) return;
      _focus.value = emblem.localToGlobal(
        emblem.size.center(Offset.zero),
        ancestor: stack,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _reveal.forward().whenComplete(() {
      if (!mounted) return;
      widget.onCovered();
      // Measured again now the entrance has settled: mid-stagger the emblem
      // is still a few pixels short of where it ends up.
      _locateEmblem();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sweep.loopUnlessReduced(context);
    // Rotation, resize or a text-scale change all move the emblem.
    _locateEmblem();
  }

  @override
  void dispose() {
    _reveal.dispose();
    _sweep.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final feed = widget.offer.feed;
    final reduced = AppMotion.reduced(context);
    final content = Material(
      color: AppColors.background,
      child: Stack(
        key: _stackKey,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _RadarPainter(
                  sweep: _sweep,
                  focus: _focus,
                  color: AppColors.amber,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            child: StaggeredEntrance(
                              builder: (context, children) => Column(
                                mainAxisSize: MainAxisSize.min,
                                children: children,
                              ),
                              children: [
                                BroadcastEmblem(
                                  key: _emblemKey,
                                  size: 124,
                                  icon: Icons.system_update_alt_rounded,
                                ),
                                const SizedBox(height: 28),
                                _OnAirTag(text: s.update_required_eyebrow),
                                const SizedBox(height: 12),
                                _Title(text: s.update_required_title, size: 26),
                                const SizedBox(height: 10),
                                _Body(
                                  text: s.update_required_body(
                                    feed.latestVersion.localized(context),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                VersionHop(
                                  from: widget.offer.installedVersion,
                                  to: feed.latestVersion,
                                ),
                                const SizedBox(height: 20),
                                ReleaseNotes(
                                  heading: s.update_whats_new,
                                  lines: feed.notesFor(_languageOf(context)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SheenButton(
                        key: const Key('update-action'),
                        label: s.update_action,
                        icon: Icons.system_update_alt_rounded,
                        busy: busy,
                        onTap: () => openStore(widget.offer),
                      ),
                      _OpenFailed(visible: failed),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (reduced) return FadeTransition(opacity: _reveal, child: content);
    // A circle opening out of the middle of the screen — the new version
    // arriving, rather than a page sliding over the old one.
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, child) => _reveal.isCompleted
          ? child!
          : ClipPath(
              clipper: _CircleReveal(
                AppMotion.easeInOut.transform(_reveal.value),
                _focus.value,
              ),
              child: child,
            ),
      child: content,
    );
  }
}

class _CircleReveal extends CustomClipper<Path> {
  _CircleReveal(this.t, this.focus);

  final double t;
  final Offset? focus;

  @override
  Path getClip(Size size) {
    final center = focus ?? _defaultFocus(size);
    // Far enough to reach the furthest corner from wherever it opens.
    final far = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((corner) => (corner - center).distance).reduce(math.max);
    return Path()..addOval(Rect.fromCircle(center: center, radius: far * t));
  }

  @override
  bool shouldReclip(_CircleReveal old) => old.t != t || old.focus != focus;
}

/// Until the emblem has been laid out once: roughly where it lands.
Offset _defaultFocus(Size size) => Offset(size.width / 2, size.height * 0.3);

/// A radar scope behind the required screen: faint range rings and one wedge
/// sweeping round, looking for a signal this version can no longer reach.
class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.sweep, required this.focus, required this.color})
    : super(repaint: Listenable.merge([sweep, focus]));

  final Animation<double> sweep;
  final ValueListenable<Offset?> focus;
  final Color color;

  Shader? _shader;
  Size? _shaderSize;

  @override
  void paint(Canvas canvas, Size size) {
    final center = focus.value ?? _defaultFocus(size);
    final radius = size.longestSide;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.07);
    for (var i = 1; i <= 5; i++) {
      canvas.drawCircle(center, size.shortestSide * 0.16 * i, ring);
    }

    // The gradient is built once per size; each frame only rotates the canvas.
    if (_shader == null || _shaderSize != size) {
      _shaderSize = size;
      _shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.11),
        ],
        stops: const [0, 0.82, 1],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius));
    }
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(sweep.value * 2 * math.pi);
    canvas.drawCircle(Offset.zero, radius, Paint()..shader = _shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.color != color;
}

/// "● UPDATE REQUIRED" — the red lamp of a studio's ON AIR sign, pulsing.
class _OnAirTag extends StatefulWidget {
  const _OnAirTag({required this.text});

  final String text;

  @override
  State<_OnAirTag> createState() => _OnAirTagState();
}

class _OnAirTagState extends State<_OnAirTag>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pulse.loopUnlessReduced(context, reverse: true, rest: 1);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final red = AppColors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: red.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: 0.25, end: 1).animate(_pulse),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: red, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.text,
            style: TextStyle(
              color: red,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared text ─────────────────────────────────────────────────────────────

class _Eyebrow extends StatelessWidget {
  const _Eyebrow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: AppColors.amber,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 2.2,
    ),
  );
}

class _Title extends StatelessWidget {
  const _Title({required this.text, this.size = 22});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: AppColors.textPrimary,
      fontSize: size,
      fontWeight: FontWeight.w800,
      height: 1.25,
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: AppColors.textSecondary,
      fontSize: 14,
      height: 1.55,
    ),
  );
}

class _OpenFailed extends StatelessWidget {
  const _OpenFailed({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: AppMotion.card,
    curve: AppMotion.easeOut,
    child: visible
        ? Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              context.getString.update_open_failed,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.red, fontSize: 12.5),
            ),
          )
        : const SizedBox(width: double.infinity),
  );
}

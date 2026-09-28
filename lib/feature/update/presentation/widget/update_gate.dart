import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    with SingleTickerProviderStateMixin, _StoreAction {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    reverseDuration: AppMotion.sheet,
  );
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // A beat after the home screen settles, so the prompt arrives on a page
    // rather than with it.
    // Built only then, too, so the content's staggered entrance plays while
    // the card rises instead of unseen before it.
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _started = true);
      _enter.forward();
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _leave(VoidCallback then) async {
    await _enter.reverse();
    then();
  }

  Future<void> _update() async {
    if (await openStore(widget.offer)) unawaited(_leave(widget.onOpened));
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) return const SizedBox.shrink();
    final s = context.getString;
    final feed = widget.offer.feed;
    final reduced = AppMotion.reduced(context);
    final slide = CurvedAnimation(
      parent: _enter,
      curve: AppMotion.drawer,
      reverseCurve: AppMotion.leaving,
    );
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => _leave(widget.onLater),
              child: FadeTransition(
                opacity: _enter,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.6)),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: AnimatedBuilder(
                  animation: slide,
                  builder: (context, child) => Opacity(
                    opacity: _enter.value.clamp(0, 1),
                    child: Transform.translate(
                      offset: Offset(0, reduced ? 0 : (1 - slide.value) * 120),
                      child: child,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _Card(
                      child: StaggeredEntrance(
                        builder: (context, children) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: children,
                        ),
                        children: [
                          const BroadcastEmblem(size: 84),
                          const SizedBox(height: 14),
                          _Eyebrow(text: s.update_eyebrow),
                          const SizedBox(height: 6),
                          _Title(
                            text: s.update_title(
                              feed.latestVersion.localized(context),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _Body(text: s.update_body),
                          const SizedBox(height: 16),
                          VersionHop(
                            from: widget.offer.installedVersion,
                            to: feed.latestVersion,
                          ),
                          const SizedBox(height: 16),
                          ReleaseNotes(
                            heading: s.update_whats_new,
                            lines: feed.notesFor(_languageOf(context)),
                          ),
                          const SizedBox(height: 18),
                          SheenButton(
                            key: const Key('update-action'),
                            label: s.update_action,
                            icon: Icons.system_update_alt_rounded,
                            busy: busy,
                            onTap: _update,
                          ),
                          _OpenFailed(visible: failed),
                          TextButton(
                            key: const Key('update-later'),
                            onPressed: () => _leave(widget.onLater),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.textSecondary,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: Text(
                              s.update_later,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.86,
    ),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.28)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 40,
          offset: const Offset(0, 14),
        ),
      ],
    ),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
      child: child,
    ),
  );
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

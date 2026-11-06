import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/logger.dart';
import '../../../update/presentation/widget/update_visuals.dart';
import '../../domain/entity/announcement.dart';
import 'announcement_gate.dart';
import 'announcement_visuals.dart';

/// Where each beat of one announcement's arrival sits on its controller.
///
/// The emblem tells its little story first (see [AnnouncementEmblem]); the
/// words come in under it while it is still moving, the ticket is stamped
/// once the box is open or the bulb is lit, and the button lands last.
abstract final class _Beat {
  static const duration = Duration(milliseconds: 1800);

  static Interval line(int i) {
    final start = 0.2 + 0.06 * i;
    return Interval(start, start + 0.3, curve: AppMotion.easeOut);
  }

  static const ticket = Interval(0.5, 1);
  static const action = Interval(0.6, 0.9, curve: Curves.easeOutBack);
  static const actionFade = Interval(0.6, 0.74);
  static const secondary = Interval(0.76, 1, curve: AppMotion.easeOut);
}

/// One to three announcements on a sheet over the home screen.
///
/// It rises on a spring and can be dragged: down to put it away, sideways to
/// leaf through the announcements, each of which plays its own entrance the
/// first time it comes up. The sheet's rim and the page dots take on the
/// colour of whichever announcement is up.
class AnnouncementSheet extends StatefulWidget {
  const AnnouncementSheet({
    required this.announcements,
    required this.onSeen,
    required this.onClosed,
    required this.navigate,
    super.key,
  });

  final List<Announcement> announcements;

  /// An announcement came up, so it counts as shown.
  final ValueChanged<Announcement> onSeen;

  /// The sheet has gone, however it was sent away.
  final VoidCallback onClosed;

  final AnnouncementNavigate navigate;

  @override
  State<AnnouncementSheet> createState() => _AnnouncementSheetState();
}

class _AnnouncementSheetState extends State<AnnouncementSheet>
    with TickerProviderStateMixin {
  /// 0 off the bottom edge, 1 docked; unbounded for the spring's overshoot
  /// and an upward tug — the same sheet physics as the update prompt.
  late final AnimationController _sheet = AnimationController.unbounded(
    vsync: this,
  );

  /// One entrance per announcement, started the first time it comes up.
  late final List<AnimationController> _arrivals = [
    for (final _ in widget.announcements)
      AnimationController(vsync: this, duration: _Beat.duration),
  ];

  /// The page turn: 0 → 1 carries [_from] out and [_index] in.
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  /// The current page's sideways drag, in sheet-widths toward "next" (so it
  /// reads the same in Persian, where next is to the left).
  final _drag = ValueNotifier<double>(0);

  static final _rise = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 260,
    ratio: 0.8,
  );
  static final _fall = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 640,
    ratio: 1,
  );
  static const _gone = Tolerance(distance: 0.004, velocity: 0.05);

  final _sheetKey = GlobalKey();
  late final List<GlobalKey> _emblemKeys = [
    for (final _ in widget.announcements) GlobalKey(),
  ];

  /// The secondary button's last words, kept while it fades out.
  String? _lastSecondary;
  final _centre = ValueNotifier<Offset?>(null);

  int _index = 0;
  int? _from;

  /// +1 when the turn goes to the next page, -1 back.
  int _direction = 1;
  bool _started = false;
  bool _leaving = false;
  bool _openFailed = false;

  /// Set at the first page turn. From then on the buttons are already on
  /// the sheet: they hand over in place instead of waiting out the next
  /// page's whole entrance, which would leave the sheet with no way forward
  /// for a second.
  bool _turned = false;
  double _dragRaw = 1;

  List<Announcement> get _all => widget.announcements;
  Announcement get _current => _all[_index];
  bool get _hasNext => _index < _all.length - 1;
  bool get _reduced => AppMotion.reduced(context);

  @override
  void initState() {
    super.initState();
    // A beat after the home screen settles, as the update prompt does.
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _started = true);
      _open();
      // The emblem's story starts once the sheet is most of the way up, so
      // its first beat (the drop, the spark) is seen rather than spent
      // below the edge.
      if (_reduced) {
        _arrive(0);
      } else {
        Future<void>.delayed(const Duration(milliseconds: 160), () {
          if (mounted) _arrive(0);
        });
      }
    });
  }

  @override
  void dispose() {
    _sheet.dispose();
    for (final c in _arrivals) {
      c.dispose();
    }
    _turn.dispose();
    _drag.dispose();
    _centre.dispose();
    super.dispose();
  }

  void _arrive(int i) {
    widget.onSeen(_all[i]);
    if (_arrivals[i].isDismissed) _arrivals[i].forward();
    _locateEmblem();
  }

  void _open() {
    if (_reduced) {
      _sheet.animateTo(1, duration: AppMotion.sheet, curve: AppMotion.easeOut);
    } else {
      _sheet.animateWith(SpringSimulation(_rise, _sheet.value, 1, 0));
    }
  }

  /// Where the emblem sits inside the sheet, for the backdrop effects that
  /// come out of it. Measured, not assumed, so text scale cannot move it.
  void _locateEmblem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sheet = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
      final emblem =
          _emblemKeys[_index].currentContext?.findRenderObject() as RenderBox?;
      if (!mounted || sheet == null || emblem == null || !emblem.attached) {
        return;
      }
      _centre.value = emblem.localToGlobal(
        emblem.size.center(Offset.zero),
        ancestor: sheet,
      );
    });
  }

  Future<void> _leave({double velocity = 0, VoidCallback? then}) async {
    if (_leaving) return;
    _leaving = true;
    if (_reduced) {
      await _sheet.animateTo(
        0,
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
      );
    } else {
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
    if (!mounted) return;
    widget.onClosed();
    then?.call();
  }

  // ── Turning pages ──

  void _go(int to, {double from = 0}) {
    if (to < 0 || to >= _all.length || to == _index) {
      _settleDrag();
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _direction = to > _index ? 1 : -1;
      _from = _index;
      _index = to;
      _turned = true;
      _openFailed = false;
    });
    _drag.value = 0;
    _arrive(to);
    if (_reduced) {
      _turn.value = 1;
      setState(() => _from = null);
      return;
    }
    _turn
      ..value = from.clamp(0.0, 0.95)
      ..animateTo(1, curve: AppMotion.easeOut).whenCompleteOrCancel(() {
        if (mounted) setState(() => _from = null);
      });
  }

  void _settleDrag() {
    final start = _drag.value;
    if (start == 0) return;
    final ctrl = AnimationController(vsync: this, duration: AppMotion.card);
    final curve = CurvedAnimation(parent: ctrl, curve: AppMotion.easeOut);
    ctrl.addListener(() => _drag.value = start * (1 - curve.value));
    ctrl.forward().whenCompleteOrCancel(ctrl.dispose);
  }

  double get _width =>
      (_sheetKey.currentContext?.findRenderObject() as RenderBox?)
          ?.size
          .width ??
      0;

  double get _forward => AppMotion.forwardSign(Directionality.of(context));

  void _pageDragUpdate(DragUpdateDetails details) {
    final width = _width;
    if (_leaving || width <= 0 || _all.length < 2) return;
    // Screen-space "toward next" is leftward in English, rightward in Persian.
    var next = _drag.value - details.primaryDelta! * _forward / width;
    // Past either end the page gives way less and less: there is nothing
    // there, and the resistance says so.
    final atEnd = (next > 0 && !_hasNext) || (next < 0 && _index == 0);
    if (atEnd) next = 0.18 * next / (next.abs() + 0.18);
    _drag.value = next.clamp(-1.0, 1.0);
  }

  void _pageDragEnd(DragEndDetails details) {
    final width = _width;
    if (_leaving || width <= 0 || _all.length < 2) return;
    final velocity = -details.velocity.pixelsPerSecond.dx * _forward / width;
    final d = _drag.value;
    if ((d > 0.22 || velocity > 1.2) && _hasNext && velocity > -0.6) {
      _go(_index + 1, from: d.abs());
    } else if ((d < -0.22 || velocity < -1.2) && _index > 0 && velocity < 0.6) {
      _go(_index - 1, from: d.abs());
    } else {
      _settleDrag();
    }
  }

  // ── Sheet drag ──

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
    final over = _dragRaw - 1;
    _sheet.value = over <= 0 ? _dragRaw : 1 + 0.1 * over / (over + 0.1);
  }

  void _dragEnd(DragEndDetails details) {
    final height = _sheetHeight;
    if (_leaving || height <= 0) return;
    final velocity = -details.velocity.pixelsPerSecond.dy / height;
    final flung = velocity < -1.4;
    final pulledDown = _sheet.value < 0.62 && velocity < 0.6;
    if (flung || pulledDown) {
      HapticFeedback.selectionClick();
      unawaited(_leave(velocity: velocity));
    } else if (_reduced) {
      _sheet.animateTo(1, duration: AppMotion.card, curve: AppMotion.easeOut);
    } else {
      _sheet.animateWith(SpringSimulation(_rise, _sheet.value, 1, velocity));
    }
  }

  // ── Actions ──

  Future<void> _act(AnnouncementAction action) async {
    HapticFeedback.lightImpact();
    switch (action.type) {
      case AnnouncementActionType.signIn:
        unawaited(_leave(then: () => widget.navigate(AppRoutes.signInName)));
      case AnnouncementActionType.screen:
        final name = AnnouncementGate.screens[action.screen];
        unawaited(
          _leave(then: name == null ? null : () => widget.navigate(name)),
        );
      case AnnouncementActionType.link:
        var opened = false;
        try {
          opened = await launchUrl(
            action.url!,
            mode: LaunchMode.externalApplication,
          );
        } catch (e) {
          Logger.log('Announcements: link did not open — $e');
        }
        if (!mounted) return;
        if (opened) {
          unawaited(_leave());
        } else {
          setState(() => _openFailed = true);
        }
    }
  }

  String _actionLabel(BuildContext context, AnnouncementAction action) {
    final lang = Localizations.localeOf(context).languageCode;
    final own = action.label.of(lang);
    if (own.isNotEmpty) return own.localized(context);
    final s = context.getString;
    return switch (action.type) {
      AnnouncementActionType.signIn => s.announcement_sign_in,
      AnnouncementActionType.link => s.announcement_open_link,
      AnnouncementActionType.screen => s.announcement_open_screen,
    };
  }

  static IconData _actionIcon(AnnouncementAction action) =>
      switch (action.type) {
        AnnouncementActionType.signIn => Icons.person_add_alt_1_rounded,
        AnnouncementActionType.link => Icons.open_in_new_rounded,
        AnnouncementActionType.screen => Icons.arrow_forward_rounded,
      };

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    if (!_started) return const SizedBox.shrink();
    final insets = MediaQuery.paddingOf(context);
    final style = AnnouncementStyle.of(_current.category);

    // Every page is always laid out, the ones not showing kept invisible,
    // so the sheet is as tall as its tallest page from the start and never
    // changes height as the pages turn. Each one is full width, so a page
    // never re-wraps its text when the next one is narrower.
    final pages = AnimatedBuilder(
      animation: Listenable.merge([_turn, _drag]),
      builder: (context, _) {
        final from = _from;
        final t = _turn.value;
        final sign = _forward;
        return Stack(
          alignment: Alignment.topCenter,
          children: [
            for (var i = 0; i < _all.length; i++)
              if (i == _index)
                _PageSlot(
                  key: ValueKey('page-$i'),
                  announcement: _all[i],
                  arrival: _arrivals[i],
                  emblemKey: _emblemKeys[i],
                  offset: from != null
                      ? _direction * 0.6 * (1 - t) * sign
                      : -_drag.value * sign,
                  opacity: from != null
                      ? Curves.easeIn.transform(t)
                      : 1 - 0.45 * _drag.value.abs(),
                  scale: 1,
                  role: _SlotRole.current,
                )
              else if (i == from)
                // Leaving: on toward where it was going, fading and receding.
                _PageSlot(
                  key: ValueKey('page-$i'),
                  announcement: _all[i],
                  arrival: _arrivals[i],
                  emblemKey: _emblemKeys[i],
                  offset: -_direction * 0.6 * t * sign,
                  opacity: 1 - Curves.easeOut.transform(t),
                  scale: 1 - 0.06 * t,
                  role: _SlotRole.leaving,
                )
              else
                _PageSlot(
                  key: ValueKey('page-$i'),
                  announcement: _all[i],
                  arrival: _arrivals[i],
                  emblemKey: _emblemKeys[i],
                  offset: 0,
                  opacity: 0,
                  scale: 1,
                  role: _SlotRole.hidden,
                ),
          ],
        );
      },
    );

    final arrival = _arrivals[_index];
    Animation<double> cue(Curve interval) =>
        CurvedAnimation(parent: arrival, curve: interval);
    final s = context.getString;
    final action = _current.action;
    final hasNext = _hasNext;
    final primaryLabel = action != null
        ? _actionLabel(context, action)
        : (hasNext ? s.announcement_next : s.announcement_got_it);
    final primaryIcon = action != null
        ? _actionIcon(action)
        : (hasNext ? Icons.arrow_forward_rounded : Icons.check_rounded);
    final secondaryLabel = action != null
        ? (hasNext ? s.announcement_next : s.announcement_later)
        : (hasNext ? s.announcement_close : null);
    void primary() {
      if (action != null) {
        unawaited(_act(action));
      } else if (hasNext) {
        _go(_index + 1);
      } else {
        HapticFeedback.lightImpact();
        unawaited(_leave());
      }
    }

    void secondary() {
      if (action != null && hasNext) {
        _go(_index + 1);
      } else {
        unawaited(_leave());
      }
    }

    // One set of buttons for the whole deck. A page turn recolours the
    // button and hands its words over in place; it never swaps in a second
    // button, and the row under it keeps its height whether or not this page
    // has a second choice, so nothing below the pages moves.
    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Landing(
          progress: _turned ? kAlwaysCompleteAnimation : cue(_Beat.action),
          fade: _turned ? kAlwaysCompleteAnimation : cue(_Beat.actionFade),
          reduced: _reduced,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: style.accent),
            duration: AppMotion.sheet,
            curve: AppMotion.easeOut,
            builder: (context, fill, _) => TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: style.onAccent),
              duration: AppMotion.sheet,
              curve: AppMotion.easeOut,
              builder: (context, ink, _) => SheenButton(
                key: const Key('announcement-action'),
                label: primaryLabel,
                icon: primaryIcon,
                color: fill,
                onColor: ink,
                startAfter: _turned ? null : arrival,
                onTap: primary,
              ),
            ),
          ),
        ),
        _OpenFailed(visible: _openFailed),
        FadeTransition(
          opacity: _turned ? kAlwaysCompleteAnimation : cue(_Beat.secondary),
          child: AnimatedOpacity(
            duration: AppMotion.card,
            curve: AppMotion.easeOut,
            opacity: secondaryLabel == null ? 0 : 1,
            child: IgnorePointer(
              ignoring: secondaryLabel == null,
              child: ExcludeSemantics(
                excluding: secondaryLabel == null,
                child: TextButton(
                  key: secondaryLabel == null
                      ? null
                      : const Key('announcement-secondary'),
                  onPressed: secondary,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    switchInCurve: const Interval(
                      0.45,
                      1,
                      curve: AppMotion.easeOut,
                    ),
                    switchOutCurve: const Interval(
                      0.45,
                      1,
                      curve: AppMotion.easeOut,
                    ),
                    child: Text(
                      // Holds its place with the last words it had, so the
                      // row keeps its height while it fades.
                      secondaryLabel ?? _lastSecondary ?? s.announcement_close,
                      key: ValueKey(secondaryLabel ?? _lastSecondary),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    if (secondaryLabel != null) _lastSecondary = secondaryLabel;

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Grabber(),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: _all.length > 1 ? _pageDragUpdate : null,
              onHorizontalDragEnd: _all.length > 1 ? _pageDragEnd : null,
              child: pages,
            ),
          ),
        ),
        if (_all.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _PageDots(
              count: _all.length,
              index: _index,
              colors: [
                for (final a in _all) AnnouncementStyle.of(a.category).accent,
              ],
              onTap: _go,
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 2 + insets.bottom),
          child: actions,
        ),
      ],
    );

    final sheet = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: style.accent),
      duration: AppMotion.sheet,
      curve: AppMotion.easeOut,
      builder: (context, rim, child) => Stack(
        key: _sheetKey,
        clipBehavior: Clip.none,
        children: [
          Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.88,
            ),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(26),
              ),
              border: Border.all(
                color: (rim ?? style.accent).withValues(alpha: 0.26),
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: AppMotion.sheet,
                    child: AnnouncementBackdrop(
                      key: ValueKey('backdrop-$_index'),
                      category: _current.category,
                      arrival: arrival,
                      centre: _centre,
                    ),
                  ),
                ),
                child!,
              ],
            ),
          ),
          // Under the docked edge, so overshoot never opens a gap.
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
                    color: (rim ?? style.accent).withValues(alpha: 0.26),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      child: body,
    );

    final reduced = _reduced;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const Key('announcement-scrim'),
              onTap: () => _leave(),
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
                key: const Key('announcement-sheet'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _dragStart,
                onVerticalDragUpdate: _dragUpdate,
                onVerticalDragEnd: _dragEnd,
                child: AnimatedBuilder(
                  animation: _sheet,
                  builder: (context, child) {
                    final v = _sheet.value;
                    if (reduced) {
                      return Opacity(opacity: v.clamp(0.0, 1.0), child: child);
                    }
                    return FractionalTranslation(
                      translation: Offset(0, 1 - v),
                      child: child,
                    );
                  },
                  child: Semantics(
                    scopesRoute: true,
                    namesRoute: true,
                    explicitChildNodes: true,
                    label: _all.length > 1
                        ? s.announcement_position(
                            (_index + 1).localized(context),
                            _all.length.localized(context),
                          )
                        : null,
                    child: sheet,
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

/// One announcement on the sheet, wherever the page turn has it.
///
/// [offset] is in widths, in screen space. The emblem travels further than
/// the words, so a turn has depth: the mark is nearer, and moves faster.
enum _SlotRole { current, leaving, hidden }

class _PageSlot extends StatelessWidget {
  const _PageSlot({
    required this.announcement,
    required this.arrival,
    required this.offset,
    required this.opacity,
    required this.scale,
    required this.role,
    required this.emblemKey,
    super.key,
  });

  final Announcement announcement;
  final AnimationController arrival;
  final double offset;
  final double opacity;
  final double scale;
  final _SlotRole role;
  final Key emblemKey;

  @override
  Widget build(BuildContext context) {
    Widget slot = SizedBox(
      width: double.infinity,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: FractionalTranslation(
          translation: Offset(offset, 0),
          child: Transform.scale(
            scale: scale,
            child: _AnnouncementPage(
              announcement: announcement,
              arrival: arrival,
              emblemKey: emblemKey,
              emblemShift: offset * 0.45,
            ),
          ),
        ),
      ),
    );
    if (role != _SlotRole.current) {
      // Taking up its room, but not tapped, not read out, and — when it is
      // not even leaving — not ticking either.
      slot = IgnorePointer(child: ExcludeSemantics(child: slot));
    }
    if (role == _SlotRole.hidden) {
      slot = TickerMode(enabled: false, child: slot);
    }
    return slot;
  }
}

class _AnnouncementPage extends StatelessWidget {
  const _AnnouncementPage({
    required this.announcement,
    required this.arrival,
    required this.emblemShift,
    required this.emblemKey,
  });

  final Announcement announcement;
  final AnimationController arrival;

  /// Extra sideways travel for the emblem, in widths.
  final double emblemShift;
  final Key emblemKey;

  String _tag(BuildContext context) {
    final s = context.getString;
    return switch (announcement.category) {
      AnnouncementCategory.gift => s.announcement_tag_gift,
      AnnouncementCategory.feature => s.announcement_tag_feature,
      AnnouncementCategory.news => s.announcement_tag_news,
      AnnouncementCategory.tip => s.announcement_tag_tip,
      AnnouncementCategory.event => s.announcement_tag_event,
      AnnouncementCategory.alert => s.announcement_tag_alert,
    };
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final lang = Localizations.localeOf(context).languageCode;
    final style = AnnouncementStyle.of(announcement.category);
    Animation<double> cue(Curve interval) =>
        CurvedAnimation(parent: arrival, curve: interval);
    final highlight = announcement.highlight.of(lang);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FractionalTranslation(
          translation: Offset(emblemShift, 0),
          child: AnnouncementEmblem(
            key: emblemKey,
            category: announcement.category,
            arrival: arrival,
            size: 112,
          ),
        ),
        const SizedBox(height: 12),
        _Rising(
          progress: cue(_Beat.line(0)),
          reduced: reduced,
          child: _Tag(text: _tag(context), color: style.accent),
        ),
        const SizedBox(height: 10),
        _Rising(
          progress: cue(_Beat.line(1)),
          reduced: reduced,
          child: Semantics(
            header: true,
            liveRegion: true,
            child: Text(
              announcement.title.of(lang).localized(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _Rising(
          progress: cue(_Beat.line(2)),
          reduced: reduced,
          child: Text(
            announcement.body.of(lang).localized(context),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.55,
            ),
          ),
        ),
        if (highlight.isNotEmpty) ...[
          const SizedBox(height: 18),
          HighlightTicket(
            key: const Key('announcement-highlight'),
            text: highlight.localized(context),
            accent: style.accent,
            arrival: cue(_Beat.ticket),
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }
}

/// The category, as a lit tag: a small lamp and the name in capitals.
class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: 7),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
      ],
    ),
  );
}

/// Where you are among the announcements: the current one a pill in its own
/// colour, which stretches and slides as the pages turn.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.index,
    required this.colors,
    required this.onTap,
  });

  final int count;
  final int index;
  final List<Color> colors;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: AnimatedContainer(
                duration: AppMotion.sheet,
                curve: Curves.easeOutBack,
                width: i == index ? 22 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == index
                      ? colors[i]
                      : AppColors.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
      ],
    ),
  );
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
              context.getString.announcement_open_failed,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.red, fontSize: 12.5),
            ),
          )
        : const SizedBox(width: double.infinity),
  );
}

/// For tests and previews: the sheet's motion is easier to judge frozen.
@visibleForTesting
const announcementBeatDuration = _Beat.duration;

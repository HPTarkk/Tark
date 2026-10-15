import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// The way a deleted Room leaves a list: it turns to dust.
///
/// Fading a deleted row out says "hidden". Deleting a Room is final — its
/// keys and its seats are gone from this phone — so the row should visibly
/// stop existing. The idea is Telegram's message deletion, in Tarkk's own
/// materials: the card is photographed once, and the photograph breaks into
/// a thousand-odd specks that peel off in a sweep from the side the menu was
/// on, lift away like embers, warm to the app's amber as they go and burn
/// out. A beat after the sweep starts, the empty slot springs shut and the
/// Rooms below are pulled up into it like links of a chain.
///
/// ## The reflow
///
/// A list that closes a gap by re-laying itself out moves every row below
/// in lockstep, as one rigid slab — and when the rows below are built from
/// a fresh list the moment the data changes, they jump. Neither reads as the
/// rows being *pulled*. Here the slot closes on a critically damped spring,
/// and each row under it follows that same spring a fixed beat later than
/// the row above ([_Leaving.linkDelay]): the first row rides the closing
/// slot, the next trails it slightly, and so on down, so the gap travels
/// down the list the way slack runs out of a chain. Every row moves
/// monotonically up and arrives at rest, never overshooting past its place.
/// The lag is a paint-time translation over each row's laid-out position
/// (one `Transform` per row, driven by a single notifier), so nothing is
/// re-laid-out or re-rasterised per frame beyond the closing slot itself.
/// Rows are matched by id ([RoomDissolvable.id]), not by position, so the
/// list re-emitting from its cubit mid-animation changes nothing on screen.
///
/// ## How it fits around a list
///
/// [RoomDissolveHost] wraps the screen or sheet holding the list; each row is
/// a [RoomDissolvable] keyed by its Room id; anything under the rows that
/// should be pulled along with them (a "new Room" card) is a
/// [RoomDissolveFollower]; and the list is built from
/// [RoomDissolveHostState.retain], which keeps a just-deleted row in its old
/// place (invisible, collapsing) after the data no longer has it. That last
/// part is what keeps this presentation-only: the delete itself runs exactly
/// as before, at the moment it always did, and the list's data is never held
/// back — only the row's empty slot is, until the rows below have settled.
///
/// A screen that swaps the list for an empty state asks
/// [RoomDissolveHostState.isSettling] first, so the last Room's dust plays
/// out in the list it belonged to and the empty state arrives out of it
/// instead of cutting in over it.
///
/// ## Cost
///
/// The card is rasterised once (`toImageSync`, capped at 2x) and every speck
/// is a sprite of that one image, so the whole cloud is a single
/// `drawRawAtlas` call per frame with per-sprite colour for the fade and
/// tint. The speck count is capped for the Galaxy S8+, the dust lives in its
/// own overlay layer, and the overlay entry removes itself and frees the
/// image when the last speck is out.
///
/// Reduced motion keeps the meaning and drops the spectacle: no dust, no
/// chain, the row fades as its slot closes over a card-length beat.
class RoomDissolveHost extends StatefulWidget {
  const RoomDissolveHost({required this.child, super.key});

  final Widget child;

  /// The host above [context], registering [context] to rebuild when a row
  /// starts or finishes leaving. For use while building.
  static RoomDissolveHostState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DissolveScope>()?.state;

  /// The host above [context] without listening to it — for event handlers.
  static RoomDissolveHostState? maybeOf(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<_DissolveScope>()?.widget
              as _DissolveScope?)
          ?.state;

  @override
  State<RoomDissolveHost> createState() => RoomDissolveHostState();
}

class RoomDissolveHostState extends State<RoomDissolveHost>
    with TickerProviderStateMixin {
  final _keys = <Object, GlobalKey>{};

  /// The space each row leaves under itself, as it last built.
  final _gaps = <Object, double>{};

  /// What the list looked like when it was last built: each id's item and
  /// position, so a row can be kept in its place after its data is gone.
  final _lastSeen = <Object, ({Object? item, int index})>{};

  final _leaving = <Object, _Leaving>{};
  int _version = 0;

  /// Ticks once per frame while any slot is closing; every row's chain lag
  /// listens to this one notifier.
  final _frame = _FrameNotifier();

  final _settled = <Completer<void>>[];

  /// Rows that have finished leaving. An outgoing copy of the list (a
  /// switcher fading it out for an empty state) can still build them; they
  /// stay gone rather than reappearing for the length of the fade.
  final _gone = <Object>{};

  /// The boundary key a [RoomDissolvable] with [id] paints into.
  GlobalKey _keyFor(Object id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// Whether [id] is on its way out.
  bool isLeaving(Object id) => _leaving.containsKey(id);

  /// Whether any row is still leaving — its dust in the air or the rows below
  /// it still rising. A screen about to swap an emptied list for something
  /// else waits for this to clear; the host rebuilds its dependents when it
  /// does.
  ///
  /// It clears a little before the last row is fully at rest — once every
  /// row has covered nearly all of its way — so what replaces the list can
  /// start arriving while the dust is still in the air.
  bool get isSettling => _leaving.values.any((leaving) => !leaving.landed);

  /// Completes once no row is leaving (at once, if none is).
  Future<void> settled() {
    if (_leaving.isEmpty) return Future<void>.value();
    final completer = Completer<void>();
    _settled.add(completer);
    return completer.future;
  }

  /// [items] with any row that is still leaving put back where it was.
  ///
  /// Call it with the list exactly as the data has it, every build.
  List<T> retain<T>(List<T> items, Object Function(T item) idOf) {
    final result = List<T>.of(items);
    final present = {for (final item in items) idOf(item)};
    _gone.removeAll(present);
    if (_leaving.isNotEmpty) {
      final ghosts =
          _leaving.entries
              .where((e) => !present.contains(e.key) && e.value.item is T)
              .toList()
            ..sort((a, b) => a.value.index.compareTo(b.value.index));
      for (final ghost in ghosts) {
        result.insert(
          math.min(ghost.value.index, result.length),
          ghost.value.item as T,
        );
      }
    }
    _lastSeen
      ..clear()
      ..addAll({
        for (var i = 0; i < result.length; i++)
          idOf(result[i]): (item: result[i], index: i),
      });
    return result;
  }

  /// How far below its laid-out place the row at [index] is drawn right now:
  /// the sum of how far it trails every slot closing above it.
  double _lagAt(int index) {
    if (_leaving.isEmpty) return 0;
    var lag = 0.0;
    for (final leaving in _leaving.values) {
      if (index > leaving.index) lag += leaving.lagFor(index - leaving.index);
    }
    return lag;
  }

  double _lagOf(Object id) {
    final seen = _lastSeen[id];
    return seen == null ? 0 : _lagAt(seen.index);
  }

  /// Followers sit under every row.
  double _trailingLag() => _lagAt(_lastSeen.length);

  /// Turns the row for [id] to dust and closes its slot.
  ///
  /// Synchronous on purpose: the row is photographed in this call, before
  /// whatever the caller does next (the delete) can take it off screen.
  void dissolve(Object id) {
    if (_leaving.containsKey(id) || !mounted) return;
    final seen = _lastSeen[id];
    final reduced = AppMotion.reduced(context);
    final boundary = _keys[id]?.currentContext?.findRenderObject();
    final height = boundary is RenderBox && boundary.hasSize
        ? boundary.size.height
        : 0.0;
    final leaving = _Leaving(
      item: seen?.item,
      index: seen?.index ?? 0,
      slot: height + (_gaps[id] ?? 0),
      followers: _lastSeen.length - (seen?.index ?? 0),
      reduced: reduced,
      vsync: this,
      onFrame: _frame.tick,
      onLanded: () {
        if (mounted) setState(() => _version++);
      },
    );
    if (!reduced) _launchDust(id);
    HapticFeedback.lightImpact();
    setState(() {
      _leaving[id] = leaving;
      _version++;
    });
    leaving.run().whenComplete(() {
      if (!mounted) return;
      setState(() {
        _leaving.remove(id)?.dispose();
        _gone.add(id);
        _keys.remove(id);
        _gaps.remove(id);
        _version++;
      });
      _frame.tick();
      if (_leaving.isEmpty) {
        for (final completer in _settled) {
          completer.complete();
        }
        _settled.clear();
      }
    });
  }

  void _launchDust(Object id) {
    final boundaryContext = _keys[id]?.currentContext;
    final boundary = boundaryContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context);
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        !boundary.hasSize ||
        boundary.size.isEmpty ||
        overlay == null) {
      return;
    }
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) return;
    final pixelRatio = math.min(
      2.0,
      MediaQuery.devicePixelRatioOf(boundaryContext!),
    );
    final ui.Image image;
    try {
      image = boundary.toImageSync(pixelRatio: pixelRatio);
    } catch (_) {
      // No photograph, no dust: the slot still closes.
      return;
    }
    final origin = boundary.localToGlobal(Offset.zero, ancestor: overlayBox);
    final rtl = Directionality.maybeOf(boundaryContext) == TextDirection.rtl;
    late final OverlayEntry entry;
    var finished = false;
    entry = OverlayEntry(
      builder: (_) => _Dust(
        image: image,
        pixelRatio: pixelRatio,
        rect: origin & boundary.size,
        // The menu sits on the trailing edge: the sweep starts there and the
        // dust is carried that way.
        fromRight: !rtl,
        tint: AppColors.amber,
        onDone: () {
          if (finished) return;
          finished = true;
          // Also when the overlay itself is already gone (the screen was
          // left mid-dissolve): remove() copes, and dispose() requires it.
          entry.remove();
          entry.dispose();
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  void dispose() {
    for (final leaving in _leaving.values) {
      leaving.dispose();
    }
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _DissolveScope(state: this, version: _version, child: widget.child);
}

class _DissolveScope extends InheritedWidget {
  const _DissolveScope({
    required this.state,
    required this.version,
    required super.child,
  });

  final RoomDissolveHostState state;
  final int version;

  @override
  bool updateShouldNotify(_DissolveScope old) => old.version != version;
}

class _FrameNotifier extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// One row on its way out, and the clock its slot and the rows below it run
/// on. Notifies once per frame while it moves.
class _Leaving extends ChangeNotifier {
  _Leaving({
    required this.item,
    required this.index,
    required this.slot,
    required this.followers,
    required this.reduced,
    required TickerProvider vsync,
    required VoidCallback onFrame,
    required VoidCallback onLanded,
  }) : _onFrame = onFrame,
       _onLanded = onLanded {
    _ticker = vsync.createTicker(_tick);
  }

  final Object? item;
  final int index;

  /// Height of the slot being closed, the row's own gap included.
  final double slot;

  /// How many rows (and followers) sit under the slot — the chain's length,
  /// which decides when the last of it is at rest.
  final int followers;
  final bool reduced;
  final VoidCallback _onFrame;
  final VoidCallback _onLanded;

  /// Whether every row has covered nearly all of its way: the moment
  /// whatever replaces an emptied list may start to arrive.
  bool landed = false;
  late final Ticker _ticker;
  final _done = Completer<void>();

  /// Seconds since the row was dissolved.
  double _t = 0;

  /// How far the slot has closed: 0 open → 1 shut.
  double collapse = 0;

  /// The beat the dust gets before the slot starts closing: long enough to
  /// read the card breaking up in place, short enough that the list never
  /// looks like it is waiting.
  static const holdFor = Duration(milliseconds: 200);

  /// How much later each row follows the one above it. Long enough for the
  /// eye to see the rows arrive one after another, short enough that they
  /// still read as one connected movement rather than a queue.
  static const linkDelay = Duration(milliseconds: 34);

  /// Past this many rows the lag stops growing: the rest of the list, mostly
  /// off screen, moves with the last link instead of waiting its turn.
  static const maxLinks = 6;

  /// The slot's spring, and every link's: critically damped, so it
  /// decelerates into place the way something with mass would, with no
  /// bounce to read as a glitch in a list — and so every row rises
  /// monotonically.
  static final _spring = SpringSimulation(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 240, ratio: 1),
    0,
    1,
    0,
    tolerance: const Tolerance(distance: 0.002, velocity: 0.02),
  );

  /// Share of its way the last row has covered when the chain counts as
  /// landed: the remaining few pixels are a deceleration nobody waits for.
  static const _landedAt = 0.96;

  static double get _hold => holdFor.inMicroseconds / 1e6;
  static double get _link => linkDelay.inMicroseconds / 1e6;

  /// Progress of a spring that started [t] seconds ago (0 before it starts).
  static double _progress(double t) {
    if (t <= 0) return 0;
    if (_spring.isDone(t)) return 1;
    return _spring.x(t).clamp(0.0, 1.0);
  }

  /// Seconds from the dissolve until the [links]th row below starts moving.
  static double _start(int links) =>
      _hold + _link * (math.min(links, maxLinks) - 1).clamp(0, maxLinks);

  /// How far below its laid-out place a row [links] rows under this slot is
  /// drawn: it trails the closing slot by its place in the chain.
  double lagFor(int links) {
    if (reduced || links <= 0 || slot <= 0) return 0;
    return slot * (collapse - _progress(_t - _start(links)));
  }

  /// Starts the clock. Completes once the slot is shut and every row it pulls
  /// has come to rest; never, if disposed first.
  Future<void> run() {
    _ticker.start();
    return _done.future;
  }

  void _tick(Duration elapsed) {
    _t = elapsed.inMicroseconds / 1e6;
    final bool finished;
    if (reduced) {
      final span = AppMotion.card.inMicroseconds / 1e6;
      final p = (_t / span).clamp(0.0, 1.0);
      collapse = AppMotion.easeOut.transform(p);
      finished = p >= 1;
    } else {
      collapse = _progress(_t - _hold);
      // The last link to move is the one that decides when this is over.
      final last = _t - _start(math.max(followers, 1));
      finished = _spring.isDone(last);
      if (finished) collapse = 1;
      if (!landed && _progress(last) >= _landedAt) {
        landed = true;
        _onLanded();
      }
    }
    notifyListeners();
    _onFrame();
    if (finished && !landed) {
      landed = true;
      _onLanded();
    }
    if (finished) {
      _ticker.stop();
      if (!_done.isCompleted) _done.complete();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// A row that can be turned to dust. Give it the Room's id.
///
/// [gap] is the space under the row, owned by the row so that it closes with
/// it — a list separator outside the row would be left behind as a hole.
class RoomDissolvable extends StatelessWidget {
  const RoomDissolvable({
    required this.id,
    required this.child,
    this.gap = 0,
    super.key,
  });

  final Object id;
  final Widget child;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final host = RoomDissolveHost.of(context);
    // Already gone: only an outgoing copy of the list still builds it.
    if (host != null && host._gone.contains(id)) return const SizedBox.shrink();
    host?._gaps[id] = gap;
    final photographed = RepaintBoundary(key: host?._keyFor(id), child: child);
    final leaving = host?._leaving[id];
    if (leaving == null) {
      final row = Padding(
        padding: EdgeInsets.only(bottom: gap),
        child: photographed,
      );
      if (host == null) return row;
      return _ChainLink(lag: () => host._lagOf(id), host: host, child: row);
    }
    final reduced = leaving.reduced;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: leaving,
        child: Padding(
          padding: EdgeInsets.only(bottom: gap),
          // The dust overlay is the row now; the row itself is only the space
          // it leaves. Under reduced motion it fades in place instead.
          child: reduced
              ? photographed
              : Opacity(opacity: 0, child: photographed),
        ),
        builder: (context, child) {
          final shut = leaving.collapse.clamp(0.0, 1.0);
          return ClipRect(
            child: Align(
              alignment: AlignmentDirectional.topCenter,
              heightFactor: 1 - shut,
              child: reduced
                  ? Opacity(
                      opacity: (1 - shut * 1.6).clamp(0.0, 1.0),
                      child: child,
                    )
                  : child,
            ),
          );
        },
      ),
    );
  }
}

/// Anything under the rows that should be pulled up with them when a slot
/// above it closes — the "new Room" card at the foot of the list.
class RoomDissolveFollower extends StatelessWidget {
  const RoomDissolveFollower({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final host = RoomDissolveHost.of(context);
    if (host == null) return child;
    return _ChainLink(lag: host._trailingLag, host: host, child: child);
  }
}

/// Draws [child] [lag] logical pixels below where it was laid out, re-read
/// every frame a slot is closing. Only the translation updates: the child is
/// built once and keeps its raster.
class _ChainLink extends StatelessWidget {
  const _ChainLink({
    required this.lag,
    required this.host,
    required this.child,
  });

  final double Function() lag;
  final RoomDissolveHostState host;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: host._frame,
    child: child,
    builder: (context, child) =>
        Transform.translate(offset: Offset(0, lag()), child: child),
  );
}

/// The dust cloud: one overlay entry, one painter, one atlas draw per frame.
class _Dust extends StatefulWidget {
  const _Dust({
    required this.image,
    required this.pixelRatio,
    required this.rect,
    required this.fromRight,
    required this.tint,
    required this.onDone,
  });

  final ui.Image image;
  final double pixelRatio;
  final Rect rect;
  final bool fromRight;
  final Color tint;
  final VoidCallback onDone;

  @override
  State<_Dust> createState() => _DustState();
}

class _DustState extends State<_Dust> with SingleTickerProviderStateMixin {
  late final _Specks _specks = _Specks(
    size: widget.rect.size,
    pixelRatio: widget.pixelRatio,
    fromRight: widget.fromRight,
  );

  late final AnimationController _time = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_specks.duration * 1000).ceil()),
  );

  @override
  void initState() {
    super.initState();
    // Which specks are card and which are the transparent corners: only
    // card catches fire. Read once, off the frame; until it lands the specks
    // still fly, just without their glow.
    widget.image
        .toByteData(format: ui.ImageByteFormat.rawRgba)
        .then((bytes) {
          if (bytes != null && mounted) {
            _specks.ignite(bytes, widget.image.width, widget.image.height);
          }
        })
        .catchError((Object _) {});
    _time.forward().whenCompleteOrCancel(() {
      // After this frame: removing an overlay entry from inside its own
      // ticker callback would rebuild the overlay mid-frame.
      SchedulerBinding.instance.addPostFrameCallback((_) => widget.onDone());
    });
  }

  @override
  void dispose() {
    _time.dispose();
    widget.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          key: const Key('room-dissolve-dust'),
          painter: _DustPainter(
            time: _time,
            specks: _specks,
            image: widget.image,
            origin: widget.rect.topLeft,
            tint: widget.tint,
          ),
        ),
      ),
    ),
  );
}

/// Every speck's start, path and timing, worked out once.
class _Specks {
  _Specks({
    required Size size,
    required double pixelRatio,
    required bool fromRight,
  }) {
    // Cell size from the budget, never below 2.5 px: a 400 x 100 card comes
    // out at 1,400 specks of about 5 px — fine enough to read as dust, few
    // enough to hold 60 fps on the floor device.
    final cell = math.max(2.5, math.sqrt(size.width * size.height / _budget));
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    count = cols * rows;
    this.cell = cell;
    sourceCell = cell * pixelRatio;
    x0 = Float32List(count);
    y0 = Float32List(count);
    delay = Float32List(count);
    life = Float32List(count);
    vx = Float32List(count);
    vy = Float32List(count);
    lift = Float32List(count);
    spin = Float32List(count);
    wobble = Float32List(count);
    rects = Float32List(count * 4);
    glow = Float32List(count);
    ember = Float32List(count);
    final random = math.Random(9);
    final drift = fromRight ? 1.0 : -1.0;
    var longest = 0.0;
    var i = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final x = c * cell;
        final y = r * cell;
        x0[i] = x;
        y0[i] = y;
        // Distance from the edge the sweep starts at, 0..1.
        final along = fromRight
            ? 1 - (x + cell / 2) / size.width
            : (x + cell / 2) / size.width;
        // A ragged front rather than a ruler-straight one.
        delay[i] =
            along * _sweep +
            random.nextDouble() * 0.09 +
            (y / size.height) * 0.04;
        life[i] = 0.5 + random.nextDouble() * 0.32;
        vx[i] = drift * (24 + random.nextDouble() * 96);
        vy[i] = -(14 + random.nextDouble() * 70);
        lift[i] = 70 + random.nextDouble() * 150;
        spin[i] = (random.nextDouble() - 0.5) * 6;
        wobble[i] = random.nextDouble() * math.pi * 2;
        // Not every speck burns as bright: an even glow reads as a filter.
        glow[i] = 0.45 + random.nextDouble() * 0.55;
        final sx = x * pixelRatio;
        final sy = y * pixelRatio;
        rects[i * 4] = sx;
        rects[i * 4 + 1] = sy;
        rects[i * 4 + 2] = sx + sourceCell;
        rects[i * 4 + 3] = sy + sourceCell;
        longest = math.max(longest, delay[i] + life[i]);
        i++;
      }
    }
    duration = longest;
  }

  /// The most specks one row is allowed.
  static const _budget = 1400;

  /// Seconds the sweep takes to cross the card.
  static const _sweep = 0.3;

  late final int count;
  late final double cell;
  late final double sourceCell;
  late final double duration;
  late final Float32List x0;
  late final Float32List y0;
  late final Float32List delay;
  late final Float32List life;
  late final Float32List vx;
  late final Float32List vy;
  late final Float32List lift;
  late final Float32List spin;
  late final Float32List wobble;
  late final Float32List rects;

  /// How brightly each speck could burn, and how brightly it will: [glow]
  /// times the card's coverage under it, once [ignite] has read the image.
  late final Float32List glow;
  late final Float32List ember;

  /// Reads the photograph's alpha under each speck's centre, so the
  /// transparent rounded corners do not fly off as amber squares.
  void ignite(ByteData rgba, int width, int height) {
    for (var i = 0; i < count; i++) {
      final px = ((rects[i * 4] + rects[i * 4 + 2]) / 2).floor();
      final py = ((rects[i * 4 + 1] + rects[i * 4 + 3]) / 2).floor();
      if (px < 0 || py < 0 || px >= width || py >= height) continue;
      final alpha = rgba.getUint8((py * width + px) * 4 + 3) / 255;
      ember[i] = glow[i] * alpha;
    }
  }
}

class _DustPainter extends CustomPainter {
  _DustPainter({
    required this.time,
    required this.specks,
    required this.image,
    required this.origin,
    required this.tint,
  }) : super(repaint: time);

  final AnimationController time;
  final _Specks specks;
  final ui.Image image;
  final Offset origin;
  final Color tint;

  late final Float32List _transforms = Float32List(specks.count * 4);
  late final Int32List _colors = Int32List(specks.count);
  late final Float32List _emberPositions = Float32List(specks.count * 12);
  late final Int32List _emberColors = Int32List(specks.count * 6);
  final _paint = Paint()..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value * specks.duration;
    final s = specks;
    final anchor = s.sourceCell / 2;
    final unit = s.cell / s.sourceCell;
    const white = Color(0xFFFFFFFF);
    // The glow is a touch lighter than the accent: an ember's core is the
    // hottest thing on screen.
    final hot = Color.lerp(tint, white, 0.18)!;
    for (var i = 0; i < s.count; i++) {
      final age = t - s.delay[i];
      double x = origin.dx + s.x0[i] + s.cell / 2;
      double y = origin.dy + s.y0[i] + s.cell / 2;
      double scale = unit;
      double angle = 0;
      Color color = white;
      var emberAlpha = 0.0;
      var emberHalf = 0.0;
      if (age > 0) {
        final p = age / s.life[i];
        if (p >= 1) {
          scale = 0;
          color = const Color(0x00000000);
        } else {
          // Breaks away fast, then rises on its own heat.
          x += s.vx[i] * age + math.sin(s.wobble[i] + age * 9) * 3 * p;
          y += s.vy[i] * age - 0.5 * s.lift[i] * age * age;
          scale = unit * (1 - 0.65 * p);
          angle = s.spin[i] * age;
          final fade = math.pow(1 - p, 1.3).toDouble();
          // Catches within the first fifth of its flight.
          final heat = math.min(1.0, p * 4) * s.ember[i];
          // The speck of card burns away into its own glow: the picture
          // thins as the ember brightens, and warms towards amber.
          color = Color.lerp(
            white,
            tint,
            math.min(1, p * 1.4),
          )!.withValues(alpha: fade * (1 - 0.55 * heat));
          emberAlpha = heat * math.pow(1 - p, 1.6).toDouble() * 0.95;
          emberHalf = s.cell * (1 - 0.65 * p) * 0.36;
        }
      }
      final e = i * 12;
      final ex0 = x - emberHalf;
      final ex1 = x + emberHalf;
      final ey0 = y - emberHalf;
      final ey1 = y + emberHalf;
      _emberPositions
        ..[e] = ex0
        ..[e + 1] = ey0
        ..[e + 2] = ex1
        ..[e + 3] = ey0
        ..[e + 4] = ex1
        ..[e + 5] = ey1
        ..[e + 6] = ex0
        ..[e + 7] = ey0
        ..[e + 8] = ex1
        ..[e + 9] = ey1
        ..[e + 10] = ex0
        ..[e + 11] = ey1;
      final ec = hot.withValues(alpha: emberAlpha).toARGB32();
      _emberColors.fillRange(i * 6, i * 6 + 6, ec);
      final cos = math.cos(angle) * scale;
      final sin = math.sin(angle) * scale;
      final o = i * 4;
      _transforms[o] = cos;
      _transforms[o + 1] = sin;
      _transforms[o + 2] = x - cos * anchor + sin * anchor;
      _transforms[o + 3] = y - sin * anchor - cos * anchor;
      _colors[i] = color.toARGB32();
    }
    canvas.drawRawAtlas(
      image,
      _transforms,
      s.rects,
      _colors,
      BlendMode.modulate,
      null,
      _paint,
    );
    // The embers, over the specks: one more batch, no blur — a glow made of
    // small bright squares reads as light at this size and costs nothing.
    canvas.drawVertices(
      ui.Vertices.raw(
        ui.VertexMode.triangles,
        _emberPositions,
        colors: _emberColors,
      ),
      BlendMode.dst,
      _paint,
    );
  }

  @override
  bool shouldRepaint(_DustPainter old) =>
      old.specks != specks || old.image != image || old.origin != origin;
}

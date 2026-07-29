# beat_transitions

Step-to-step transitions for linear flows — onboarding, product tours, wizards.

Zero dependencies beyond the Flutter SDK. Extracted from Tark's onboarding
journey so the same motion can be reused in other projects; nothing in here
knows about a palette, a theme, a cubit or a router.

## Usage

You own the clock. The package never rebuilds your beats for the animation —
that is the whole point.

```dart
late final _stepT = AnimationController(
  vsync: this,
  duration: const Duration(milliseconds: 1100),
);

int _shown = 0;
int? _leaving;
int _dir = 1;

void _goTo(int step) {
  setState(() {
    _leaving = _shown;
    _dir = step > _shown ? 1 : -1;
    _shown = step;
  });
  _stepT.forward(from: 0).whenComplete(() => setState(() => _leaving = null));
}

@override
Widget build(BuildContext context) => BeatTransitionView(
  progress: _stepT,
  direction: _dir,
  leaving: _leaving == null ? null : buildBeat(_leaving!),
  incoming: buildBeat(_shown),
  transition: const HandoverTransition(accent: Color(0xFFF5853F)),
);
```

Set `_leaving` back to `null` when the controller finishes so an idle flow
collapses to just the beat widget and costs nothing at all.

`BeatTransitionView` reads the ambient `Directionality`, so RTL locales mirror
the motion automatically.

## Transitions

### `HandoverTransition` (default)

A staged handover rather than a slide. The phases live in `Stage`:

```text
t   0.00      0.15         0.46   0.58        0.88    1.00
    |  CHARGE  |   THROW    | TRANSIT |  ARRIVE  | LOCK |
    └ winds up ┘            └ empty  ┘          └ settles
```

The outgoing beat pulls *back* against the direction of travel and squashes
along it before it goes, then accelerates off the **end** edge, stretching and
turning away into perspective with ghost trails strung out behind it. The stage
then sits deliberately **empty** for a moment — nothing but parallax wind and a
targeting reticle closing on the landing zone — before the next beat
decelerates in from the **start** edge and settles on a damped bounce, with the
reticle snapping onto its corners and a shockwave pulsing out.

That empty middle is the point. Without it the two panels simply trade places
and the change reads as hurried no matter how long you make it.

```dart
const HandoverTransition(
  accent: Color(0xFFF5853F),
  streakCount: 26,   // parallax wind streaks; 0 turns the wind off
  turn: 0.30,        // radians of perspective Y-rotation at full travel
  arc: 18,           // px the incoming panel rises through as it settles
  trails: 3,         // ghost outlines behind each panel; 0 disables
  reticle: true,     // guide rails, converging brackets, lock shockwave
  exitToEnd: true,   // false = conventional "new content enters from the end"
)
```

Retime it by editing `Stage`'s phase boundaries; change how long it takes by
changing your controller's duration (1100ms is what the choreography is tuned
around).

**Performance.** A frame of this transition is two compositor operations on
cached rasters plus ~110 `drawLine`/`drawRect` calls. No blur, no shader, no
`saveLayer`, no clip, no non-rectangular path, and no widget rebuilt for the
animation. It was written against a Galaxy S8+ (Mali-G71, Android 9) as the
floor.

Two things to get right on the calling side:

* **Feed it static beats.** A per-child entrance animation inside the arriving
  panel re-records its raster every frame and is the one cost here that scales
  with how complex your beats are. Pass `kAlwaysCompleteAnimation` (or
  equivalent) for the duration and let the arrival choreography carry the
  moment.
* **Don't clip it.** The panels are *meant* to leave the frame. A `ClipRect`, a
  scroll viewport with overflowing content, or `Stack(clipBehavior:
  Clip.hardEdge)` between this widget and the screen edge will cut them off
  mid-flight.

### `SignalSweepTransition`

A radio channel retune: a luminous oscilloscope bar scans across the panel and
the next beat resolves in behind it out of digital static and CRT scanlines.
A hard wipe, so the two beats never overlap and there is zero ghosting.

```dart
const SignalSweepTransition(
  accent: Color(0xFFF5853F),
  quality: SweepQuality.lite,   // drops the mask blurs and thins the static
)
```

This one is expensive by design — the glow *is* the look. Per frame it re-cuts
two 48-segment `ClipPath`s (which defeats raster caching for both beats) and
strokes four copies of the waveform, three through a `MaskFilter` blur. Fine on
a modern GPU; `SweepQuality.lite` roughly halves the raster cost for older
tile-based mobile GPUs, and `HandoverTransition` is the answer when you need
something that is fast by construction rather than by dialling back.

`buildSignalSweep(...)` exposes the same effect as a plain function for callers
that already hold a `double` clock.

## Pieces

Each of these takes a `0 → 1` animation and paints nothing outside that range,
so they can be reused behind your own motion:

* **`SpeedField`** — the parallax wind layer.
* **`LockReticle`** — guide rails, converging corner brackets, lock shockwave.
* **`MotionTrails`** — ghost outlines trailing a moving box.
* **`Stage`** — the choreography itself, as plain numbers.

/// Step-to-step transitions for linear flows — onboarding, tours, wizards.
///
/// Self-contained: nothing in here depends on anything but the Flutter SDK, so
/// the package can be copied or path-depended into any project.
///
/// * [HandoverTransition] — the default. A staged handover: the old beat winds
///   up and is thrown off the end of the screen, the stage sits deliberately
///   empty while parallax wind tears through it, and the new beat is brought in
///   from the start under a targeting reticle that snaps onto it. Built to hold
///   60fps on low-end GPUs.
/// * [SignalSweepTransition] — a radio "channel retune": a glowing oscilloscope
///   bar scans the new beat in out of static. Much heavier; see its docs.
///
/// [Stage] is the shared choreography both the panels and the chrome read, and
/// the place to go to retime the phases.
///
/// Both transitions are driven by an [Animation] you own, through
/// [BeatTransitionView].
library;

export 'src/beat_transition.dart' show BeatTransition, BeatTransitionView;
export 'src/handover_transition.dart' show HandoverTransition;
export 'src/lock_reticle.dart' show LockReticle, MotionTrails;
export 'src/signal_sweep_transition.dart'
    show SignalSweepTransition, SweepQuality, buildSignalSweep;
export 'src/speed_field.dart' show SpeedField;
export 'src/stage.dart' show Stage;

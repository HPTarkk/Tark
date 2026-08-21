import 'dart:async';

import 'package:get_it/get_it.dart';

import '../../audio/data/voice_audio_session.dart';
import '../../audio/domain/entity/audio_route.dart';
import '../../audio/domain/service/audio_engine.dart';

/// What Preflight's bounded mic probe found.
enum MicProbeOutcome {
  /// Mic permission was refused (hard fail — the issue's own policy).
  permissionDenied,

  /// Permission granted, engine reports started, but no frame arrived
  /// within the probe window (hard fail — "engine-started-but-no-frames").
  noFrames,

  /// A frame arrived — the mic is genuinely delivering audio.
  ok,
}

/// [MicProbe.run]'s result: the frame-delivery outcome plus the route the
/// same probe session settled on (check 2 piggybacks on check 1's engine —
/// see the class doc for why this can't be two independent probes).
class MicProbeResult {
  const MicProbeResult({required this.outcome, required this.route});

  final MicProbeOutcome outcome;
  final AudioRoute route;
}

/// Check 1 (and check 2's route classification) — bounded-window
/// real-frame-delivery probe.
///
/// Deliberately a **throwaway probe engine**, not a warm handoff into the
/// real `WalkieTalkieCubit`'s `AudioEngine`: that cubit resolves and starts
/// its own engine synchronously inside its own constructor
/// (`walkie_talkie_cubit.dart`), with no seam to hand it an already-running
/// instance without forking the generated DI wiring — doing so would
/// recreate exactly the "who owns this engine" ambiguity the issue's
/// lifecycle section warns against. One extra native audio-device
/// open/close cycle is an accepted cost for zero duplicate-ownership risk.
/// Do not "optimize" this into sharing an engine with the real session.
///
/// Check 2 (output route) reads off this same session rather than running
/// independently: the route only settles once `engine.start()` has run
/// `VoiceAudioSession.configure()` internally, and `engine.dispose()`
/// releases that same voice session — querying the route after disposal
/// would read whatever the OS falls back to, not what this probe actually
/// used. So the route is captured here, between start and dispose, and
/// handed back alongside the frame-delivery outcome.
abstract final class MicProbe {
  /// Long enough to absorb AAudio/OpenSL startup jitter, short enough to
  /// keep Preflight's "a few seconds" budget.
  static const defaultTimeout = Duration(milliseconds: 1200);

  static Future<MicProbeResult> run({
    AudioEngine Function()? resolveEngine,
    Future<AudioRoute> Function()? resolveRoute,
    Duration timeout = defaultTimeout,
  }) async {
    final engine = (resolveEngine ?? () => GetIt.instance<AudioEngine>())();
    final route = resolveRoute ?? VoiceAudioSession.getCurrentRoute;
    try {
      await engine.start();
      if (!engine.currentStatus.hasPermission) {
        // start() never reached configureVoice on this branch — nothing to
        // classify.
        return const MicProbeResult(
          outcome: MicProbeOutcome.permissionDenied,
          route: AudioRoute.unknown,
        );
      }
      final resolvedRoute = await route();
      try {
        await engine.frames.first.timeout(timeout);
        return MicProbeResult(
          outcome: MicProbeOutcome.ok,
          route: resolvedRoute,
        );
      } on TimeoutException {
        return MicProbeResult(
          outcome: MicProbeOutcome.noFrames,
          route: resolvedRoute,
        );
      } on StateError {
        // The frames stream closed without ever emitting — same verdict as
        // timing out (a broadcast engine stream isn't expected to close on
        // its own while started, but `.first` throws this for any stream
        // that completes with no elements, so it's handled the same way).
        return MicProbeResult(
          outcome: MicProbeOutcome.noFrames,
          route: resolvedRoute,
        );
      }
    } finally {
      // Whichever branch above returns, this probe's engine must not
      // outlive the check — see the class doc.
      await engine.dispose();
    }
  }
}

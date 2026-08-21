import 'dart:async';

import 'package:get_it/get_it.dart';

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

/// Check 1 — bounded-window real-frame-delivery probe.
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
abstract final class MicProbe {
  /// Long enough to absorb AAudio/OpenSL startup jitter, short enough to
  /// keep Preflight's "a few seconds" budget.
  static const defaultTimeout = Duration(milliseconds: 1200);

  static Future<MicProbeOutcome> run({
    AudioEngine Function()? resolveEngine,
    Duration timeout = defaultTimeout,
  }) async {
    final engine = (resolveEngine ?? () => GetIt.instance<AudioEngine>())();
    try {
      await engine.start();
      if (!engine.currentStatus.hasPermission) {
        return MicProbeOutcome.permissionDenied;
      }
      try {
        await engine.frames.first.timeout(timeout);
        return MicProbeOutcome.ok;
      } on TimeoutException {
        return MicProbeOutcome.noFrames;
      } on StateError {
        // The frames stream closed without ever emitting — same verdict as
        // timing out (a broadcast engine stream isn't expected to close on
        // its own while started, but `.first` throws this for any stream
        // that completes with no elements, so it's handled the same way).
        return MicProbeOutcome.noFrames;
      }
    } finally {
      // Whichever branch above returns, this probe's engine must not
      // outlive the check — see the class doc.
      await engine.dispose();
    }
  }
}

import 'dart:async';

import 'package:permission_handler/permission_handler.dart';

import '../../../core/audio/audio_format_profile.dart';
import '../../../core/diagnostics/diagnostic_log.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/utils/latest_only.dart';
import '../../../core/utils/permission_queue.dart';
import '../../audio/data/session_keep_alive.dart';
import '../../audio/data/system_audio_capture.dart';
import '../../transfer/domain/service/transport_advisor.dart';
import '../data/background_readiness_probe.dart';
import '../data/mic_probe.dart';
import '../domain/service/background_readiness_check.dart';
import '../domain/service/diagnostics_readiness_check.dart';
import '../domain/service/mic_check.dart';
import '../domain/service/profile_readiness_check.dart';
import '../domain/service/route_check.dart';
import '../domain/service/shared_music_readiness_check.dart';
import '../domain/service/transport_readiness_check.dart';
import 'preflight_result.dart';

/// A running Preflight — an [initial] snapshot (whatever resolves
/// synchronously) plus [results], which carries every later update as the
/// slower checks (mic probe, background, Shared Music) finish or a
/// remediation action re-runs one of them.
///
/// Long-lived by design, the same way `WalkieTalkieCubit`'s stream feeds
/// `showRecoverySheet`: a remediation action (e.g. "Allow mic") re-runs its
/// check and must be able to push a fresh row after the initial batch has
/// already settled, so nothing here auto-closes. Whoever opens the sheet
/// owns [dispose] — call it exactly once, when the sheet itself is torn
/// down, so a cancelled Preflight doesn't leave the controller (or an
/// in-flight retry closing over it) live behind the real channel.
class PreflightSession {
  PreflightSession._(
    this.initial,
    this._controller, {
    Recheck? recheckBackground,
    Recheck? recheckMic,
  }) : _recheckBackground = recheckBackground,
       _recheckMic = recheckMic;

  /// Test seam: wraps a fixed, already-resolved result with no further
  /// updates. Mirrors `DiagnosticLog.debugAttach`'s naming — this is not for
  /// production use, `PreflightService.start` is.
  factory PreflightSession.debugFixed(PreflightResult result) {
    final controller = StreamController<PreflightResult>()..add(result);
    return PreflightSession._(result, controller);
  }

  /// Test seam: wraps [initial] plus a caller-driven [results] stream, for
  /// tests that need to exercise the sheet's progressive/pending-row
  /// rendering without a real probe. [recheckBackground]/[recheckMic] let a
  /// test observe the sheet's resume-triggered rechecks (see [PreflightSession
  /// .recheckBackground]/[PreflightSession.recheckMic]) without a real
  /// platform channel.
  factory PreflightSession.debugStream({
    required PreflightResult initial,
    required Stream<PreflightResult> results,
    Recheck? recheckBackground,
    Recheck? recheckMic,
  }) {
    final controller = StreamController<PreflightResult>();
    results.listen(controller.add, onDone: controller.close);
    return PreflightSession._(
      initial,
      controller,
      recheckBackground: recheckBackground,
      recheckMic: recheckMic,
    );
  }

  final PreflightResult initial;
  final StreamController<PreflightResult> _controller;
  final Recheck? _recheckBackground;
  final Recheck? _recheckMic;

  Stream<PreflightResult> get results => _controller.stream;

  /// Re-runs the background-readiness check on demand.
  ///
  /// Exists because [PreflightService]'s battery-exemption and Autostart
  /// actions both hand off to a system screen (`ACTION_REQUEST_IGNORE_
  /// BATTERY_OPTIMIZATIONS`, MIUI's Autostart manager) via a bare
  /// `startActivity`, which returns to Dart the instant the screen opens —
  /// long before the user has actually granted anything. The retry that used
  /// to run right after used to read the OS state mid-transition and land on
  /// "still not exempt" every time, only correcting itself on a second manual
  /// tap. The sheet calls this instead when the app resumes, the same
  /// re-check-on-resume `BackgroundPermissionBanner` already uses for the
  /// identical hand-off. A no-op for the debug sessions, which have no live
  /// probe to rerun.
  Future<void> recheckBackground() => _recheckBackground?.call() ?? Future.value();

  /// Re-runs the mic probe (and its piggybacked route check) on demand.
  ///
  /// The mic row's own "Open Settings" action (see `mic_check.dart`'s
  /// `permissionDenied` case — offered once permission is permanently
  /// denied and re-requesting it can no longer show the OS dialog) hands off
  /// to the app's Settings page the same blunt way the background checks
  /// hand off to a system screen: it just opens Settings and stops, with no
  /// way to know when — or whether — the user actually flipped the
  /// permission there. Without this, granting mic access in Settings and
  /// coming back left the row stuck on "denied" until the *other* action
  /// ("Allow mic") was tapped separately. The sheet calls this on every
  /// resume, same as [recheckBackground]. A no-op for the debug sessions.
  Future<void> recheckMic() => _recheckMic?.call() ?? Future.value();

  void dispose() => _controller.close();
}

typedef Recheck = Future<void> Function();

/// Runs every check Preflight can answer before a peer exists — see the
/// module doc on why checks 5 (peer reachability) isn't run from here:
/// pre-connect it is always the same "nobody's joined yet" unknown, which
/// carries no information worth computing.
abstract final class PreflightService {
  static PreflightSession start({
    required AppLocalizations s,
    required ChannelPlan plan,
  }) {
    final controller = StreamController<PreflightResult>();
    var current = PreflightResult(
      connection: transportReadinessCheck(s: s, plan: plan),
      hdVoice: profileReadinessCheck(
        s: s,
        hdVoiceEnabled: AudioFormatProfile.hdVoiceEnabled,
      ),
      diagnostics: diagnosticsReadinessCheck(
        s: s,
        isEnabled: DiagnosticLog.isEnabled,
        isPersisting: DiagnosticLog.isPersisting,
      ),
    );

    void update(PreflightResult Function(PreflightResult) apply) {
      if (controller.isClosed) return;
      current = apply(current);
      controller.add(current);
    }

    // Same dual-trigger shape as the background check below: the row's own
    // "Allow mic" retry and the resume-triggered recheck (armed after the
    // permanently-denied row's "Open Settings" action) can both have a
    // MicProbe run in flight at once, and a probe opens the mic hardware and
    // waits up to MicProbe.defaultTimeout for a frame — plenty of time for a
    // later-started, faster-resolving probe to finish first. [LatestOnly]
    // keeps the last-issued probe authoritative regardless of which
    // finishes first.
    final micGeneration = LatestOnly();

    Future<void> runMicAndRoute() async {
      final generation = micGeneration.start();
      Future<void> retry() => runMicAndRoute();
      final probe = await MicProbe.run();
      if (!micGeneration.isCurrent(generation)) return;
      update(
        (r) => r.copyWith(
          mic: micCheck(s: s, outcome: probe.outcome, retry: retry),
          route: routeReadinessCheck(s: s, route: probe.route),
        ),
      );
    }

    // Two things can each trigger a background recheck: the row's own
    // action ("Allow" -> requestIgnoreBatteryOptimizations) and the
    // resume-triggered recheck in _PreflightPageState. The action's own
    // retry fires the instant the settings hand-off *opens* — see
    // PreflightSession.recheckBackground's doc — so it is reading stale OS
    // state and, on a device slow enough for that stale read to still be
    // in flight when the user has already granted the permission and
    // resumed, it can complete *after* the resume recheck and clobber a
    // correct "granted" result with a stale "not yet" one. [LatestOnly]
    // makes the two racing calls resolve in issue order rather than
    // completion order.
    final backgroundGeneration = LatestOnly();

    Future<void> runBackground() async {
      final generation = backgroundGeneration.start();
      Future<void> retry() => runBackground();
      final notificationRequired =
          await BackgroundReadinessProbe.notificationRequired();
      final notificationGranted =
          await BackgroundReadinessProbe.notificationGranted();
      final batteryExempt =
          await SessionKeepAlive.isIgnoringBatteryOptimizations();
      final isMiui = await SessionKeepAlive.isMiui();
      if (!backgroundGeneration.isCurrent(generation)) return;
      update(
        (r) => r.copyWith(
          background: backgroundReadinessCheck(
            s: s,
            notificationRequired: notificationRequired,
            notificationGranted: notificationGranted,
            batteryExempt: batteryExempt,
            isMiui: isMiui,
            requestNotification: () async {
              await PermissionQueue.run(() => Permission.notification.request());
              await retry();
            },
            requestBatteryExemption: () async {
              await SessionKeepAlive.requestIgnoreBatteryOptimizations();
              await retry();
            },
            openAutoStartSettings: () async {
              await SessionKeepAlive.openAutoStartSettings();
              await retry();
            },
          ),
        ),
      );
    }

    Future<void> runSharedMusic() async {
      final supported = await SystemAudioCapture.isSupported;
      update(
        (r) => r.copyWith(
          sharedMusic: sharedMusicReadinessCheck(s: s, isSupported: supported),
        ),
      );
    }

    unawaited(
      Future.wait([runMicAndRoute(), runBackground(), runSharedMusic()]),
    );

    return PreflightSession._(
      current,
      controller,
      recheckBackground: runBackground,
      recheckMic: runMicAndRoute,
    );
  }
}

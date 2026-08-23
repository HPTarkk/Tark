import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/recovery/recovery_banner.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/domain/service/transport_advisor.dart';
import '../../service/preflight_result.dart';
import '../../service/preflight_service.dart';
import '../widget/signal_radar.dart';

/// Signature of [PreflightService.start] — a seam so tests can substitute a
/// fake session instead of a real probe/platform-channel run, the same way
/// [MicProbe.run]'s `resolveEngine` lets its own tests avoid the real engine.
typedef PreflightSessionStarter =
    PreflightSession Function({
      required AppLocalizations s,
      required ChannelPlan plan,
    });

/// Shows the full pre-ride Preflight page and waits for the user's answer.
///
/// Returns `true` the moment they choose to proceed ("Enter channel" once
/// everything's clear, "Continue anyway" if only warnings remain) and
/// `false` on cancel (back button/gesture) — never while a hard failure is
/// still standing, since the CTA itself stays disabled until then.
///
/// A full page rather than a modal sheet: the six-row checklist is exactly
/// the content a bottom sheet handles worst, since the sheet's own
/// drag-to-dismiss gesture and the list's scroll gesture are reaching for
/// the same swipe, and a phone with more than a handful of low-end-floor
/// pixels to spare (six rows, a hero dial, a header and a CTA) forced a
/// nested-scroll compromise a sheet was never sized for. A pushed page owns
/// its full height instead, so the list gets [Expanded] rather than
/// `shrinkWrap` fighting a percentage-of-screen [Container] constraint.
///
/// A fully clear picture doesn't wait for a tap at all: this is the check
/// that runs before *every* return to a channel, not just a first install,
/// and a person is not owed a button press for a screen that has nothing to
/// tell them. See `_PreflightPageState._scheduleAutoLaunch` for the short
/// grace pause and the launch flourish that plays instead of an instant cut.
/// A warning or a hard failure always waits for the tap — those are the
/// moments the screen exists for.
Future<bool> showPreflightPage(
  BuildContext context, {
  required ChannelPlan plan,
  PreflightSessionStarter startSession = PreflightService.start,
}) async {
  final result = await Navigator.of(context).push<bool>(
    PageRouteBuilder<bool>(
      transitionDuration: const Duration(milliseconds: 360),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, _, _) =>
          _PreflightPage(plan: plan, startSession: startSession),
      // Rises in from just below rather than a flat cross-fade — the last
      // physical trace of the sheet this replaced, kept because "the next
      // screen comes up from where your thumb is" is still the right story
      // for a page that opens on a tap, not a plain navigation.
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position:
              Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        ),
      ),
    ),
  );
  return result ?? false;
}

class _PreflightPage extends StatefulWidget {
  const _PreflightPage({required this.plan, required this.startSession});

  final ChannelPlan plan;
  final PreflightSessionStarter startSession;

  @override
  State<_PreflightPage> createState() => _PreflightPageState();
}

class _PreflightPageState extends State<_PreflightPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  PreflightSession? _session;
  PreflightResult? _result;
  StreamSubscription<PreflightResult>? _resultsSub;
  Timer? _autoLaunchTimer;
  bool _launching = false;

  /// Backstop for the background row while it isn't [RecoveryStatus.ok]: on
  /// at least one real device/ROM, returning from the battery-restriction
  /// screen never delivered a clean `AppLifecycleState.resumed` transition
  /// at all (unlike the quick "Allow" dialog, the full battery-settings page
  /// is apparently shown in a way that doesn't reliably pause/resume this
  /// activity on every OEM), leaving [didChangeAppLifecycleState]'s recheck
  /// with nothing to fire on. Polling is what [didChangeAppLifecycleState]
  /// was trying to avoid (see [PreflightSession.recheckBackground]'s doc on
  /// reading mid-transition state) — but a cheap, no-hardware background
  /// read every couple of seconds is a fair trade for actually catching up
  /// with reality instead of leaving the row stuck. Only the background row
  /// gets this — the mic row's recheck opens real mic hardware, which is not
  /// something to do on a timer.
  Timer? _backgroundPollTimer;
  static const _backgroundPollInterval = Duration(milliseconds: 1500);

  late final AnimationController _entrance;

  /// Drives the launch flourish — see [_scheduleAutoLaunch]. Idle (and
  /// therefore free) until the one moment it's needed, unlike [_entrance]
  /// which always plays.
  late final AnimationController _launch;

  /// How long a fully-clear result sits on screen before the page moves on
  /// by itself — long enough to read as "all clear" rather than a flicker,
  /// short enough that it never feels like the app is making someone wait.
  static const _autoLaunchGrace = Duration(milliseconds: 900);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // One controller drives every row's staggered entrance (see _PreflightRow)
    // — six independent controllers would each tick a frame callback for the
    // same single visual beat, which is the kind of per-row animation cost
    // the low-end-device floor can't absorb.
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..forward();
    _launch = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 640),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The battery-exemption/Autostart actions and the mic row's "Open
    // Settings" action (offered once permission is permanently denied) all
    // hand off to a system screen and either report success the instant it
    // *opens* or don't report back at all — never once the user has
    // actually made the change there. See PreflightSession
    // .recheckBackground/.recheckMic. Re-checking both on every resume (not
    // just after one specific action) is the same blunt-but-correct
    // approach BackgroundPermissionBanner already uses for its own identical
    // hand-off.
    if (state != AppLifecycleState.resumed) return;
    _session?.recheckBackground();
    _session?.recheckMic();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not initState: resolving AppLocalizations depends on an inherited
    // widget, which the framework forbids before initState has returned.
    // Guarded so a later dependency change (a locale switch mid-page) can't
    // start a second, orphaned session.
    if (_session == null) {
      final session = widget.startSession(s: context.getString, plan: widget.plan);
      _session = session;
      _result = session.initial;
      _scheduleAutoLaunch(session.initial);
      _updateBackgroundPolling(session.initial);
      // A single subscription, not a second one alongside a StreamBuilder:
      // [PreflightSession.results] is single-subscription, and this is the
      // one place both the row rendering and the auto-launch watch need to
      // read from.
      _resultsSub = session.results.listen((result) {
        if (!mounted) return;
        setState(() => _result = result);
        _scheduleAutoLaunch(result);
        _updateBackgroundPolling(result);
      });
    }
  }

  /// Arms (or disarms) [_backgroundPollTimer] — see its doc for why this
  /// exists alongside the resume-triggered recheck rather than instead of
  /// it. Idempotent: safe to call on every result, whether or not polling
  /// was already running.
  void _updateBackgroundPolling(PreflightResult result) {
    final resolved = result.background?.isHealthy ?? false;
    if (resolved) {
      _backgroundPollTimer?.cancel();
      _backgroundPollTimer = null;
      return;
    }
    _backgroundPollTimer ??= Timer.periodic(
      _backgroundPollInterval,
      (_) => _session?.recheckBackground(),
    );
  }

  /// Arms (or disarms) the walk-away timer for a fully-clear result.
  ///
  /// Only ever reads the picture as "clear enough to leave alone" when
  /// nothing is pending, blocking, or merely a warning — a warning still
  /// gets its own deliberate "Continue anyway" tap, because it is a real
  /// trade-off someone is owed a say in, not a formality. A remediation that
  /// un-clears an already-scheduled result (rare, but the mic retry path
  /// makes it possible) disarms the timer rather than letting a stale one
  /// fire into a picture that no longer earned it.
  void _scheduleAutoLaunch(PreflightResult result) {
    final allClear =
        result.isComplete && !result.hasBlocking && !result.hasOnlyWarning;
    if (!allClear) {
      _autoLaunchTimer?.cancel();
      _autoLaunchTimer = null;
      return;
    }
    _autoLaunchTimer ??= Timer(_autoLaunchGrace, () {
      _autoLaunchTimer = null;
      if (mounted && !_launching) _autoLaunch();
    });
  }

  /// The one-shot "we're going in" sequence: a launch flourish plays, then
  /// the page closes itself. Manual taps on the CTA skip straight to
  /// [Navigator.pop] instead — a person who already reached out and pressed
  /// something is not owed a flourish delaying the very thing they asked for;
  /// the flourish exists to explain why the *screen* moved when nobody
  /// touched it.
  Future<void> _autoLaunch() async {
    if (_launching) return;
    setState(() => _launching = true);
    HapticFeedback.heavyImpact();
    await _launch.forward();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoLaunchTimer?.cancel();
    _backgroundPollTimer?.cancel();
    // The session must not outlive this page: a cancelled Preflight leaving
    // its controller (and any in-flight retry closing over it) alive behind
    // the real channel is exactly the leak the issue's lifecycle section
    // warns against.
    _resultsSub?.cancel();
    _session?.dispose();
    _entrance.dispose();
    _launch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final result = _result!;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: AnimatedBuilder(
              animation: _launch,
              builder: (context, child) => Opacity(
                opacity: 1 - _launch.value,
                child: Transform.translate(
                  offset: Offset(0, -18 * _launch.value),
                  child: child,
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        _BackButton(
                          onTap: () => Navigator.of(context).pop(false),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SignalRadar(
                    checks: _Slot.values
                        .map((slot) => slot.checkOf(result))
                        .toList(),
                    isComplete: result.isComplete,
                    hasBlocking: result.hasBlocking,
                    hasOnlyWarning: result.hasOnlyWarning,
                  ),
                  const SizedBox(height: 16),
                  _Header(s: s, result: result),
                  const SizedBox(height: 12),
                  // Expanded, not Flexible+shrinkWrap: the whole reason this
                  // is a page and not a sheet is that the list now owns
                  // real, fixed vertical space to scroll within instead of
                  // negotiating height against a modal's own drag gesture.
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      itemCount: _Slot.values.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _PreflightRow(
                        slot: _Slot.values[i],
                        s: s,
                        check: _Slot.values[i].checkOf(result),
                        index: i,
                        entrance: _entrance,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: _Cta(s: s, result: result),
                  ),
                ],
              ),
            ),
          ),
          // Only ever mounted for the auto path (see _autoLaunch) — a
          // manual tap never sets _launching, so this never competes with
          // the instant close a deliberate press is owed.
          if (_launching)
            Positioned.fill(child: _LaunchBurst(animation: _launch)),
        ],
      ),
    );
  }
}

/// The one way back that doesn't depend on the platform providing its own —
/// mirrors [WifiHotspotPage]'s leading arrow, but as a standalone chip rather
/// than an AppBar's, since this page is full-bleed rather than boxed under a
/// bar.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(
          Icons.arrow_back_rounded,
          color: AppColors.textPrimary,
          size: 20,
        ),
      ),
    );
  }
}

/// The launch flourish: two rings of the "all clear" green bursting outward
/// from the page's centre and fading as the checklist itself lifts away
/// (see the [AnimatedBuilder] wrapping the page's [Column]) — the one moment
/// this screen spends looking like a launch rather than a checklist.
///
/// Both rings are plain [Container]s scaled and faded by a single
/// [AnimationController], the same idiom [SignalRadar]'s own bloom already
/// uses — no [CustomPainter], no shader rebuilt per frame, and it only ever
/// exists for this one 640ms pass rather than sitting in the tree accruing an
/// idle cost the way a looping effect would.
class _LaunchBurst extends StatelessWidget {
  const _LaunchBurst({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value;
          // Held near-full through most of the sweep, then eased out right
          // at the end so the page doesn't get yanked shut mid-glow.
          final fade = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
          return Opacity(
            opacity: fade,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: 0.3 + t * 2.6,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.green.withAlpha(
                          (60 * (1 - t)).round(),
                        ),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: 0.3 + t * 3.6,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.green.withAlpha(
                            (200 * (1 - t)).round(),
                          ),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The six rows the page shows, in display order — see [PreflightResult]'s
/// doc for why checks 5/8 aren't in this list.
enum _Slot { mic, headset, connection, background, hdVoice, sharedMusic }

extension on _Slot {
  RecoveryCheck? checkOf(PreflightResult r) => switch (this) {
    _Slot.mic => r.mic,
    _Slot.headset => r.route,
    _Slot.connection => r.connection,
    _Slot.background => r.background,
    _Slot.hdVoice => r.hdVoice,
    _Slot.sharedMusic => r.sharedMusic,
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.s, required this.result});

  final AppLocalizations s;
  final PreflightResult result;

  @override
  Widget build(BuildContext context) {
    final subtitle = !result.isComplete
        ? s.preflight_subtitle_checking
        : result.hasBlocking
        ? s.preflight_subtitle_blocked
        : result.hasOnlyWarning
        ? s.preflight_subtitle_warning
        : s.preflight_subtitle_ready;
    final subtitleColor = !result.isComplete
        ? AppColors.textSecondary
        : result.hasBlocking
        ? AppColors.red
        : result.hasOnlyWarning
        ? AppColors.amber
        : AppColors.green;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.preflight_title,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                subtitle,
                key: ValueKey(subtitle),
                style: TextStyle(
                  color: subtitleColor,
                  fontSize: 12.5,
                  height: 1.5,
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

class _PreflightRow extends StatelessWidget {
  const _PreflightRow({
    required this.slot,
    required this.s,
    required this.check,
    required this.index,
    required this.entrance,
  });

  final _Slot slot;
  final AppLocalizations s;
  final RecoveryCheck? check;
  final int index;
  final Animation<double> entrance;

  String _label() => switch (slot) {
    _Slot.mic => s.preflight_check_mic,
    _Slot.headset => s.preflight_check_headset,
    _Slot.connection => s.preflight_check_connection,
    _Slot.background => s.preflight_check_background,
    _Slot.hdVoice => s.preflight_check_hd_voice,
    _Slot.sharedMusic => s.preflight_check_shared_music,
  };

  @override
  Widget build(BuildContext context) {
    // Staggered off one shared controller: each row's own slice of the same
    // 620ms sweep, not an independent animation — see _PreflightPageState.
    final start = (index * 0.09).clamp(0.0, 0.55);
    final curved = CurvedAnimation(
      parent: entrance,
      curve: Interval(
        start,
        (start + 0.45).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, (1 - curved.value) * 14),
          child: child,
        ),
      ),
      child: _content(),
    );
  }

  Widget _content() {
    final resolved = check;
    final accent = resolved == null
        ? AppColors.textSecondary
        : RecoveryBanner.accentFor(resolved.status);
    final unhealthy = resolved != null && !resolved.isHealthy;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: unhealthy ? accent.withAlpha(16) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: unhealthy ? accent.withAlpha(110) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusGlyph(check: resolved),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _label(),
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      resolved?.detail ?? s.preflight_checking,
                      style: TextStyle(
                        color: resolved == null
                            ? AppColors.textSecondary
                            : (resolved.isHealthy
                                  ? AppColors.textSecondary
                                  : accent),
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (resolved != null && resolved.actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            RecoveryActionRow(actions: resolved.actions, accent: accent),
          ],
        ],
      ),
    );
  }
}

/// The row's leading glyph: a breathing dot while pending, cross-fading into
/// the resolved status icon the instant a check settles — one bold effect
/// (a pop-in swap), not a pile of simultaneous ones.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.check});

  final RecoveryCheck? check;

  @override
  Widget build(BuildContext context) {
    final resolved = check;
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: resolved == null
            ? const _PendingDot(key: ValueKey('pending'))
            : Icon(
                RecoveryBanner.iconFor(resolved.status),
                color: RecoveryBanner.accentFor(resolved.status),
                size: 18,
                key: ValueKey(resolved.status),
              ),
      ),
    );
  }
}

class _PendingDot extends StatefulWidget {
  const _PendingDot({super.key});

  @override
  State<_PendingDot> createState() => _PendingDotState();
}

class _PendingDotState extends State<_PendingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ).drive(Tween(begin: 0.35, end: 1.0)),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: AppColors.amber,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _Cta extends StatelessWidget {
  const _Cta({required this.s, required this.result});

  final AppLocalizations s;
  final PreflightResult result;

  @override
  Widget build(BuildContext context) {
    final incomplete = !result.isComplete;
    final blocked = result.isComplete && result.hasBlocking;
    final enabled = result.isComplete && !result.hasBlocking;
    final label = incomplete
        ? s.preflight_checking
        : blocked
        ? s.preflight_fix_issues
        : result.hasOnlyWarning
        ? s.preflight_continue_anyway
        : s.preflight_enter_channel;
    final accent = blocked
        ? AppColors.red
        : (result.isComplete && result.hasOnlyWarning)
        ? AppColors.amber
        : AppColors.green;

    return Semantics(
      // One merged button node with the row's own label, rather than a
      // screen reader separately reading an unlabeled tappable region and
      // then the text inside it as two things. onTap is repeated here
      // (not just left to the inner InkWell) because excludeSemantics
      // drops the descendant's own semantics annotations wholesale,
      // including the tap action InkWell would otherwise have
      // contributed — without this, a screen reader's activation gesture
      // would land on a correctly-labeled button that silently did nothing.
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? () => Navigator.of(context).pop(true) : null,
      excludeSemantics: true,
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: enabled ? accent : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: enabled ? null : Border.all(color: AppColors.border),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: enabled ? () => Navigator.of(context).pop(true) : null,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (incomplete) ...[
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(
                            AppColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        color: enabled
                            ? Colors.black.withAlpha(220)
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

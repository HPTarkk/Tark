import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/config/support_config.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/copy_chip.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../room/presentation/widget/room_visuals.dart';
import '../../domain/listener_mutes.dart';
import '../../domain/abuse_report.dart';
import '../member_subject.dart';
import 'report_scene_painter.dart';

/// Opens the report story for [subject].
///
/// [launchMail] and [mutes] are seams for tests; the app uses the platform's
/// mail handler and the shared mute registry.
Future<void> showReportStory(
  BuildContext context, {
  required MemberSubject subject,
  ListenerMutes? mutes,
  Future<bool> Function(Uri uri)? launchMail,
}) => showModalBottomSheet<void>(
  context: context,
  routeSettings: const RouteSettings(name: 'ReportStorySheet'),
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  barrierColor: Colors.black.withValues(alpha: 0.62),
  builder: (_) => ReportStorySheet(
    subject: subject,
    mutes: mutes ?? ListenerMutes.instance,
    launchMail: launchMail ?? _launchMail,
  ),
);

Future<bool> _launchMail(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

enum _Phase { intro, choose, sending, done, noMail }

/// Reporting someone, told as a tiny story instead of a form.
///
/// Two riders share the road. The other one turns on you, and their words
/// knock the smile off your face. You say what it was, and the scene acts it
/// out: the bubble fills with swearing, lightning, a struck-out name tag, or
/// noise. Then a glass dome drops over them (the mute, pre-selected because it
/// is what almost everybody wants), their shouting bounces off the glass, and
/// you cheer up. Sending folds it all into an envelope that flies off to us.
///
/// Every beat of the scene is something the app is actually doing: the
/// dome is the real mute, the envelope is the real email. Nothing is decoration
/// that pretends.
///
/// Reduced motion keeps every state of the story (who is upset, what they
/// said, the dome, the send) and drops the travel: no pops, flights, bounces
/// or ambient chatter.
class ReportStorySheet extends StatefulWidget {
  const ReportStorySheet({
    required this.subject,
    required this.mutes,
    required this.launchMail,
    super.key,
  });

  final MemberSubject subject;
  final ListenerMutes mutes;
  final Future<bool> Function(Uri uri) launchMail;

  @override
  State<ReportStorySheet> createState() => _ReportStorySheetState();
}

class _ReportStorySheetState extends State<ReportStorySheet>
    with TickerProviderStateMixin {
  static const _domeSpring = SpringDescription(
    mass: 1,
    stiffness: 260,
    damping: 13,
  );
  static const _moodSpring = SpringDescription(
    mass: 1,
    stiffness: 110,
    damping: 15,
  );

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final AnimationController _punch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  late final AnimationController _dome = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _mood = AnimationController.unbounded(
    vsync: this,
    value: -1,
  );
  late final AnimationController _send = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );
  late final AnimationController _celebrate = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  late final Listenable _scene = Listenable.merge([
    _intro,
    _ambient,
    _punch,
    _dome,
    _mood,
    _send,
    _celebrate,
  ]);

  _Phase _phase = _Phase.intro;
  ReportReason? _reason;
  late bool _mute;
  bool _domeQueued = false;
  String? _appVersion;
  String? _mailText;
  bool _started = false;

  /// The mute and Send block, scrolled into view when it first appears: on a
  /// short phone it lands below the fold, right where nobody is looking.
  final GlobalKey _sendKey = GlobalKey();

  bool get _reduced => AppMotion.reduced(context);

  @override
  void initState() {
    super.initState();
    _mute = widget.subject.canMute;
    _intro.addListener(_onIntro);
    unawaited(_readVersion());
  }

  Future<void> _readVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Left out of the report rather than guessed.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ambient.loopUnlessReduced(context);
    if (!_started) {
      _started = true;
      if (_reduced) {
        // Straight to the state the intro arrives at: same story, no travel.
        _phase = _Phase.choose;
        _intro.value = 1;
      } else {
        _intro.forward();
      }
    }
  }

  void _onIntro() {
    if (_phase == _Phase.intro && _intro.value >= 0.8) {
      setState(() => _phase = _Phase.choose);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _ambient.dispose();
    _punch.dispose();
    _dome.dispose();
    _mood.dispose();
    _send.dispose();
    _celebrate.dispose();
    super.dispose();
  }

  // ── Story beats ──────────────────────────────────────────────────────────

  void _pick(ReportReason reason) {
    if (_phase != _Phase.choose) return;
    HapticFeedback.selectionClick();
    final first = _reason == null;
    setState(() => _reason = reason);
    if (!_reduced) unawaited(_punch.forward(from: 0));
    if (first) {
      Future<void>.delayed(AppMotion.sheet + AppMotion.press, () {
        final target = _sendKey.currentContext;
        if (!mounted || target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: _reduced ? Duration.zero : AppMotion.sheet,
            curve: AppMotion.drawer,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      });
    }
    if (first && _mute && !_domeQueued) {
      _domeQueued = true;
      // Let the new words land first, then the protection.
      Future<void>.delayed(Duration(milliseconds: _reduced ? 0 : 650), () {
        if (mounted && _mute && _phase == _Phase.choose) _setDome(true);
      });
    }
  }

  void _toggleMute(bool on) {
    HapticFeedback.selectionClick();
    setState(() {
      _mute = on;
      _domeQueued = true;
    });
    _setDome(on);
  }

  void _setDome(bool down) {
    _springTo(_mood, down ? 0.35 : -1, _moodSpring);
    if (_reduced) {
      _dome.value = down ? 1 : 0;
      return;
    }
    _dome.animateWith(
      SpringSimulation(_domeSpring, _dome.value, down ? 1 : 0, 0),
    );
    if (down) {
      Future<void>.delayed(const Duration(milliseconds: 230), () {
        if (mounted) HapticFeedback.lightImpact();
      });
    }
  }

  void _springTo(
    AnimationController controller,
    double target,
    SpringDescription spring,
  ) {
    if (_reduced) {
      controller.value = target;
      return;
    }
    controller.animateWith(
      SpringSimulation(spring, controller.value, target, 0),
    );
  }

  Future<void> _sendReport() async {
    final reason = _reason;
    if (reason == null || _phase != _Phase.choose) return;
    HapticFeedback.mediumImpact();
    final s = context.getString;
    final subject = widget.subject;
    final reasonLabel = _reasonLabel(s, reason);
    final report = AbuseReport(
      reportedName: subject.name,
      reason: reason,
      at: DateTime.now(),
      roomName: subject.roomName,
      reportedMemberId: subject.memberId,
      appVersion: _appVersion,
    );
    final mailSubject = s.report_mail_subject(reasonLabel);
    final body = s.report_mail_body(
      report.reportedName,
      reasonLabel,
      report.roomName ?? s.report_mail_quick_channel,
      report.reportedMemberId ?? '-',
      AbuseReport.formatTime(report.at),
      report.appVersion ?? '-',
    );
    _mailText = '${SupportConfig.email}\n$mailSubject\n\n$body';

    setState(() => _phase = _Phase.sending);
    if (_mute && subject.canMute) {
      unawaited(subject.setMuted(widget.mutes, true));
    }
    if (!_reduced) await _send.forward(from: 0);
    if (!mounted) return;

    final opened = await widget.launchMail(
      AbuseReport.mailto(subject: mailSubject, body: body),
    );
    if (!mounted) return;
    setState(() => _phase = opened ? _Phase.done : _Phase.noMail);
    _springTo(_mood, opened ? 1 : 0.6, _moodSpring);
    if (opened && !_reduced) unawaited(_celebrate.forward(from: 0));
  }

  // ── Frame ────────────────────────────────────────────────────────────────

  double _iv(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  ReportSceneFrame _frame(BuildContext context) {
    final t = _intro.value;
    final introDone = t >= 1;
    final punch = math.sin(math.pi * _punch.value);
    final landed = _dome.value.clamp(0.0, 1.0);

    final moodIntro = 1 - 2 * AppMotion.easeInOut.transform(_iv(t, 0.55, 0.8));
    final mood = introDone ? _mood.value : moodIntro;

    final flinchIntro = math.sin(math.pi * _iv(t, 0.55, 0.78));
    // Once the dome is down, new words no longer reach you.
    final flinch = math.max(flinchIntro, punch * (1 - landed));

    final double tear;
    if (!introDone) {
      tear = _iv(t, 0.7, 1);
    } else {
      tear = mood < -0.4 ? _ambient.value : 0;
    }

    final cs = Theme.of(context).brightness == Brightness.dark;
    return ReportSceneFrame(
      youIn: Curves.easeOutBack.transform(_iv(t, 0, 0.22)),
      themIn: Curves.easeOutBack.transform(_iv(t, 0.1, 0.32)),
      youMood: mood,
      themAnger: AppMotion.easeOut.transform(_iv(t, 0.26, 0.42)),
      bubble:
          Curves.easeOutBack.transform(_iv(t, 0.36, 0.52)) * (1 + 0.2 * punch),
      glyph: _reason,
      waves: _iv(t, 0.42, 0.56) * (_reduced ? 0.8 : 1),
      wavePhase: _reduced ? 0.45 : (_ambient.value * 3) % 1,
      flinch: _reduced ? 0 : flinch,
      tear: _reduced ? (mood < -0.4 ? 0.3 : 0) : tear,
      dome: _dome.value,
      envelope: _send.value,
      envelopeOn: _phase == _Phase.sending && !_reduced,
      celebrate: _celebrate.isAnimating ? _celebrate.value : 0,
      ambient: _ambient.value,
      rtl: Directionality.of(context) == TextDirection.rtl,
      youColor: AppColors.amber,
      themColor: TintedAvatar.tintFor(widget.subject.seed),
      ink: const Color(0xFF1B1F24),
      paper: const Color(0xFFFFF6EC),
      danger: AppColors.red,
      road: AppColors.border.withValues(alpha: cs ? 1 : 0.9),
    );
  }

  // ── Layout ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final name = widget.subject.name;
    final (title, body) = switch (_phase) {
      _Phase.intro ||
      _Phase.choose ||
      // Once a reason is picked the "what happened" prompt has done its job,
      // and its room goes to what pressing Send will do.
      _Phase.sending => (
        s.report_story_title(name),
        _reason == null ? s.report_story_body : s.report_send_note,
      ),
      _Phase.done => (s.report_done_title, s.report_done_body),
      _Phase.noMail => (
        s.report_no_mail_title,
        s.report_no_mail_body(SupportConfig.email),
      ),
    };
    final headlineKey = _phase == _Phase.done || _phase == _Phase.noMail
        ? _phase
        : _Phase.choose;

    return SheetShell(
      topFraction: 0.06,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              image: true,
              label: s.report_scene_label(name),
              child: ExcludeSemantics(
                child: AspectRatio(
                  aspectRatio:
                      ReportScenePainter.stage.width /
                      ReportScenePainter.stage.height,
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _scene,
                      builder: (context, _) => CustomPaint(
                        key: const Key('report-scene'),
                        painter: ReportScenePainter(_frame(context)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: AppMotion.sheet,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: HandOver.transition(),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: Column(
                key: ValueKey(headlineKey),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: AppMotion.card,
                    switchInCurve: AppMotion.easeOut,
                    switchOutCurve: AppMotion.leaving,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previous, ?current],
                    ),
                    child: Text(
                      body,
                      key: ValueKey(body),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13.5,
                        height: 1.55,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: AppMotion.sheet,
              curve: AppMotion.drawer,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: AppMotion.sheet,
                switchInCurve: AppMotion.easeOut,
                switchOutCurve: AppMotion.leaving,
                transitionBuilder: HandOver.transition(),
                child: _controls(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final s = context.getString;
    switch (_phase) {
      case _Phase.intro:
        return const SizedBox(key: ValueKey('intro'), height: 120);
      case _Phase.choose:
      case _Phase.sending:
        return Column(
          key: const ValueKey('choose'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            StaggeredEntrance(
              builder: (context, children) => Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: children,
              ),
              children: [
                for (final reason in ReportReason.values)
                  _ReasonChip(
                    key: Key('report-reason-${reason.name}'),
                    label: _reasonLabel(s, reason),
                    icon: _reasonIcon(reason),
                    selected: _reason == reason,
                    onTap: () => _pick(reason),
                  ),
              ],
            ),
            AnimatedSize(
              duration: AppMotion.sheet,
              curve: AppMotion.drawer,
              alignment: Alignment.topCenter,
              child: _reason == null
                  ? const SizedBox(width: double.infinity)
                  : _sendBlock(context),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('report-not-now'),
              onPressed: _phase == _Phase.sending
                  ? null
                  : () => Navigator.of(context).maybePop(),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                s.report_not_now,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      case _Phase.done:
        return Column(
          key: const ValueKey('done'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mute && widget.subject.canMute)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _Note(
                  icon: Icons.volume_off_rounded,
                  text: s.report_done_muted(widget.subject.name),
                ),
              ),
            _PrimaryButton(
              key: const Key('report-done'),
              label: s.report_done,
              icon: Icons.check_rounded,
              color: AppColors.green,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        );
      case _Phase.noMail:
        return Column(
          key: const ValueKey('no-mail'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: CopyChip(
                key: const Key('report-copy'),
                text: _mailText ?? SupportConfig.email,
                label: s.report_copy,
                copiedLabel: s.report_copied,
              ),
            ),
            const SizedBox(height: 14),
            _PrimaryButton(
              key: const Key('report-done'),
              label: s.report_done,
              icon: Icons.check_rounded,
              color: AppColors.amber,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        );
    }
  }

  Widget _sendBlock(BuildContext context) {
    final s = context.getString;
    final sending = _phase == _Phase.sending;
    return Padding(
      key: _sendKey,
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.subject.canMute) ...[
            _MuteToggle(
              label: s.report_mute_toggle(widget.subject.name),
              hint: s.report_mute_hint,
              value: _mute,
              onChanged: sending ? null : _toggleMute,
            ),
            const SizedBox(height: 12),
          ],
          _PrimaryButton(
            key: const Key('report-send'),
            label: s.report_send,
            icon: Icons.send_rounded,
            color: AppColors.red,
            onTap: sending ? null : _sendReport,
          ),
        ],
      ),
    );
  }
}

String _reasonLabel(AppLocalizations s, ReportReason reason) =>
    switch (reason) {
      ReportReason.insult => s.report_reason_insult,
      ReportReason.threat => s.report_reason_threat,
      ReportReason.profile => s.report_reason_profile,
      ReportReason.spam => s.report_reason_spam,
      ReportReason.other => s.report_reason_other,
    };

IconData _reasonIcon(ReportReason reason) => switch (reason) {
  ReportReason.insult => Icons.sentiment_very_dissatisfied_rounded,
  ReportReason.threat => Icons.bolt_rounded,
  ReportReason.profile => Icons.badge_outlined,
  ReportReason.spam => Icons.graphic_eq_rounded,
  ReportReason.other => Icons.more_horiz_rounded,
};

/// A reason, as a pill that lights up red and swaps its icon for a check.
class _ReasonChip extends StatelessWidget {
  const _ReasonChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? AppColors.red : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        scale: 0.94,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: AppMotion.chip,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.red.withValues(alpha: 0.16)
                : AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected
                  ? AppColors.red.withValues(alpha: 0.85)
                  : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: AppMotion.chip,
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: AppMotion.leaving,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Icon(
                  selected ? Icons.check_rounded : icon,
                  key: ValueKey(selected),
                  size: 17,
                  color: accent,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.textPrimary : accent,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MuteToggle extends StatelessWidget {
  const _MuteToggle({
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    toggled: value,
    label: label,
    excludeSemantics: true,
    child: PressableScale(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        key: const Key('report-mute-toggle'),
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: value
                ? AppColors.amber.withValues(alpha: 0.6)
                : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            _SpeakerIcon(muted: value),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.amber,
            ),
          ],
        ),
      ),
    ),
  );
}

/// A speaker that turns its back on the sound: the icon swaps with a quarter
/// turn and a pop, so muting reads as an action, not a repaint.
class _SpeakerIcon extends StatelessWidget {
  const _SpeakerIcon({required this.muted});

  final bool muted;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AppMotion.card,
    switchInCurve: Curves.easeOutBack,
    switchOutCurve: AppMotion.leaving,
    transitionBuilder: (child, animation) => AppMotion.reduced(context)
        ? FadeTransition(opacity: animation, child: child)
        : RotationTransition(
            turns: Tween(begin: -0.12, end: 0.0).animate(animation),
            child: ScaleTransition(scale: animation, child: child),
          ),
    child: Icon(
      muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      key: ValueKey(muted),
      color: muted ? AppColors.amber : AppColors.textSecondary,
      size: 24,
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    excludeSemantics: true,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedOpacity(
        duration: AppMotion.chip,
        opacity: onTap == null ? 0.55 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.24),
                blurRadius: 16,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 19, color: Colors.white),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(icon, size: 18, color: AppColors.amber),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

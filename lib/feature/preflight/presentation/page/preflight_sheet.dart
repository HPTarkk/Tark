import 'package:flutter/material.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/recovery/recovery_banner.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/domain/service/transport_advisor.dart';
import '../../service/preflight_result.dart';
import '../../service/preflight_service.dart';

/// Signature of [PreflightService.start] — a seam so tests can substitute a
/// fake session instead of a real probe/platform-channel run, the same way
/// [MicProbe.run]'s `resolveEngine` lets its own tests avoid the real engine.
typedef PreflightSessionStarter =
    PreflightSession Function({
      required AppLocalizations s,
      required ChannelPlan plan,
    });

/// Shows the full pre-ride Preflight sheet and waits for the user's answer.
///
/// Returns `true` the moment they choose to proceed ("Enter channel" once
/// everything's clear, "Continue anyway" if only warnings remain) and
/// `false` on cancel (drag-to-dismiss or back) — never while a hard failure
/// is still standing, since the CTA itself stays disabled until then.
Future<bool> showPreflightSheet(
  BuildContext context, {
  required ChannelPlan plan,
  PreflightSessionStarter startSession = PreflightService.start,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _PreflightSheet(plan: plan, startSession: startSession),
  );
  return result ?? false;
}

class _PreflightSheet extends StatefulWidget {
  const _PreflightSheet({required this.plan, required this.startSession});

  final ChannelPlan plan;
  final PreflightSessionStarter startSession;

  @override
  State<_PreflightSheet> createState() => _PreflightSheetState();
}

class _PreflightSheetState extends State<_PreflightSheet>
    with SingleTickerProviderStateMixin {
  PreflightSession? _session;
  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    // One controller drives every row's staggered entrance (see _PreflightRow)
    // — six independent controllers would each tick a frame callback for the
    // same single visual beat, which is the kind of per-row animation cost
    // the low-end-device floor can't absorb.
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not initState: resolving AppLocalizations depends on an inherited
    // widget, which the framework forbids before initState has returned.
    // Guarded so a later dependency change (a locale switch mid-sheet)
    // can't start a second, orphaned session.
    _session ??= widget.startSession(s: context.getString, plan: widget.plan);
  }

  @override
  void dispose() {
    // The session must not outlive this sheet: a cancelled Preflight leaving
    // its controller (and any in-flight retry closing over it) alive behind
    // the real channel is exactly the leak the issue's lifecycle section
    // warns against.
    _session?.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final session = _session!;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: SafeArea(
        top: false,
        child: StreamBuilder<PreflightResult>(
          stream: session.results,
          initialData: session.initial,
          builder: (context, snapshot) {
            final result = snapshot.data ?? session.initial;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 18),
                _Header(s: s, result: result),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
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
            );
          },
        ),
      ),
    );
  }
}

/// The six rows the sheet shows, in display order — see [PreflightResult]'s
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
    // 620ms sweep, not an independent animation — see _PreflightSheetState.
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

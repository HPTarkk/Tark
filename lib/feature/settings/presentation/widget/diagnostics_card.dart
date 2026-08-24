import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/diagnostics/build_provenance.dart';
import '../../../../core/diagnostics/diagnostic_log.dart';
import '../../../../core/diagnostics/diagnostics_bridge.dart';
import '../../../../core/diagnostics/log_budget.dart';
import '../../../../core/diagnostics/tark_log_format.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/ticker_text.dart';
import '../manager/settings_cubit.dart';
import 'settings_category_card.dart';
import 'settings_row.dart';

/// Settings → Advanced → Diagnostics: choose how much room the on-device log
/// may take, hand it back to us, or wipe it.
///
/// The reason this is a user-facing button rather than a debug-menu affair is
/// that the bugs it exists for cannot be reproduced anywhere else. A hotspot
/// session that goes one-way after a screen lock depends on two specific
/// phones, one specific OEM's power manager, and the order two OS callbacks
/// happened to fire in. The only honest way to see it is to read what that
/// phone recorded while it was happening.
///
/// The size control at the top exists because "we keep a log for you" is a
/// promise about someone else's storage. Showing the ceiling, showing how much
/// of it is spent, and letting it be moved is the difference between a feature
/// the user permits and one that just happens to them.
///
/// Hidden entirely where there is no share sheet to hand a file to (web,
/// desktop) — a row that cannot do its job is worse than no row.
class DiagnosticsCard extends StatefulWidget {
  const DiagnosticsCard({super.key});

  @override
  State<DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<DiagnosticsCard> {
  int _sizeBytes = 0;
  BuildProvenance? _build;

  /// Blocks a second tap while an export is being written and packed. On a
  /// long session this is a compress of a few hundred KB — quick, but not
  /// instant, and two of them racing would each prune the other's file.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshSize();
    _refreshBuild();
  }

  Future<void> _refreshSize() async {
    final size = await DiagnosticLog.sizeOnDisk();
    if (!mounted) return;
    setState(() => _sizeBytes = size);
  }

  Future<void> _refreshBuild() async {
    final build = await BuildProvenance.resolve();
    if (!mounted) return;
    setState(() => _build = build);
  }

  /// Persists the new ceiling, then re-reads the size — lowering it prunes,
  /// and a meter still showing the pre-prune number would read as a control
  /// that did nothing.
  Future<void> _applyMaxBytes(int bytes) async {
    final cubit = context.read<SettingsCubit>();
    await cubit.setLogMaxBytes(bytes);
    await _refreshSize();
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = context.getString;
    try {
      final path = await DiagnosticLog.export();
      if (!mounted) return;
      if (path == null) {
        _say(s.settings_log_empty);
        return;
      }
      final shared = await DiagnosticsBridge.shareFile(
        path: path,
        // Deliberately not a text type: the container is gzip + keystream (see
        // TarkLogFormat), and letting a mail client treat it as text is how a
        // binary attachment arrives mangled.
        mimeType: 'application/octet-stream',
        subject: 'Tark diagnostic log (.${TarkLogFormat.extension})',
      );
      if (!mounted) return;
      if (!shared) _say(s.settings_log_share_failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirmed before it runs: the log is the only copy of what a phone saw
  /// during a bug, and it cannot be recovered once wiped. The prompt is also
  /// the last place to remind someone to share it before it's gone.
  Future<void> _confirmClear() async {
    final s = context.getString;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.border),
        ),
        title: Text(
          s.settings_clear_log_confirm_title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          s.settings_clear_log_confirm_message,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              s.cancel,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.settings_clear_log_confirm_action,
              style: TextStyle(
                color: AppColors.red,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _clear();
  }

  Future<void> _clear() async {
    final s = context.getString;
    await DiagnosticLog.clear();
    if (!mounted) return;
    _say(s.settings_log_cleared);
    await _refreshSize();
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Rounded to whole units — the exact byte count answers nothing, and this
  /// number's only job is to tell someone whether it's worth sending over a
  /// mobile connection.
  String _humanSize(BuildContext context) => _sizeBytes <= 0
      ? context.getString.settings_log_empty
      : LogBudget.format(_sizeBytes).localized(context);

  @override
  Widget build(BuildContext context) {
    if (!DiagnosticsBridge.isSupported) return const SizedBox.shrink();
    final s = context.getString;
    final build = _build;
    return SettingsCategoryCard(
      icon: Icons.bug_report_rounded,
      title: s.settings_section_diagnostics,
      child: Column(
        children: [
          BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (p, c) => p.logMaxBytes != c.logMaxBytes,
            builder: (context, state) => _LogBudgetSection(
              usedBytes: _sizeBytes,
              maxBytes: state.logMaxBytes,
              onChanged: _applyMaxBytes,
            ),
          ),
          Divider(color: AppColors.border, height: 1),
          Semantics(
            label: build == null
                ? 'Build provenance loading'
                : 'Build ${build.version}, commit ${build.shortCommit}, '
                      '${build.channel}, ${build.dirtyLabel}',
            button: build != null,
            child: SettingsRow(
              icon: Icons.fingerprint_rounded,
              label: 'BUILD',
              subtitle: build == null
                  ? '…'
                  : '${build.version} • ${build.shortCommit} • ${build.channel}',
              trailing: build == null
                  ? null
                  : Text(
                      build.dirtyLabel.toUpperCase(),
                      style: TextStyle(
                        color: build.hasExactCommit
                            ? AppColors.textSecondary
                            : AppColors.amber,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
              onTap: build == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      Clipboard.setData(ClipboardData(text: build.diagnosticLine));
                      _say(build.shortCommit);
                    },
            ),
          ),
          Divider(color: AppColors.border, height: 1),
          SettingsRow(
            icon: Icons.ios_share_rounded,
            label: s.settings_share_log,
            subtitle: s.settings_share_log_desc(_humanSize(context)),
            trailing: _busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.amber,
                    ),
                  )
                : Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                  ),
            onTap: () {
              HapticFeedback.selectionClick();
              _share();
            },
          ),
          Divider(color: AppColors.border, height: 1),
          SettingsRow(
            icon: Icons.delete_outline_rounded,
            label: s.settings_clear_log,
            subtitle: s.settings_clear_log_desc,
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
            onTap: () {
              HapticFeedback.selectionClick();
              _confirmClear();
            },
          ),
        ],
      ),
    );
  }
}

/// The ceiling picker: how full the log is, and how big it's allowed to get.
///
/// The slider snaps to [LogBudget.steps] rather than sweeping a raw byte
/// range. Twenty kilobytes to a hundred megabytes is a factor of five
/// thousand, and on a linear track everything below a megabyte would share
/// the first pixel — the ladder gives every size its own detent and lands on
/// a round number every time.
class _LogBudgetSection extends StatefulWidget {
  final int usedBytes;
  final int maxBytes;
  final ValueChanged<int> onChanged;

  const _LogBudgetSection({
    required this.usedBytes,
    required this.maxBytes,
    required this.onChanged,
  });

  @override
  State<_LogBudgetSection> createState() => _LogBudgetSectionState();
}

class _LogBudgetSectionState extends State<_LogBudgetSection> {
  /// Where the thumb is while a drag is in flight.
  ///
  /// Committing per step would prune on the way past every detent — dragging
  /// from 100 MB down to 20 KB would delete almost everything before the
  /// finger even lifted, including whatever the user was about to think
  /// better of. The value is only written on release.
  int? _dragIndex;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final index = _dragIndex ?? LogBudget.stepIndexFor(widget.maxBytes);
    final selected = LogBudget.steps[index];
    final fraction = widget.usedBytes <= 0
        ? 0.0
        : (widget.usedBytes / selected).clamp(0.0, 1.0);
    // Rotation kicks in a little before the ceiling is literally touched (the
    // oldest segment goes as soon as the total would exceed it), so treat the
    // last few percent as "recycling" rather than waiting for a number that
    // by design never quite arrives.
    final recycling = fraction >= 0.95;
    final percent = (fraction * 100).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                s.settings_log_max_size,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: TickerText(
                  text: LogBudget.format(selected).localized(context),
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CapacityBar(fraction: fraction, full: recycling),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  s.settings_log_usage(
                    LogBudget.format(math.max(0, widget.usedBytes)).localized(
                      context,
                    ),
                    LogBudget.format(selected).localized(context),
                  ),
                  style: TextStyle(
                    color: AppColors.textSecondary.withAlpha(190),
                    fontSize: 11,
                  ),
                ),
              ),
              Text(
                '${percent.localized(context)}%',
                style: TextStyle(
                  color: recycling
                      ? AppColors.red
                      : AppColors.textSecondary.withAlpha(190),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: AppColors.amber,
              inactiveTrackColor: AppColors.border,
              thumbColor: AppColors.amber,
              overlayColor: AppColors.amber.withAlpha(40),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              value: index.toDouble(),
              min: 0,
              max: (LogBudget.steps.length - 1).toDouble(),
              divisions: LogBudget.steps.length - 1,
              onChanged: (v) => setState(() => _dragIndex = v.round()),
              onChangeEnd: (v) {
                HapticFeedback.selectionClick();
                setState(() => _dragIndex = null);
                widget.onChanged(LogBudget.steps[v.round()]);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                LogBudget.format(LogBudget.minBytes).localized(context),
                style: _hintStyle,
              ),
              Text(
                LogBudget.format(LogBudget.maxBytes).localized(context),
                style: _hintStyle,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                recycling
                    ? Icons.autorenew_rounded
                    : Icons.all_inclusive_rounded,
                size: 13,
                color: recycling
                    ? AppColors.amber
                    : AppColors.textSecondary.withAlpha(160),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  recycling
                      ? s.settings_log_recycling
                      : s.settings_log_max_size_desc,
                  style: TextStyle(
                    color: recycling
                        ? AppColors.amber.withAlpha(220)
                        : AppColors.textSecondary.withAlpha(180),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static TextStyle get _hintStyle => TextStyle(
    color: AppColors.textSecondary.withAlpha(160),
    fontSize: 10,
    letterSpacing: 1,
  );
}

/// How much of the ceiling is spent, as a filled track.
///
/// Fills from the leading edge, so it runs right-to-left in Persian along with
/// everything else on the page.
class _CapacityBar extends StatelessWidget {
  final double fraction;
  final bool full;

  const _CapacityBar({required this.fraction, required this.full});

  @override
  Widget build(BuildContext context) {
    final color = full ? AppColors.red : AppColors.amber;
    // A log with a few KB in it against a 100 MB ceiling is a fill of 0.006%.
    // Round that to nothing and the bar reads as broken rather than nearly
    // empty, so anything non-zero keeps a visible sliver.
    final width = fraction <= 0 ? 0.0 : math.max(fraction, 0.02);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: AppColors.border.withAlpha(150)),
            ),
            if (width > 0)
              // Animated on the way in and on every ceiling change: the bar
              // growing or springing back is the feedback that the slider did
              // something, and a fill that teleports reads as a repaint glitch.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: width.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: value,
                  child: child,
                ),
                // A gradient rather than a glow: the bar is clipped to its own
                // rounded rect, so a drop shadow would be cropped to nothing.
                // Brightening towards the growing tip gives the fill an edge to
                // read against the track instead.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.centerStart,
                      end: AlignmentDirectional.centerEnd,
                      colors: [color.withAlpha(130), color],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

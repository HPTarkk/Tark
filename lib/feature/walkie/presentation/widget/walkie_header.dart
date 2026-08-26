import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/widget/settings_icon_button.dart';
import '../../../../core/widget/tark_mark.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';

class WalkieHeader extends StatelessWidget {
  const WalkieHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.isReady != c.isReady || p.localId != c.localId,
      builder: (context, state) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
        ),
        child: Row(
          children: [
            const _BrandBadge(),
            const SizedBox(width: 10),
            Text(
              context.getString.app_name,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
            const Spacer(),
            // RepaintBoundary isolates the 60 fps pulse dot from the header.
            const RepaintBoundary(child: SignalIndicator()),
            const SizedBox(width: 8),
            const _RoomsButton(),
            const SizedBox(width: 4),
            const _SettingsButton(),
          ],
        ),
      ),
    );
  }
}

// ── Room / settings entry points ─────────────────────────────────────────────

/// Opens durable saved Rooms without touching the current transport. This is
/// deliberately available from inside a live session so Room management is no
/// longer hidden behind leaving/recreating the channel.
class _RoomsButton extends StatelessWidget {
  const _RoomsButton();

  @override
  Widget build(BuildContext context) {
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final label = fa ? 'اتاق‌های ذخیره‌شده' : 'Saved rooms';
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        key: const Key('walkie-saved-rooms'),
        tooltip: label,
        onPressed: () => context.pushNamed(AppRoutes.roomsName),
        icon: Icon(Icons.groups_2_outlined, color: AppColors.textSecondary),
      ),
    );
  }
}

/// Opens Settings with the running [WalkieTalkieCubit] threaded through
/// go_router's `extra`, so changes (VOX threshold, noise suppression, name)
/// apply live to this session instead of only taking effect next time.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    return SettingsIconButton(
      onTap: () => context.pushNamed(
        AppRoutes.settingsName,
        extra: context.read<WalkieTalkieCubit>(),
      ),
    );
  }
}

// ── Brand badge ───────────────────────────────────────────────────────────────

class _BrandBadge extends StatelessWidget {
  const _BrandBadge();

  @override
  Widget build(BuildContext context) {
    // Same staleness trap as _ScanlineBackground in VisualizerSection: this
    // build reads only static AppColors, so after the theme-change re-key
    // grafts the preserved element tree back, it would never repaint with
    // the new palette without listening to the theme directly.
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (_, _, _) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: AppColors.amber.withAlpha(30),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.amber.withAlpha(80), width: 1),
        ),
        child: TarkMark(
          size: 14,
          color: AppColors.amber,
          colorDim: AppColors.amberDim,
        ),
      ),
    );
  }
}

// ── Signal indicator ──────────────────────────────────────────────────────────

/// Pulsing LIVE / OFFLINE indicator in the header, carrying link quality.
///
/// The word stays LIVE or OFFLINE and the *bars* say how well the link is
/// actually carrying voice — deliberately, on both counts. Four states of
/// [LinkQuality] would need four more translated words for something the user
/// reads at a glance while riding, and the granular numbers behind the grade
/// belong in diagnostics rather than the header. A signal meter says "weak"
/// in every language.
///
/// Owns its own [AnimationController] so the pulse animation is isolated from
/// the rest of the page widget tree.
class SignalIndicator extends StatefulWidget {
  const SignalIndicator({super.key});

  @override
  State<SignalIndicator> createState() => _SignalIndicatorState();
}

class _SignalIndicatorState extends State<SignalIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isReady != c.isReady ||
          p.localId != c.localId ||
          p.linkQuality != c.linkQuality,
      builder: (context, state) {
        final isActive =
            state.isReady &&
            state.localId.isNotEmpty &&
            state.localId != '0.0.0.0';
        final quality = state.linkQuality;
        final accent = isActive
            ? _qualityColor(quality)
            : AppColors.textSecondary;
        final s = context.getString;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinkQualityBars(
              // An inactive session shows an empty meter rather than a grade:
              // there is no link to have an opinion about yet.
              filled: isActive ? LinkQualityBars.barsFor(quality) : 0,
              color: accent,
              pulse: _pulseAnimation,
            ),
            const SizedBox(width: 7),
            TickerText(
              text: isActive ? s.live : s.offline,
              duration: const Duration(milliseconds: 350),
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
          ],
        );
      },
    );
  }

  static Color _qualityColor(LinkQuality q) => switch (q) {
    // Green covers both healthy grades: the difference between four bars and
    // three is worth showing, but not worth a colour change that reads as a
    // warning for a link that is working.
    LinkQuality.excellent || LinkQuality.good => AppColors.green,
    LinkQuality.weak || LinkQuality.recovering => AppColors.amber,
  };
}

/// A four-bar signal meter.
///
/// Public so its mapping from grade to lit bars can be tested directly; the
/// header is the only thing that builds one. The tallest lit bar carries the
/// pulse, so the header keeps the "this session is alive" heartbeat the single
/// dot used to provide while also saying how good the link is.
///
/// Built from plain sized boxes on purpose — no shader, no clip, no blur, and
/// only the one animated child rebuilds per frame. This sits in the header of
/// the screen a rider leaves open for an hour, on hardware where a mask blur
/// is the difference between 60 fps and 40.
class LinkQualityBars extends StatelessWidget {
  const LinkQualityBars({
    super.key,
    required this.filled,
    required this.color,
    required this.pulse,
  });

  final int filled;
  final Color color;
  final Animation<double> pulse;

  /// Lit bars for a grade. Four steps for four grades, so the meter is full
  /// only when nothing at all is wrong.
  static int barsFor(LinkQuality q) => switch (q) {
    LinkQuality.excellent => 4,
    LinkQuality.good => 3,
    LinkQuality.weak => 2,
    LinkQuality.recovering => 1,
  };

  static const _count = 4;
  static const _heights = [4.0, 7.0, 10.0, 13.0];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 13,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _count; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            if (i == filled - 1)
              // Only the leading lit bar is inside the AnimatedBuilder, so a
              // frame of the pulse rebuilds one 3px box rather than the meter.
              AnimatedBuilder(
                animation: pulse,
                builder: (_, _) => _bar(
                  _heights[i],
                  color,
                  alpha: 255 - (pulse.value * 110).round(),
                ),
              )
            else
              _bar(
                _heights[i],
                color,
                // Unlit bars stay visible as a track, so the meter reads as a
                // meter at a glance instead of as a bar that changed length.
                alpha: i < filled ? 255 : 46,
              ),
          ],
        ],
      ),
    );
  }

  static Widget _bar(double height, Color color, {required int alpha}) =>
      Container(
        width: 3,
        height: height,
        decoration: BoxDecoration(
          color: color.withAlpha(alpha),
          borderRadius: BorderRadius.circular(1),
        ),
      );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/paywall_sheet.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/widget/settings_icon_button.dart';
import '../../../../core/widget/tark_mark.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../room/presentation/widget/in_room_invite_button.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// Width policy for the pinned Ride Mode header.
///
/// At narrow phone widths the decorative app title gives way before any live
/// control does. This keeps the always-visible mic action, connection state,
/// Add rider, Rooms and Settings inside the safe viewport without relying on a
/// horizontal scroll or shrinking tap targets below 40 logical pixels.
abstract final class WalkieHeaderLayout {
  static const compactBreakpoint = 390.0;

  static bool showAppTitle(double maxWidth) => maxWidth >= compactBreakpoint;
}

class WalkieHeader extends StatelessWidget {
  const WalkieHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.isReady != c.isReady || p.localId != c.localId,
      builder: (context, state) => LayoutBuilder(
        builder: (context, constraints) {
          final showTitle = WalkieHeaderLayout.showAppTitle(
            constraints.maxWidth,
          );
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                const _BrandBadge(),
                if (showTitle) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      context.getString.app_name,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: TextStyle(
                        color: AppColors.amber,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                const RepaintBoundary(child: SignalIndicator()),
                const SizedBox(width: 4),
                const _QuickMicButton(),
                const InRoomInviteButton(),
                const _RoomsButton(),
                const _SettingsButton(),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Primary ride action ──────────────────────────────────────────────────────

/// Compact always-visible mirror of the full MicControl card.
///
/// The detailed card remains in the scrollable body for explanation and state
/// copy, but Ride Mode must never require scrolling to mute/unmute. The Cubit
/// remains the single source of truth and keeps the same entitlement rule as
/// the full control: entering mute may be premium-gated, while unmuting is
/// always available so nobody can be stranded silent.
class _QuickMicButton extends StatelessWidget {
  const _QuickMicButton();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.isSelfMuted != c.isSelfMuted,
      builder: (context, state) {
        final muted = state.isSelfMuted;
        final s = context.getString;
        final label = muted ? s.mic_action_unmute : s.mic_action_mute;
        final accent = muted ? AppColors.red : AppColors.green;
        return Semantics(
          button: true,
          label: label,
          child: IconButton(
            key: const Key('walkie-primary-mic-toggle'),
            tooltip: label,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: () {
              if (!muted &&
                  !GetIt.instance<LicenseGate>().allows(
                    PremiumFeature.selfMute,
                  )) {
                showPaywallSheet(context, PremiumFeature.selfMute);
                return;
              }
              HapticFeedback.selectionClick();
              context.read<WalkieTalkieCubit>().toggleSelfMute();
            },
            icon: Icon(
              muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              color: accent,
            ),
          ),
        );
      },
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
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
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
    return SizedBox(
      width: 40,
      height: 40,
      child: SettingsIconButton(
        onTap: () => context.pushNamed(
          AppRoutes.settingsName,
          extra: context.read<WalkieTalkieCubit>(),
        ),
      ),
    );
  }
}

// ── Brand badge ───────────────────────────────────────────────────────────────

class _BrandBadge extends StatelessWidget {
  const _BrandBadge();

  @override
  Widget build(BuildContext context) {
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

/// State-driven LIVE / OFFLINE indicator in the header, carrying link quality.
///
/// Ride Mode deliberately avoids a continuously repeating decorative pulse.
/// The connection state already changes from transport evidence, so repainting
/// at animation-frame cadence adds distraction and long-session work without
/// conveying new information. Actual state transitions still rebuild through
/// the surrounding BlocBuilder and the text keeps its bounded transition.
class SignalIndicator extends StatelessWidget {
  const SignalIndicator({super.key});

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
              filled: isActive ? LinkQualityBars.barsFor(quality) : 0,
              color: accent,
            ),
            const SizedBox(width: 5),
            TickerText(
              text: isActive ? s.live : s.offline,
              duration: const Duration(milliseconds: 350),
              style: TextStyle(
                color: accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        );
      },
    );
  }

  static Color _qualityColor(LinkQuality q) => switch (q) {
    LinkQuality.excellent || LinkQuality.good => AppColors.green,
    LinkQuality.weak || LinkQuality.recovering => AppColors.amber,
  };
}

/// A four-bar signal meter. Bars are static between real transport-state
/// changes so the header does not schedule continuous ride-session frames.
class LinkQualityBars extends StatelessWidget {
  const LinkQualityBars({super.key, required this.filled, required this.color});

  final int filled;
  final Color color;

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
            _bar(_heights[i], color, alpha: i < filled ? 255 : 46),
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

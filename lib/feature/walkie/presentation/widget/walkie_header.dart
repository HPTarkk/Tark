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
import '../../../room/domain/repository/room_repository.dart';
import '../../../room/presentation/widget/in_room_invite_button.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';
import '../model/ride_room_identity.dart';

/// Width policy for the pinned Ride Mode header.
///
/// The header used to end in four square icon buttons in a row, each carrying
/// `IconButton`'s own 8px of internal padding on top of the bar's 12 — so the
/// last glyph floated well inside the edge the brand badge sat flush against,
/// and none of them said what they were. It is now two rows with one job each:
/// identity and the way out on top, live controls underneath.
///
/// Below [compactBreakpoint] the People pill drops its word and keeps its
/// count, because the count is the information and the word is the label.
abstract final class WalkieHeaderLayout {
  static const compactBreakpoint = 390.0;

  static bool showAppTitle(double maxWidth) => maxWidth >= compactBreakpoint;

  static bool compactPeople(double maxWidth) => maxWidth < compactBreakpoint;

  /// The single vertical line every visible edge on this screen sits on —
  /// the same 16 the body's cards use, so the header reads as the top of one
  /// column rather than a bar with a margin of its own.
  static const opticalMargin = 16.0;

  /// `IconButton` draws its 24px glyph inside 8px of hit-target padding.
  static const iconButtonInset = 8.0;

  /// `SettingsIconButton` insets its amber chip by 4 to reach its tap target.
  static const settingsChipInset = 4.0;

  /// The bar's own padding for an edge whose control already carries
  /// [controlInset] of internal padding.
  ///
  /// Hit-target padding is invisible, so it has to be subtracted rather than
  /// added to: leave it in and the control's *drawn* edge floats inward by
  /// exactly that much. Equal numbers on both sides are what left the end of
  /// each row looking abandoned — a settings chip 8 from the edge above a mic
  /// glyph 20 from it, over cards starting at 16.
  static double inset(double controlInset) =>
      (opticalMargin - controlInset).clamp(0.0, opticalMargin);
}

class WalkieHeader extends StatelessWidget {
  const WalkieHeader({super.key, this.onLeave});

  /// Invoked by the header's back control. Null falls back to the route's own
  /// pop, which `WalkieTalkiePage`'s `PopScope` turns into the same
  /// confirmation the on-screen Leave action uses.
  final VoidCallback? onLeave;

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
            // Vertical padding only. The rows below set their own horizontal
            // inset so a bare glyph and a pill can both sit on the same
            // optical margin instead of one being pushed in by its own
            // hit-target padding.
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 1),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    // The leave chevron is an IconButton, the settings control
                    // an inset chip — different padding, so different numbers
                    // to land both on the same margin.
                    start: WalkieHeaderLayout.inset(
                      WalkieHeaderLayout.iconButtonInset,
                    ),
                    end: WalkieHeaderLayout.inset(
                      WalkieHeaderLayout.settingsChipInset,
                    ),
                  ),
                  child: Row(
                    children: [
                      _LeaveButton(onLeave: onLeave),
                      const SizedBox(width: 2),
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
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 3,
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      const RepaintBoundary(child: SignalIndicator()),
                      const SizedBox(width: 6),
                      const _SettingsButton(),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsetsDirectional.only(
                    // The room identity line starts with a bare icon and owns
                    // no padding, so it sits on the margin itself.
                    start: WalkieHeaderLayout.inset(0),
                    top: 6,
                    end: WalkieHeaderLayout.inset(
                      WalkieHeaderLayout.iconButtonInset,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Expanded(child: _SelectedRoomIdentityLine()),
                      const SizedBox(width: 8),
                      InRoomInviteButton(
                        compact: WalkieHeaderLayout.compactPeople(
                          constraints.maxWidth,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const _RoomsButton(),
                      const SizedBox(width: 6),
                      const _QuickMicButton(),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The way back out of a live channel.
///
/// Its absence was the single most disorienting thing about this screen: the
/// channel is often the only route on the stack, so there was no system back
/// either, and the only exit was a Leave control below the fold. It is drawn
/// as a plain chevron rather than a destructive-looking control because the
/// confirmation behind it is what makes leaving deliberate — the affordance
/// itself only has to be findable.
class _LeaveButton extends StatelessWidget {
  const _LeaveButton({required this.onLeave});

  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final label = fa ? 'خروج از اتاق' : 'Leave the room';
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        key: const Key('walkie-leave'),
        tooltip: label,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        onPressed: () {
          HapticFeedback.selectionClick();
          final leave = onLeave;
          if (leave != null) {
            leave();
          } else {
            // Routed through the page's PopScope, which is the one place that
            // knows leaving needs confirming.
            Navigator.of(context).maybePop();
          }
        },
        icon: Icon(Icons.arrow_back_rounded, color: AppColors.textSecondary),
      ),
    );
  }
}

/// Loads the durable selected Room exactly once for this live Ride surface.
///
/// A user may browse/select another saved Room while the current call is still
/// running; that must not silently relabel the already-running session. A new
/// WalkieTalkiePage gets a fresh header and resolves the then-selected Room.
class _SelectedRoomIdentityLine extends StatefulWidget {
  const _SelectedRoomIdentityLine();

  @override
  State<_SelectedRoomIdentityLine> createState() =>
      _SelectedRoomIdentityLineState();
}

class _SelectedRoomIdentityLineState extends State<_SelectedRoomIdentityLine> {
  late final Future<RideRoomIdentity?> _identity;

  @override
  void initState() {
    super.initState();
    _identity = RideRoomIdentityResolver(GetIt.instance<RoomRepository>())
        .load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RideRoomIdentity?>(
      future: _identity,
      builder: (context, snapshot) {
        final identity = snapshot.data;
        if (identity == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: RideRoomIdentityBadge(identity: identity),
        );
      },
    );
  }
}

/// Compact durable Room identity for the primary Ride hierarchy.
///
/// The code is a stable display-only prefix of RoomId. It is never used as an
/// authorization or transport identity and remains visually LTR in Persian.
class RideRoomIdentityBadge extends StatelessWidget {
  const RideRoomIdentityBadge({super.key, required this.identity});

  final RideRoomIdentity identity;

  @override
  Widget build(BuildContext context) {
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final semantics = fa
        ? 'اتاق ${identity.name}، کد ${identity.code}'
        : 'Room ${identity.name}, code ${identity.code}';

    return Semantics(
      container: true,
      label: semantics,
      excludeSemantics: true,
      child: Row(
        key: const Key('ride-room-identity'),
        children: [
          Icon(Icons.meeting_room_outlined, size: 16, color: AppColors.amber),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              identity.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              '#${identity.code}',
              maxLines: 1,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: .5,
              ),
            ),
          ),
        ],
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
        // A channel with nobody on it is not LIVE, whatever the socket thinks.
        // Saying LIVE here while both phones sat alone on different transports
        // is what turned a five-second "he isn't in yet" into a bug report.
        final alone = isActive && quality == LinkQuality.alone;
        final accent = !isActive
            ? AppColors.textSecondary
            : _qualityColor(quality);
        final fa = Localizations.localeOf(context).languageCode == 'fa';
        final s = context.getString;
        return Semantics(
          liveRegion: true,
          label: alone
              ? (fa ? 'تنها در اتاق' : 'Alone in the room')
              : (isActive ? s.live : s.offline),
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinkQualityBars(
                filled: isActive ? LinkQualityBars.barsFor(quality) : 0,
                color: accent,
              ),
              const SizedBox(width: 5),
              TickerText(
                text: alone
                    ? (fa ? 'تنها' : 'ALONE')
                    : isActive
                    ? s.live
                    : s.offline,
                duration: const Duration(milliseconds: 350),
                style: TextStyle(
                  color: accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Color _qualityColor(LinkQuality q) => switch (q) {
    LinkQuality.excellent || LinkQuality.good => AppColors.green,
    LinkQuality.weak || LinkQuality.recovering => AppColors.amber,
    // Not red — nothing has failed, there is simply nobody there yet — and
    // never green, which is the whole point.
    LinkQuality.alone => AppColors.textSecondary,
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
    // An empty meter, because there is no link to measure. A bar here would
    // be the interface inventing a connection.
    LinkQuality.alone => 0,
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

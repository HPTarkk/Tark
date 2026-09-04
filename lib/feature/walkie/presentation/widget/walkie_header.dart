import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/widget/settings_icon_button.dart';
import '../../../../core/widget/tark_mark.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../room/domain/repository/room_repository.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';
import '../model/ride_room_identity.dart';

/// Width policy for the pinned Ride Mode header.
///
/// The header used to end in four square icon buttons in a row, each carrying
/// `IconButton`'s own 8px of internal padding on top of the bar's 12 — so the
/// last glyph floated well inside the edge the brand badge sat flush against,
/// and none of them said what they were.
///
/// It is now **one identity block and one control cluster**, side by side. The
/// mark leads, and beside it the wordmark sits over the room this phone is in:
/// two lines that are the same fact at two scopes, which is why they share a
/// mark rather than each getting a row. Everything that is not identity —
/// the link, and settings — sits at the trailing edge.
///
/// R28 built the same idea out of two stacked rows and indented the second one
/// by [brandMark] + [brandGap] so it would line up under the wordmark. That is
/// alignment by arithmetic: it was correct, and it was one constant away from
/// silently drifting the moment the mark changed size — which R31 then did.
/// The room line is a sibling of the wordmark inside one column now, so the two
/// cannot come apart, and the mark is free to grow to carry both.
///
/// Three controls were removed in R28, each because the screen already had it
/// somewhere better. **The back chevron** was added when the only other exit
/// was a Leave control that scrolled away with the body; that Leave button is
/// pinned below the scroll view now, and the system back gesture already routes
/// through the same confirmation, so the chevron was a third door onto a screen
/// with two. **The mute toggle** mirrored `MicControl`, which sits in the body
/// above the fold and is the control this screen is built around — two live
/// mute affordances is one more than a gloved hand can press. **Saved rooms**
/// was the odd one: you do not change rooms while you are in one.
///
/// **The People pill left in R32.** Adding someone to a room you are already
/// riding in is not an everyday act, and it was holding the trailing edge of
/// the screen a rider looks at for the whole trip. It has a designed home in
/// the members card now, where the question it answers is already being asked
/// — and where it can be the lit control on a channel with nobody else on it,
/// which a header pill could never be.
abstract final class WalkieHeaderLayout {
  /// The single vertical line every visible edge on this screen sits on —
  /// the same 16 the body's cards use, so the header reads as the top of one
  /// column rather than a bar with a margin of its own.
  static const opticalMargin = 16.0;

  /// `IconButton` draws its 24px glyph inside 8px of hit-target padding.
  static const iconButtonInset = 8.0;

  /// `SettingsIconButton` insets its amber chip by 4 to reach its tap target.
  static const settingsChipInset = 4.0;

  /// The brand mark, and the gap after it.
  ///
  /// Grown from the 28 it was when it stood beside a single line. It now has
  /// to hold a two-line block up, and a mark shorter than the text beside it
  /// reads as decoration on a title rather than the head of one.
  static const brandMark = 38.0;
  static const brandGap = 10.0;

  /// The glyph inside the mark, at the proportion it was drawn at when the
  /// mark was 28. Derived rather than restated so the two cannot drift.
  static const brandGlyph = brandMark * 0.5;

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
  const WalkieHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.isReady != c.isReady || p.localId != c.localId,
      builder: (context, state) => Container(
        padding: EdgeInsetsDirectional.fromSTEB(
          // The mark owns no padding of its own, so it sits on the margin
          // itself; the settings control is an inset chip.
          WalkieHeaderLayout.inset(0),
          8,
          WalkieHeaderLayout.inset(WalkieHeaderLayout.settingsChipInset),
          8,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
        ),
        child: const _Identity(),
      ),
    );
  }
}

/// The mark, and beside it what this session is: the app, then the room.
///
/// A column rather than two indented rows, so the wordmark and the room name
/// share one left edge structurally instead of by arithmetic. Nothing taller
/// than the text is allowed inside that column, which buys two things at once:
/// the mark is centred on the text pair exactly rather than approximately, and
/// the gap between the two lines is the leading and nothing else.
///
/// **That is why both controls sit outside it.** A 40pt settings chip on the
/// wordmark's line sets that line's height on its own, and every pixel of the
/// difference between the chip and the text turns into space under the
/// wordmark — the gap grows by exactly what the chip adds. Keeping the link
/// indicator in the column and the chip out of it looked right in isolation
/// and was worse than either: the two controls then sat on different lines,
/// eleven pixels apart, at the one edge of the screen where the eye expects a
/// row.
///
/// So they are one cluster, centred on the block, and the room line is the
/// thing that gives way — which [RideRoomIdentityBadge] is built to do in the
/// right order.
class _Identity extends StatelessWidget {
  const _Identity();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _BrandBadge(),
        const SizedBox(width: WalkieHeaderLayout.brandGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.getString.app_name,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  // Trimmed to the glyphs. At the font's own leading the
                  // wordmark carries four invisible pixels under it, and the
                  // room line reads as a separate row rather than the second
                  // half of one thing.
                  height: 1,
                ),
              ),
              const _SelectedRoomIdentityLine(),
            ],
          ),
        ),
        const SizedBox(width: 10),
        const RepaintBoundary(child: SignalIndicator()),
        const SizedBox(width: 8),
        const _SettingsButton(),
      ],
    );
  }
}

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
    _identity = RideRoomIdentityResolver(
      GetIt.instance<RoomRepository>(),
    ).load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RideRoomIdentity?>(
      future: _identity,
      builder: (context, snapshot) {
        final identity = snapshot.data;
        if (identity == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: RideRoomIdentityBadge(identity: identity),
        );
      },
    );
  }
}

/// The room this phone is in, written as the wordmark's subtitle.
///
/// The code is a stable display-only prefix of RoomId. It is never used as an
/// authorization or transport identity and stays visually LTR in Persian: a
/// value that gets read out digit by digit, or typed, must not be reordered by
/// the paragraph direction.
///
/// Name and code used to sit at opposite ends of a full-width row, which made
/// them read as two unrelated facts and left the code hard against a control.
/// They are one phrase now, joined by a dot — the name is what you recognise
/// the room by, the code is what you read out to someone joining, and they are
/// the same answer to the same question.
///
/// ## Which half gives way
///
/// The code is the half that must survive: mid-ride it is what you say out
/// loud to get somebody in, and a truncated one is worse than none. So the
/// name gives way first, and completely if it has to.
///
/// A `Flexible` name beside a fixed code says that, and only while there is
/// room for the code at all — past that the row overflows and paints outside
/// its box with nothing on screen to say so. `Row` cannot express the rest,
/// because flex shares are decided before anyone is measured: two flexible
/// children split the space by ratio whatever they actually need, so any
/// weighting that saves the code at 320 also starves the name at 430.
///
/// Measuring the code is the whole fix. It is one short string in a known
/// style, the name gets exactly what is left over, and when even the code
/// cannot fit the name is dropped outright rather than both being squeezed.
class RideRoomIdentityBadge extends StatelessWidget {
  const RideRoomIdentityBadge({super.key, required this.identity});

  final RideRoomIdentity identity;

  /// The dot and the air either side of it.
  static const _joinWidth = 7.0 + 3.5 + 7.0;

  @override
  Widget build(BuildContext context) {
    final semantics = context.getString.header_room_semantics(
      identity.name,
      identity.code,
    );
    final codeStyle = TextStyle(
      color: AppColors.textSecondary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: .5,
    );

    return Semantics(
      container: true,
      label: semantics,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final code = '#${identity.code}';
          final codeWidth = _measure(context, code, codeStyle);
          final forName = constraints.maxWidth - _joinWidth - codeWidth;
          return Row(
            key: const Key('ride-room-identity'),
            children: [
              // Zero when the code has taken everything, which renders the
              // name away rather than letting the two fight over pixels that
              // do not exist.
              if (forName > 0)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: forName),
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
              if (forName > 0) ...[
                const SizedBox(width: 7),
                _Separator(),
                const SizedBox(width: 7),
              ],
              // Flexible only for the case the measurement says is already
              // lost: a code wider than the whole line ellipsizes instead of
              // painting over the controls beside it.
              Flexible(
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: codeStyle,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// What [text] will actually occupy, at this phone's text scale.
  static double _measure(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

/// The dot between the room's name and its code.
///
/// Small enough to be punctuation rather than a bullet: it says the two halves
/// belong to one phrase, which a gap alone does not, and a slash or a pipe
/// would say they are alternatives.
class _Separator extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 3.5,
    height: 3.5,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: AppColors.textSecondary.withValues(alpha: 0.75),
    ),
  );
}

// ── Room / settings entry points ─────────────────────────────────────────────

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
        width: WalkieHeaderLayout.brandMark,
        height: WalkieHeaderLayout.brandMark,
        decoration: BoxDecoration(
          color: AppColors.amber.withAlpha(30),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.amber.withAlpha(80), width: 1),
        ),
        child: TarkMark(
          size: WalkieHeaderLayout.brandGlyph,
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
        final s = context.getString;
        return Semantics(
          liveRegion: true,
          label: alone
              ? context.getString.header_alone_in_room
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
                    ? context.getString.header_alone
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

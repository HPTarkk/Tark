import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/profile/avatar_catalog.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/language_toggle.dart';
import '../../../../core/widget/theme_toggle.dart';
import '../manager/onboarding_cubit.dart';
import 'connection_choice.dart';

/// The lines each movement puts on stage, as flat lists so [StepSwap] can
/// hand them over one line at a time.
///
/// Everything is centred under the beacon: the journey is one composition
/// around one object, not a form.
abstract final class OnboardingMovements {
  /// The page's side margin. Lines are inset by it themselves (see [inset])
  /// rather than by the scroll view, so a line that wants to run edge to
  /// edge — the face strip — can.
  static const double margin = 24;

  /// Insets [line] by the side margin, unless it runs edge to edge.
  static Widget inset(Widget line) => line is AvatarStrip
      ? line
      : Padding(
          padding: const EdgeInsets.symmetric(horizontal: margin),
          child: line,
        );

  /// Hello: what this is, in the website's own words, and the two settings
  /// worth choosing before anything else — applied live, through the same
  /// controls (and the same circular reveal) Settings uses.
  static List<Widget> hello(BuildContext context) {
    final s = context.getString;
    return [
      _Kicker(s.onbx_kicker),
      const SizedBox(height: 10),
      _Title(s.onbx_hello_title),
      const SizedBox(height: 10),
      _Body(s.onboarding_welcome_sub),
      const SizedBox(height: 26),
      const LanguageToggle(),
      const SizedBox(height: 12),
      const ThemeToggle(),
    ];
  }

  /// You: a callsign and a face, on one screen.
  static List<Widget> identity(
    BuildContext context, {
    required VoidCallback onSubmit,
  }) {
    final s = context.getString;
    return [
      _Title(s.onbx_you_title),
      const SizedBox(height: 8),
      _Body(s.onboarding_callsign_help),
      const SizedBox(height: 20),
      CallsignField(onSubmit: onSubmit),
      const SizedBox(height: 22),
      _Kicker(s.onboarding_avatar_title),
      const SizedBox(height: 10),
      const AvatarStrip(),
    ];
  }

  /// Your room: the hand-off into the product. The actions themselves live
  /// in the page's action zone; this is what sits under the formation.
  static List<Widget> room(BuildContext context, {required bool replay}) {
    final s = context.getString;
    final state = context.read<OnboardingCubit>().state;
    final name = state.name.trim();
    return [
      if (name.isNotEmpty) ...[
        _Kicker(s.onbx_room_kicker(name)),
        const SizedBox(height: 10),
      ],
      _Title(replay ? s.onboarding_ready_title : s.onbx_room_title),
      const SizedBox(height: 8),
      _Body(replay ? s.onboarding_tip_settings : s.onbx_room_sub),
      const SizedBox(height: 16),
      Center(
        child: BlocBuilder<OnboardingCubit, OnboardingState>(
          buildWhen: (p, c) => p.mode != c.mode,
          builder: (context, state) => ConnectionChip(
            key: const Key('onboarding-connection'),
            mode: state.effectiveMode,
            onChanged: context.read<OnboardingCubit>().selectMode,
          ),
        ),
      ),
    ];
  }
}

class _Kicker extends StatelessWidget {
  const _Kicker(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    return Text(
      isFa ? text : text.toUpperCase(),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppColors.amber,
        fontSize: isFa ? 13 : 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: isFa ? 0 : 1.8,
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: AppColors.textPrimary,
      fontSize: 27,
      height: 1.3,
      fontWeight: FontWeight.w900,
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: AppColors.textSecondary,
      fontSize: 13.5,
      height: 1.65,
    ),
  );
}

/// The callsign, typed straight into a large centred field — the same field
/// shape the room creation screen uses for a Room's name — with a dice key
/// that rolls a radio handle for anyone who would rather not choose.
class CallsignField extends StatefulWidget {
  const CallsignField({required this.onSubmit, super.key});

  /// Keyboard "done" with a valid name — moves the journey on.
  final VoidCallback onSubmit;

  @override
  State<CallsignField> createState() => _CallsignFieldState();
}

class _CallsignFieldState extends State<CallsignField> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<OnboardingCubit>().state.name,
  );
  final _rng = Random();
  int _rolls = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Rolls a radio handle from a localized pool plus a two-digit unit number
  /// (Persian digits under fa, so no bidi reordering inside the name).
  void _shuffle() {
    final pool = context.getString.onboarding_callsign_pool.split(',');
    final word = pool[_rng.nextInt(pool.length)].trim();
    final number = (10 + _rng.nextInt(90)).localized(context);
    final name = '$word$number';
    Sfx.play(SfxEvent.toggle);
    HapticFeedback.selectionClick();
    _controller.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
    context.read<OnboardingCubit>().setName(name);
    setState(() => _rolls++);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final radius = BorderRadius.circular(20);
    return BlocListener<OnboardingCubit, OnboardingState>(
      listenWhen: (p, c) => p.name != c.name && c.name != _controller.text,
      listener: (_, state) => _controller.text = state.name,
      child: TextField(
        key: const Key('onboarding-callsign-field'),
        controller: _controller,
        textAlign: TextAlign.center,
        maxLength: OnboardingCubit.nameMaxLength,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.words,
        onChanged: context.read<OnboardingCubit>().setName,
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) widget.onSubmit();
        },
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
        decoration: InputDecoration(
          hintText: s.name_hint,
          hintStyle: TextStyle(
            color: AppColors.textSecondary.withValues(alpha: 0.7),
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          filled: true,
          fillColor: AppColors.card,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
          // Balances the dice key so the typed name sits truly centred.
          prefixIcon: const SizedBox(width: 52),
          suffixIcon: Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: IconButton(
              key: const Key('onboarding-shuffle'),
              tooltip: s.onbx_shuffle,
              onPressed: _shuffle,
              icon: AnimatedRotation(
                // A full tumble per roll — the die is thrown, not swapped.
                turns: _rolls.toDouble(),
                duration: AppMotion.reduced(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 520),
                curve: AppMotion.easeOut,
                child: Icon(Icons.casino_rounded, color: AppColors.amber),
              ),
            ),
          ),
          border: OutlineInputBorder(borderRadius: radius),
          enabledBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: AppColors.amber, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// Every face in one swipeable row. The pick lands in the beacon above, so
/// the row itself only has to say which one is chosen.
class AvatarStrip extends StatefulWidget {
  const AvatarStrip({super.key});

  @override
  State<AvatarStrip> createState() => _AvatarStripState();
}

class _AvatarStripState extends State<AvatarStrip> {
  static const _size = 54.0;
  static const _gap = 12.0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _offsetFor(
      context.read<OnboardingCubit>().state.avatarId,
    ),
  );

  /// Opens with the current pick in view (a replay may start on the 15th).
  static double _offsetFor(int? id) {
    final index = AvatarCatalog.all.indexWhere((a) => a.id == id);
    if (index <= 2) return 0;
    return (index - 2) * (_size + _gap) + OnboardingMovements.margin;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      buildWhen: (p, c) => p.avatarId != c.avatarId,
      // Runs edge to edge (the page's side margin is padding *inside* the
      // list), so the row reads as a strip you can swipe rather than a box the
      // faces are cut off inside — and every face, even one peeking in at the
      // edge, is a real target.
      builder: (context, state) => SizedBox(
        height: _size + 8,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: OnboardingMovements.margin,
            vertical: 4,
          ),
          itemCount: AvatarCatalog.all.length,
          separatorBuilder: (_, _) => const SizedBox(width: _gap),
          itemBuilder: (context, i) {
            final avatar = AvatarCatalog.all[i];
            return _AvatarChoice(
              key: ValueKey('avatar-${avatar.id}'),
              id: avatar.id,
              size: _size,
              selected: avatar.id == state.avatarId,
              onTap: () {
                Sfx.play(SfxEvent.toggle);
                context.read<OnboardingCubit>().selectAvatar(avatar.id);
              },
            );
          },
        ),
      ),
    );
  }
}

class _AvatarChoice extends StatelessWidget {
  const _AvatarChoice({
    required this.id,
    required this.size,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final int id;
  final double size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: PressableScale(
        onTap: onTap,
        scale: 0.94,
        child: AnimatedContainer(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          width: size,
          height: size,
          padding: EdgeInsets.all(selected ? 3 : 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? AppColors.amber : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: AnimatedOpacity(
            duration: AppMotion.card,
            opacity: selected ? 1 : 0.72,
            child: AvatarPicture(avatarId: id, size: size - 6),
          ),
        ),
      ),
    );
  }
}

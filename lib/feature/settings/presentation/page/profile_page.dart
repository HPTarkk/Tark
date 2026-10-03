import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/entitlement/subscription_service.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/avatar_picker_grid.dart';
import '../../../../core/widget/localized_counter.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/account_section.dart';

/// The person's profile: one card with their face and radio name, both
/// editable in place (faces in a sideways row), and — on builds with
/// sign-in — the account right under it, in view without scrolling.
///
/// Like Advanced settings, [buildPage] takes the running [WalkieTalkieCubit]
/// (if any) through go_router's `extra`, so a change made mid-channel reaches
/// the people in it at once instead of at the next channel.
class ProfilePage extends StatelessWidget {
  const ProfilePage._();

  static Widget buildPage({Object? liveSession}) => BlocProvider<SettingsCubit>(
    create: (_) => SettingsCubit(
      liveSession: liveSession as WalkieTalkieCubit?,
      repository: GetIt.instance<SettingsRepository>(),
    ),
    child: const ProfilePage._(),
  );

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: Text(
            s.profile_title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: StaggeredEntrance(
              children: [
                const _IdentityCard(),
                if (AccountSection.visible) const AccountSection(),
              ],
              builder: (context, cards) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: cards,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who this person is to everyone else: the face in a glowing ring beside
/// the editable name (and a PREMIUM badge while a subscription runs), then
/// the faces to choose from in one row. Compact on purpose, so the account
/// card below stays in view.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final amber = AppColors.amber;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    TextStyle label() => TextStyle(
      color: AppColors.textSecondary,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      // Persian is a joined script: spacing its letters pulls every word
      // apart.
      letterSpacing: rtl ? 0 : 1.6,
    );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [
            Color.alphaBlend(amber.withValues(alpha: 0.08), AppColors.card),
            AppColors.card,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: amber.withAlpha(14),
            blurRadius: 26,
            spreadRadius: -6,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 18, 16, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Face(),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.profile_name_label, style: label()),
                      const SizedBox(height: 6),
                      const _NameField(),
                      const _PremiumBadge(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.border, height: 1),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 8),
            child: Text(s.profile_avatar_label, style: label()),
          ),
          BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (p, c) => p.myAvatarId != c.myAvatarId,
            builder: (context, state) => AvatarPickerStrip(
              selectedId: state.myAvatarId,
              accent: amber,
              idleRing: AppColors.border,
              onSelected: context.read<SettingsCubit>().setMyAvatarId,
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// The chosen face in a glowing ring; swaps with a small pop when a new one
/// is picked.
class _Face extends StatelessWidget {
  const _Face();

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final amber = AppColors.amber;
    return BlocBuilder<SettingsCubit, SettingsState>(
      buildWhen: (p, c) => p.myAvatarId != c.myAvatarId || p.myName != c.myName,
      builder: (context, state) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: amber.withValues(alpha: 0.6), width: 2),
          boxShadow: [
            BoxShadow(
              color: amber.withValues(alpha: 0.22),
              blurRadius: 20,
              spreadRadius: 1,
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: reduced ? Duration.zero : AppMotion.sheet,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: AppAvatar(
            key: ValueKey(state.myAvatarId),
            name: state.myName,
            avatarId: state.myAvatarId,
            size: _faceSize,
          ),
        ),
      ),
    );
  }
}

/// The face's size in the identity card.
const double _faceSize = 76;

/// PREMIUM under the name while a subscription runs; nothing otherwise, or
/// on builds that sell nothing. Follows the subscription as it changes.
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) {
    if (!GetIt.instance.isRegistered<SubscriptionService>()) {
      return const SizedBox.shrink();
    }
    final subscription = GetIt.instance<SubscriptionService>();
    return StreamBuilder<void>(
      stream: subscription.changes,
      builder: (context, _) {
        final active = subscription.isPremiumActive;
        final amber = AppColors.amber;
        return AnimatedSize(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: !active
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    key: const ValueKey('profile-premium'),
                    padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 10, 4),
                    decoration: BoxDecoration(
                      color: amber.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: amber.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star_rounded, size: 14, color: amber),
                        const SizedBox(width: 4),
                        Text(
                          context.getString.mysub_premium,
                          style: TextStyle(
                            color: amber,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing:
                                Directionality.of(context) == TextDirection.rtl
                                ? 0
                                : 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// The radio name, edited in place. Saved on "done" and when the field loses
/// focus (leaving the page included), and never saved blank.
class _NameField extends StatefulWidget {
  const _NameField();

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final SettingsCubit _cubit = context.read<SettingsCubit>();

  @override
  void initState() {
    super.initState();
    _controller.text = _cubit.state.myName;
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      // Put the saved name back rather than leave a blank field that looks
      // as though it took.
      _controller.text = _cubit.state.myName;
      return;
    }
    if (value != _cubit.state.myName) _cubit.setMyName(value);
  }

  @override
  void dispose() {
    _save();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocListener<SettingsCubit, SettingsState>(
      // The name arrives asynchronously on first open; fill it in unless the
      // person has already started typing.
      listenWhen: (p, c) => p.myName != c.myName,
      listener: (_, state) {
        if (!_focus.hasFocus) _controller.text = state.myName;
      },
      child: TextField(
        key: const ValueKey('profile-name-field'),
        controller: _controller,
        focusNode: _focus,
        maxLength: 20,
        textInputAction: TextInputAction.done,
        // The count only matters while typing; hidden otherwise so the
        // card stays short.
        buildCounter: _counterWhileTyping(
          localizedCounter(
            style: TextStyle(color: AppColors.textSecondary.withAlpha(120)),
          ),
        ),
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w800,
        ),
        decoration: InputDecoration(
          hintText: s.name_hint,
          hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(160)),
          isDense: true,
          contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 12, 8, 12),
          filled: true,
          fillColor: AppColors.surface,
          suffixIcon: const Icon(Icons.edit_rounded, size: 18),
          suffixIconColor: WidgetStateColor.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? AppColors.amber
                : AppColors.textSecondary,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppColors.amber, width: 1.6),
          ),
        ),
        onSubmitted: (_) => _focus.unfocus(),
      ),
    );
  }
}

InputCounterWidgetBuilder _counterWhileTyping(InputCounterWidgetBuilder base) =>
    (
      BuildContext context, {
      required int currentLength,
      required int? maxLength,
      required bool isFocused,
    }) => isFocused
    ? base(
        context,
        currentLength: currentLength,
        maxLength: maxLength,
        isFocused: isFocused,
      )
    : null;

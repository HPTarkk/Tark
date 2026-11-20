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
import '../../../../core/widget/profile_hero.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/account_section.dart';
import 'profile_editor_page.dart';

/// The person's radio identity and account.
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
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: Text(
            s.profile_title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 19,
            ),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 14,
                  children: [
                    const _IdentityCard(),
                    if (AccountSection.visible)
                      StaggeredEntrance(
                        beginOffset: const Offset(0, 0.6),
                        builder: (_, children) => children.single,
                        children: const [AccountSection()],
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

TextStyle _sectionLabel(BuildContext context) => TextStyle(
  color: AppColors.textSecondary,
  fontSize: 12,
  fontWeight: FontWeight.w700,
  letterSpacing: Directionality.of(context) == TextDirection.rtl ? 0 : 1.4,
);

/// The radio identity shown to the people in your channel.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final amber = AppColors.amber;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
        gradient: RadialGradient(
          center: const AlignmentDirectional(-0.75, -0.15),
          radius: 1.3,
          colors: [
            Color.alphaBlend(amber.withValues(alpha: 0.14), AppColors.card),
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
        spacing: 16,
        children: [
          BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (before, after) =>
                before.myName != after.myName ||
                before.myAvatarId != after.myAvatarId,
            builder: (context, state) => Row(
              spacing: 16,
              children: [
                ProfileHero.avatar(
                  name: state.myName,
                  avatarId: state.myAvatarId,
                  child: ProfileAvatar(
                    name: state.myName,
                    avatarId: state.myAvatarId,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(s.profile_name_label, style: _sectionLabel(context)),
                      ProfileHero.name(
                        name: state.myName,
                        child: Text(
                          state.myName.trim().isEmpty
                              ? s.people_unnamed
                              : state.myName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            height: 1.18,
                          ),
                        ),
                      ),
                      const _PremiumBadge(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('profile-edit'),
            onPressed: () =>
                openProfileEditor(context, context.read<SettingsCubit>()),
            icon: const Icon(Icons.edit_outlined, size: 17),
            label: Text(s.profile_edit),
            style: FilledButton.styleFrom(
              backgroundColor: amber.withValues(alpha: 0.13),
              foregroundColor: amber,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

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
        final badge = !active
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
              );
        if (AppMotion.reduced(context)) return badge;
        return AnimatedSize(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: badge,
        );
      },
    );
  }
}

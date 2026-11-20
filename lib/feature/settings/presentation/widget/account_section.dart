import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/account_session.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/subscription_service.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../../account/api/account_api.dart';
import 'settings_row.dart';

/// A sign-in entry point or a compact account summary that opens in place.
class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  static bool get visible =>
      GetIt.instance.isRegistered<AccountSession>() &&
      GetIt.instance<AccountSession>().available;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final session = GetIt.instance<AccountSession>();
    final s = context.getString;
    final radius = BorderRadius.circular(20);
    final accent = AppColors.amber;
    return Material(
      key: const ValueKey('account-section'),
      color: AppColors.card,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: AppColors.border),
          gradient: LinearGradient(
            begin: AlignmentDirectional.centerStart,
            end: AlignmentDirectional.centerEnd,
            colors: [
              accent.withValues(alpha: 0.07),
              accent.withValues(alpha: 0),
            ],
          ),
        ),
        child: ValueListenableBuilder<AccountProfile?>(
          valueListenable: session.profile,
          builder: (_, profile, _) {
            final content = PhaseSwitcher(
              child: profile == null
                  ? _AccountLink(
                      key: const ValueKey('account-sign-in'),
                      heroTag: AuthHero.flowTag,
                      icon: Icons.login_rounded,
                      title: s.account_sign_in_row,
                      body: s.account_signed_out_body,
                      onTap: () => pushAuthPage(
                        context,
                        SignInPage.routeName,
                        (_) => SignInPage.buildPage(),
                      ),
                    )
                  : _SignedIn(
                      key: ValueKey(profile.id),
                      profile: profile,
                      onSignOut: (everywhere) => unawaited(
                        _signOut(context, session, everywhere: everywhere),
                      ),
                    ),
            );
            if (AppMotion.reduced(context)) return content;
            return AnimatedSize(
              duration: AppMotion.card,
              curve: AppMotion.easeOut,
              alignment: Alignment.topCenter,
              child: content,
            );
          },
        ),
      ),
    );
  }

  Future<void> _signOut(
    BuildContext context,
    AccountSession session, {
    required bool everywhere,
  }) async {
    final s = context.getString;
    final label = everywhere
        ? s.account_sign_out_everywhere
        : s.account_sign_out;
    final confirmed = await showConfirmSheet(
      context,
      title: label,
      body: everywhere
          ? s.account_sign_out_everywhere_body
          : s.account_sign_out_body,
      action: label,
      icon: everywhere ? Icons.devices_other_rounded : Icons.logout_rounded,
    );
    if (!confirmed) return;
    await session.signOut(everywhere: everywhere);
    if (context.mounted) showAuthToast(context, s.account_signed_out_toast);
  }
}

class _AccountMark extends StatelessWidget {
  const _AccountMark(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: AppColors.amber.withValues(alpha: 0.16),
    ),
    child: SizedBox.square(
      dimension: 44,
      child: Icon(icon, color: AppColors.amber, size: 20),
    ),
  );
}

class _AccountLink extends StatelessWidget {
  const _AccountLink({
    required this.heroTag,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    super.key,
  });

  final Object heroTag;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        spacing: 12,
        children: [
          AuthHero(
            tag: heroTag,
            icon: icon,
            color: AppColors.amber,
            look: AuthHeroLook.badge(AppColors.amber),
            child: _AccountMark(icon),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 3,
              children: [
                Text(title, style: _accountTitle),
                Text(body, style: _accountSubtitle),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_rounded, color: AppColors.amber, size: 20),
        ],
      ),
    ),
  );
}

TextStyle get _accountTitle => TextStyle(
  color: AppColors.textPrimary,
  fontSize: 15,
  fontWeight: FontWeight.w800,
);

TextStyle get _accountSubtitle =>
    TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.4);

class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.profile, required this.onSignOut, super.key});

  final AccountProfile profile;
  final ValueChanged<bool> onSignOut;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final reduced = AppMotion.reduced(context);
    final getIt = GetIt.instance;
    final hasSubscriptions =
        getIt.isRegistered<LicenseGate>() &&
        getIt<LicenseGate>().canPurchase &&
        getIt.isRegistered<SubscriptionService>();
    final chevron = Icon(
      Icons.chevron_right_rounded,
      color: AppColors.textSecondary,
    );
    return ExpansionTile(
      key: const ValueKey('account-manage'),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      iconColor: AppColors.amber,
      collapsedIconColor: AppColors.amber,
      expansionAnimationStyle: reduced
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: AppMotion.sheet,
              curve: AppMotion.easeOut,
            ),
      leading: const _AccountMark(Icons.person_outline_rounded),
      title: Text(s.account_section_title, style: _accountTitle),
      subtitle: Text(
        '\u2066${profile.email}\u2069',
        key: const ValueKey('account-email'),
        style: _accountSubtitle,
      ),
      children: [
        Divider(height: 1, color: AppColors.border),
        if (hasSubscriptions) const _SubscriptionSpotlight(),
        StaggeredEntrance(
          beginOffset: const Offset(0, 1.4),
          builder: (_, actions) => Column(children: actions),
          children: [
            if (profile.hasPassword)
              SettingsRow(
                key: const ValueKey('account-change-password'),
                icon: Icons.password_rounded,
                label: s.account_change_password,
                trailing: chevron,
                onTap: () => pushAuthPage(
                  context,
                  ChangePasswordPage.routeName,
                  (_) => ChangePasswordPage.buildPage(),
                ),
              ),
            SettingsRow(
              key: const ValueKey('account-sign-out'),
              icon: Icons.logout_rounded,
              label: s.account_sign_out,
              trailing: null,
              onTap: () => onSignOut(false),
            ),
            SettingsRow(
              key: const ValueKey('account-sign-out-everywhere'),
              icon: Icons.devices_other_rounded,
              label: s.account_sign_out_everywhere,
              trailing: null,
              onTap: () => onSignOut(true),
            ),
            SettingsRow(
              key: const ValueKey('account-delete'),
              icon: Icons.delete_outline_rounded,
              label: s.account_delete,
              tint: AppColors.red,
              trailing: chevron,
              onTap: () => pushAuthPage(
                context,
                DeleteAccountPage.routeName,
                (_) => DeleteAccountPage.buildPage(profile: profile),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SubscriptionSpotlight extends StatelessWidget {
  const _SubscriptionSpotlight();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final subscription = GetIt.instance<SubscriptionService>();
    return StreamBuilder<void>(
      stream: subscription.changes,
      builder: (context, _) {
        if (!subscription.isPremiumActive) return const SizedBox.shrink();
        return _AccountLink(
          key: const ValueKey('account-subscription'),
          heroTag: AuthHero.subscriptionTag,
          icon: Icons.workspace_premium_rounded,
          title: s.account_subscription,
          body: s.mysub_premium,
          onTap: () => pushAuthPage(
            context,
            SubscriptionPage.routeName,
            (_) => SubscriptionPage.buildPage(),
          ),
        );
      },
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/account_session.dart';
import '../../../../core/entitlement/subscription_service.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../../account/api/account_api.dart';
import 'settings_category_card.dart';
import 'settings_row.dart';

/// The account card on the Profile page. Signed out: one "Sign in" row and
/// a line saying an account is only for subscriptions. Signed in: the
/// email (read-only), password change, sign-out and deletion.
///
/// Renders nothing on builds without sign-in (web, guest, iOS for now, and
/// builds that sell nothing).
class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  /// Whether this build shows the account card at all.
  static bool get visible =>
      GetIt.instance.isRegistered<AccountSession>() &&
      GetIt.instance<AccountSession>().available;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final session = GetIt.instance<AccountSession>();
    final s = context.getString;
    return ValueListenableBuilder<AccountProfile?>(
      valueListenable: session.profile,
      builder: (context, profile, _) => SettingsCategoryCard(
        key: const ValueKey('account-section'),
        icon: Icons.account_circle_rounded,
        title: s.account_section_title,
        // Signing in or out swaps the card's contents in place: the old
        // state fades as the card resizes to the new one.
        child: AnimatedSize(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          alignment: Alignment.topCenter,
          child: PhaseSwitcher(
            child: profile == null
                ? _SignedOut(
                    key: const ValueKey('signed-out'),
                    onSignIn: () => _signIn(context),
                  )
                : _SignedIn(
                    key: const ValueKey('signed-in'),
                    profile: profile,
                    session: session,
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _signIn(BuildContext context) => pushAuthPage(
    context,
    SignInPage.routeName,
    (_) => SignInPage.buildPage(),
  );
}

/// Signed out: one inviting card that says what an account is for, and
/// opens sign-in.
class _SignedOut extends StatelessWidget {
  const _SignedOut({required this.onSignIn, super.key});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final amber = AppColors.amber;
    final radius = BorderRadius.circular(14);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: PressableScale(
        key: const ValueKey('account-sign-in'),
        onTap: onSignIn,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 10, 14),
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [
                Color.alphaBlend(amber.withValues(alpha: 0.12), AppColors.card),
                AppColors.card,
              ],
            ),
            border: Border.all(color: amber.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: amber.withValues(alpha: 0.16),
                ),
                child: Icon(Icons.login_rounded, color: amber, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.account_sign_in_row,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.account_signed_out_body,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(shape: BoxShape.circle, color: amber),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.background,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.profile, required this.session, super.key});

  final AccountProfile profile;
  final AccountSession session;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final chevron = Icon(
      Icons.chevron_right_rounded,
      color: AppColors.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          key: const ValueKey('account-email'),
          icon: Icons.alternate_email_rounded,
          label: s.account_email_label,
          subtitle: '\u2066${profile.email}\u2069',
          trailing: Icon(
            Icons.verified_rounded,
            color: AppColors.green,
            size: 20,
          ),
        ),
        if (GetIt.instance.isRegistered<SubscriptionService>())
          SettingsRow(
            key: const ValueKey('account-subscription'),
            icon: Icons.workspace_premium_rounded,
            label: s.account_subscription,
            trailing: chevron,
            onTap: () => pushAuthPage(
              context,
              SubscriptionPage.routeName,
              (_) => SubscriptionPage.buildPage(),
            ),
          ),
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
          onTap: () => unawaited(_signOut(context, everywhere: false)),
        ),
        SettingsRow(
          key: const ValueKey('account-sign-out-everywhere'),
          icon: Icons.devices_other_rounded,
          label: s.account_sign_out_everywhere,
          trailing: null,
          onTap: () => unawaited(_signOut(context, everywhere: true)),
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
    );
  }

  Future<void> _signOut(
    BuildContext context, {
    required bool everywhere,
  }) async {
    final s = context.getString;
    if (everywhere) {
      final confirmed = await showConfirmSheet(
        context,
        title: s.account_sign_out_everywhere,
        body: s.account_sign_out_everywhere_body,
        action: s.account_sign_out_everywhere,
        icon: Icons.devices_other_rounded,
      );
      if (!confirmed) return;
    }
    await session.signOut(everywhere: everywhere);
    if (context.mounted) showAuthToast(context, s.account_signed_out_toast);
  }
}

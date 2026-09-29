import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/account_session.dart';
import '../../../../core/l10n/extension.dart';
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
        child: profile == null
            ? _SignedOut(onSignIn: () => _signIn(context))
            : _SignedIn(profile: profile, session: session),
      ),
    );
  }

  Future<void> _signIn(BuildContext context) => pushAuthPage(
    context,
    SignInPage.routeName,
    (_) => SignInPage.buildPage(),
  );
}

class _SignedOut extends StatelessWidget {
  const _SignedOut({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          key: const ValueKey('account-sign-in'),
          icon: Icons.login_rounded,
          label: s.account_sign_in_row,
          subtitle: s.account_signed_out_body,
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: AppColors.textSecondary,
          ),
          onTap: onSignIn,
        ),
      ],
    );
  }
}

class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.profile, required this.session});

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
          trailing: null,
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

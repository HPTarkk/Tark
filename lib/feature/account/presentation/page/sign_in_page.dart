import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../manager/account_form_cubit.dart';
import '../widget/auth_error_text.dart';
import '../widget/auth_widgets.dart';
import 'forgot_password_page.dart';
import 'google_steps_page.dart';
import 'register_page.dart';

/// Sign in with email and password, or Google. Also the door to creating an
/// account and to resetting a password. Pops true once signed in.
///
/// Signing in is optional in Tark: it exists only so a subscription can
/// belong to an account. The page is reached from Profile and from the
/// subscription screen, never forced.
class SignInPage extends StatefulWidget {
  const SignInPage._();

  static const routeName = 'SignInPage';

  static Widget buildPage() => BlocProvider(
    create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
    child: const SignInPage._(),
  );

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(email: _email.text, password: _password.text)) return;
    final result = await _cubit.run(
      () =>
          _cubit.repository.login(email: _email.text, password: _password.text),
    );
    if (result is AuthSuccess && mounted) _done();
  }

  Future<void> _google() async {
    FocusScope.of(context).unfocus();
    final result = await _cubit.run(() => _cubit.repository.signInWithGoogle());
    if (!mounted || result == null) return;
    switch (result) {
      case AuthSuccess():
        _done();
      case AuthFailure(:final error)
          when error.kind == AuthErrorKind.linkRequired && error.ticket != null:
        _cubit.clearError();
        final linked = await pushAuthPage(
          context,
          GoogleLinkPage.routeName,
          (_) => GoogleLinkPage.buildPage(
            ticket: error.ticket!,
            maskedEmail: error.maskedEmail ?? '',
          ),
        );
        if (linked && mounted) _done();
      case AuthFailure(:final error)
          when error.kind == AuthErrorKind.nameRequired && error.ticket != null:
        _cubit.clearError();
        final named = await pushAuthPage(
          context,
          GoogleNamePage.routeName,
          (_) => GoogleNamePage.buildPage(
            ticket: error.ticket!,
            suggestedName: error.suggestedName,
          ),
        );
        if (named && mounted) _done();
      case AuthFailure():
        break;
    }
  }

  Future<void> _register() async {
    final done = await pushAuthPage(
      context,
      RegisterPage.routeName,
      (_) => RegisterPage.buildPage(email: _email.text),
    );
    if (done && mounted) _done();
  }

  Future<void> _forgot() async {
    final done = await pushAuthPage(
      context,
      ForgotPasswordPage.routeName,
      (_) => ForgotPasswordPage.buildPage(email: _email.text),
    );
    if (done && mounted) _done();
  }

  void _done() {
    showAuthToast(context, context.getString.signin_done);
    finishAuthFlow(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<AccountFormCubit, AccountFormState>(
      builder: (context, state) {
        final error = state.error;
        final message = error == null ? null : authErrorText(context, error);
        return AuthScaffold(
          icon: Icons.account_circle_outlined,
          title: s.signin_title,
          body: s.signin_subtitle,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('signin-email'),
              controller: _email,
              hint: s.auth_email_hint,
              ltr: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              enabled: !state.busy,
            ),
            AuthTextField(
              fieldKey: const ValueKey('signin-password'),
              controller: _password,
              hint: s.auth_password_hint,
              obscure: true,
              ltr: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _signIn(),
              enabled: !state.busy,
            ),
            if (message != null) AuthMessage(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('signin-submit'),
              label: s.signin_action,
              busy: state.busy,
              onTap: _signIn,
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: AuthTextLink(
                linkKey: const ValueKey('signin-forgot'),
                label: s.signin_forgot,
                onTap: state.busy ? null : _forgot,
              ),
            ),
            if (_cubit.repository.googleAvailable) ...[
              _OrDivider(label: s.signin_or),
              AuthSecondaryButton(
                buttonKey: const ValueKey('signin-google'),
                label: s.signin_google,
                icon: Icons.g_mobiledata_rounded,
                onTap: state.busy ? null : _google,
              ),
            ],
            const SizedBox(height: 18),
            AuthTextLink(
              linkKey: const ValueKey('signin-register'),
              label: s.signin_create,
              onTap: state.busy ? null : _register,
            ),
          ],
        );
      },
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: AppColors.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          Expanded(child: Divider(color: AppColors.border)),
        ],
      ),
    );
  }
}

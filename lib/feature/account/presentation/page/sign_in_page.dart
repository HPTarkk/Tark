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

  /// Signed in: the check mark is playing and the screen leaves when it
  /// lands.
  bool _signedIn = false;

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
        if (linked && mounted) _leave();
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
        if (named && mounted) _leave();
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
    // The code screen already showed its check mark and said so.
    if (done && mounted) finishAuthFlow(context);
  }

  Future<void> _forgot() async {
    final done = await pushAuthPage(
      context,
      ForgotPasswordPage.routeName,
      (_) => ForgotPasswordPage.buildPage(email: _email.text),
    );
    if (done && mounted) finishAuthFlow(context);
  }

  void _done() => setState(() => _signedIn = true);

  /// Leaves once signed in. Screens further along the flow (Google's) have
  /// already shown their own check mark, so they come straight here.

  void _leave() {
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
        final locked = state.busy || _signedIn;
        return AuthScaffold(
          icon: Icons.person_rounded,
          title: s.signin_title,
          body: s.signin_subtitle,
          busy: state.busy,
          error: error,
          success: _signedIn,
          onSuccessShown: _leave,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('signin-email'),
              controller: _email,
              hint: s.auth_email_hint,
              icon: Icons.alternate_email_rounded,
              ltr: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              enabled: !locked,
            ),
            AuthTextField(
              fieldKey: const ValueKey('signin-password'),
              controller: _password,
              hint: s.auth_password_hint,
              icon: Icons.lock_outline_rounded,
              obscure: true,
              ltr: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _signIn(),
              enabled: !locked,
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: AuthTextLink(
                linkKey: const ValueKey('signin-forgot'),
                label: s.signin_forgot,
                onTap: locked ? null : _forgot,
              ),
            ),
            const SizedBox(height: 6),
            AuthMessageSlot(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('signin-submit'),
              label: s.signin_action,
              busy: state.busy,
              done: _signedIn,
              onTap: _signIn,
            ),
            if (_cubit.repository.googleAvailable) ...[
              AuthOrDivider(label: s.signin_or),
              AuthSecondaryButton(
                buttonKey: const ValueKey('signin-google'),
                label: s.signin_google,
                leading: const GoogleMark(),
                onTap: locked ? null : _google,
              ),
            ],
            const SizedBox(height: 22),
            _CreateAccount(
              prompt: s.signin_create,
              onTap: locked ? null : _register,
            ),
          ],
        );
      },
    );
  }
}

/// The way to a new account, set apart in its own quiet card at the foot of
/// the screen.
class _CreateAccount extends StatelessWidget {
  const _CreateAccount({required this.prompt, required this.onTap});

  final String prompt;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_add_alt_rounded, size: 18, color: AppColors.amber),
          Flexible(
            child: AuthTextLink(
              linkKey: const ValueKey('signin-register'),
              label: prompt,
              onTap: onTap,
            ),
          ),
        ],
      ),
    );
  }
}

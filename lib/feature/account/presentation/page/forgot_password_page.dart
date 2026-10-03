import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';
import '../../../../core/l10n/extension.dart';
import '../manager/account_form_cubit.dart';
import '../widget/auth_error_text.dart';
import '../widget/auth_widgets.dart';
import 'code_entry_page.dart';

/// Starts a password reset. The answer is the same whether or not the
/// address has an account, so this screen always moves on to the code.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage._({required this.initialEmail});

  static const routeName = 'ForgotPasswordPage';

  static Widget buildPage({String email = ''}) => BlocProvider(
    create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
    child: ForgotPasswordPage._(initialEmail: email),
  );

  final String initialEmail;

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final _email = TextEditingController(text: widget.initialEmail);

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(email: _email.text)) return;
    final result = await _cubit.run(
      () => _cubit.repository.forgotPassword(_email.text),
    );
    if (result is! AuthSuccess || !mounted) return;
    final done = await pushAuthPage(
      context,
      CodeEntryPage.routeName,
      (_) => CodeEntryPage.buildPage(kind: FlowKind.reset),
    );
    if (done && mounted) finishAuthFlow(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<AccountFormCubit, AccountFormState>(
      builder: (context, state) {
        final error = state.error;
        final message = error == null ? null : authErrorText(context, error);
        return AuthScaffold(
          icon: Icons.lock_reset_rounded,
          title: s.forgot_title,
          body: s.forgot_body,
          busy: state.busy,
          error: error,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('forgot-email'),
              controller: _email,
              hint: s.auth_email_hint,
              icon: Icons.alternate_email_rounded,
              ltr: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              enabled: !state.busy,
            ),
            AuthMessageSlot(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('forgot-submit'),
              label: s.forgot_action,
              busy: state.busy,
              onTap: _submit,
            ),
          ],
        );
      },
    );
  }
}

/// The new password, after a verified reset. Signs in on success; every
/// other session of the account ends.
class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage._({required this.ticket});

  static const routeName = 'ResetPasswordPage';

  static Widget buildPage({required ResetTicket ticket}) => BlocProvider(
    create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
    child: ResetPasswordPage._(ticket: ticket),
  );

  final ResetTicket ticket;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _password = TextEditingController();
  bool _saved = false;

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _leave() {
    showAuthToast(context, context.getString.signin_done);
    finishAuthFlow(context);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(newPassword: _password.text)) return;
    final result = await _cubit.run(
      () => _cubit.repository.resetPassword(
        ticket: widget.ticket,
        newPassword: _password.text,
      ),
    );
    if (result is AuthSuccess && mounted) setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<AccountFormCubit, AccountFormState>(
      builder: (context, state) {
        final error = state.error;
        final message = error == null ? null : authErrorText(context, error);
        return AuthScaffold(
          icon: Icons.password_rounded,
          title: s.reset_title,
          body: s.reset_body,
          busy: state.busy,
          error: error,
          success: _saved,
          onSuccessShown: _leave,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('reset-password'),
              controller: _password,
              hint: s.auth_new_password_hint,
              icon: Icons.lock_outline_rounded,
              obscure: true,
              ltr: true,
              maxLength: 128,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              enabled: !state.busy && !_saved,
            ),
            AuthMessageSlot(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('reset-submit'),
              label: s.reset_action,
              busy: state.busy,
              done: _saved,
              onTap: _submit,
            ),
          ],
        );
      },
    );
  }
}

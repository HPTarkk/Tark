import 'dart:async';

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

/// Email + password sign-up. The name starts as the radio name this phone
/// already uses. Continues to the code screen; pops true once the code (or
/// link) has signed the person in.
class RegisterPage extends StatefulWidget {
  const RegisterPage._({required this.initialEmail});

  static const routeName = 'RegisterPage';

  static Widget buildPage({String email = ''}) => BlocProvider(
    create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
    child: RegisterPage._(initialEmail: email),
  );

  final String initialEmail;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _password = TextEditingController();
  final _name = TextEditingController();

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final name = await _cubit.repository.localName();
      if (mounted && _name.text.isEmpty) _name.text = name;
    }());
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(
      name: _name.text,
      email: _email.text,
      newPassword: _password.text,
    )) {
      return;
    }
    final result = await _cubit.run(
      () => _cubit.repository.register(
        email: _email.text,
        password: _password.text,
        name: _name.text,
      ),
    );
    if (result is! AuthSuccess || !mounted) return;
    final done = await pushAuthPage(
      context,
      CodeEntryPage.routeName,
      (_) => CodeEntryPage.buildPage(kind: FlowKind.register),
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
          icon: Icons.person_add_alt_rounded,
          title: s.register_title,
          body: s.register_body,
          busy: state.busy,
          error: error,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('register-name'),
              controller: _name,
              hint: s.auth_name_hint,
              icon: Icons.badge_outlined,
              maxLength: 50,
              autofillHints: const [AutofillHints.name],
              enabled: !state.busy,
            ),
            AuthTextField(
              fieldKey: const ValueKey('register-email'),
              controller: _email,
              hint: s.auth_email_hint,
              icon: Icons.alternate_email_rounded,
              ltr: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              enabled: !state.busy,
            ),
            AuthTextField(
              fieldKey: const ValueKey('register-password'),
              controller: _password,
              hint: s.auth_new_password_hint,
              icon: Icons.lock_outline_rounded,
              obscure: true,
              ltr: true,
              maxLength: 128,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              enabled: !state.busy,
            ),
            AuthMessageSlot(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('register-submit'),
              label: s.register_action,
              busy: state.busy,
              onTap: _submit,
            ),
          ],
        );
      },
    );
  }
}

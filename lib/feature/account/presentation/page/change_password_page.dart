import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';
import '../../../../core/l10n/extension.dart';
import '../manager/account_form_cubit.dart';
import '../widget/auth_error_text.dart';
import '../widget/auth_widgets.dart';

/// Change the password, given the current one. This phone stays signed in;
/// the account's other sessions end.
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage._();

  static const routeName = 'ChangePasswordPage';

  static Widget buildPage() => BlocProvider(
    create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
    child: const ChangePasswordPage._(),
  );

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(password: _current.text, newPassword: _next.text)) {
      return;
    }
    final result = await _cubit.run(
      () => _cubit.repository.changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
      ),
    );
    if (result is AuthSuccess && mounted) {
      showAuthToast(context, context.getString.change_password_done);
      finishAuthFlow(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<AccountFormCubit, AccountFormState>(
      builder: (context, state) {
        final error = state.error;
        final message = error == null
            ? null
            : authErrorText(context, error, passwordContext: true);
        return AuthScaffold(
          icon: Icons.password_rounded,
          title: s.account_change_password,
          body: s.change_password_body,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('change-current'),
              controller: _current,
              hint: s.auth_current_password_hint,
              obscure: true,
              ltr: true,
              autofillHints: const [AutofillHints.password],
              enabled: !state.busy,
            ),
            AuthTextField(
              fieldKey: const ValueKey('change-new'),
              controller: _next,
              hint: s.auth_new_password_hint,
              obscure: true,
              ltr: true,
              maxLength: 128,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              enabled: !state.busy,
            ),
            if (message != null) AuthMessage(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('change-submit'),
              label: s.change_password_action,
              busy: state.busy,
              onTap: _submit,
            ),
          ],
        );
      },
    );
  }
}

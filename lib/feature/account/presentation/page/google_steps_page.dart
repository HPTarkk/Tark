import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';
import '../../../../core/l10n/extension.dart';
import '../manager/account_form_cubit.dart';
import '../widget/auth_error_text.dart';
import '../widget/auth_widgets.dart';

/// Google sign-in found a password account with the same address: its
/// password, once, adds Google to it and signs in. Pops true when linked.
class GoogleLinkPage extends StatefulWidget {
  const GoogleLinkPage._({required this.ticket, required this.maskedEmail});

  static const routeName = 'GoogleLinkPage';

  static Widget buildPage({
    required String ticket,
    required String maskedEmail,
  }) => BlocProvider(
    create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
    child: GoogleLinkPage._(ticket: ticket, maskedEmail: maskedEmail),
  );

  final String ticket;
  final String maskedEmail;

  @override
  State<GoogleLinkPage> createState() => _GoogleLinkPageState();
}

class _GoogleLinkPageState extends State<GoogleLinkPage> {
  final _password = TextEditingController();

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(password: _password.text)) return;
    final result = await _cubit.run(
      () => _cubit.repository.linkGoogle(
        ticket: widget.ticket,
        password: _password.text,
      ),
    );
    if (result is AuthSuccess && mounted) finishAuthFlow(context);
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
        final ticketGone = switch (error?.kind) {
          AuthErrorKind.ticketExpired || AuthErrorKind.ticketLocked => true,
          _ => false,
        };
        return AuthScaffold(
          icon: Icons.link_rounded,
          title: s.google_link_title,
          body: s.google_link_body('\u2066${widget.maskedEmail}\u2069'),
          children: [
            AuthTextField(
              fieldKey: const ValueKey('google-link-password'),
              controller: _password,
              hint: s.auth_password_hint,
              obscure: true,
              ltr: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              enabled: !state.busy && !ticketGone,
            ),
            if (message != null) AuthMessage(message),
            if (ticketGone)
              AuthPrimaryButton(
                label: s.auth_close,
                onTap: () => finishAuthFlow(context, signedIn: false),
              )
            else
              AuthPrimaryButton(
                buttonKey: const ValueKey('google-link-submit'),
                label: s.google_link_action,
                busy: state.busy,
                onTap: _submit,
              ),
          ],
        );
      },
    );
  }
}

/// Google sign-up where neither this phone nor Google had a name to use.
class GoogleNamePage extends StatefulWidget {
  const GoogleNamePage._({required this.ticket, this.suggestedName});

  static const routeName = 'GoogleNamePage';

  static Widget buildPage({required String ticket, String? suggestedName}) =>
      BlocProvider(
        create: (_) => AccountFormCubit(GetIt.instance<AuthRepository>()),
        child: GoogleNamePage._(ticket: ticket, suggestedName: suggestedName),
      );

  final String ticket;
  final String? suggestedName;

  @override
  State<GoogleNamePage> createState() => _GoogleNamePageState();
}

class _GoogleNamePageState extends State<GoogleNamePage> {
  late final _name = TextEditingController(text: widget.suggestedName ?? '');

  AccountFormCubit get _cubit => context.read<AccountFormCubit>();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_cubit.validate(name: _name.text)) return;
    final result = await _cubit.run(
      () => _cubit.repository.completeGoogle(
        ticket: widget.ticket,
        name: _name.text,
      ),
    );
    if (result is AuthSuccess && mounted) finishAuthFlow(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<AccountFormCubit, AccountFormState>(
      builder: (context, state) {
        final error = state.error;
        final message = error == null ? null : authErrorText(context, error);
        return AuthScaffold(
          icon: Icons.badge_rounded,
          title: s.google_name_title,
          children: [
            AuthTextField(
              fieldKey: const ValueKey('google-name'),
              controller: _name,
              hint: s.auth_name_hint,
              maxLength: 50,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              enabled: !state.busy,
            ),
            if (message != null) AuthMessage(message),
            AuthPrimaryButton(
              label: s.google_name_action,
              busy: state.busy,
              onTap: _submit,
            ),
          ],
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/auth_repository.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../manager/delete_account_cubit.dart';
import '../widget/auth_error_text.dart';
import '../widget/auth_widgets.dart';

/// Deleting the account, deliberately slow: what it does and does not
/// touch, the account's email typed out, the password (or Google again),
/// the subscription acknowledgement when one is running, and a last
/// confirmation sheet. Pops true once the account is gone.
class DeleteAccountPage extends StatefulWidget {
  const DeleteAccountPage._({required this.profile});

  static const routeName = 'DeleteAccountPage';

  static Widget buildPage({required AccountProfile profile}) => BlocProvider(
    create: (_) => DeleteAccountCubit(GetIt.instance<AuthRepository>()),
    child: DeleteAccountPage._(profile: profile),
  );

  final AccountProfile profile;

  @override
  State<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends State<DeleteAccountPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  /// A Google-only account proves itself with a fresh Google sign-in; one
  /// with a password uses the password.
  bool get _withGoogle => !widget.profile.hasPassword;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final cubit = context.read<DeleteAccountCubit>();
    if (_email.text.trim().isEmpty ||
        (!_withGoogle && _password.text.isEmpty)) {
      await cubit.submit(
        confirmEmail: _email.text,
        password: _password.text,
        withGoogle: _withGoogle,
      );
      return;
    }
    final s = context.getString;
    final confirmed = await showConfirmSheet(
      context,
      title: s.delete_confirm_title,
      body: s.delete_confirm_body,
      action: s.delete_action,
      icon: Icons.delete_forever_rounded,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await cubit.submit(
      confirmEmail: _email.text,
      password: _password.text,
      withGoogle: _withGoogle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocConsumer<DeleteAccountCubit, DeleteAccountState>(
      listenWhen: (p, c) => !p.deleted && c.deleted,
      listener: (context, state) {
        showAuthToast(context, s.delete_done);
        finishAuthFlow(context);
      },
      builder: (context, state) {
        final error = state.error;
        final message = error == null
            ? null
            : authErrorText(context, error, passwordContext: true);
        final blocked = state.subscriptionRunning && !state.acknowledged;
        return AuthScaffold(
          icon: Icons.delete_forever_rounded,
          iconColor: AppColors.red,
          title: s.delete_title,
          body: s.delete_warning,
          children: [
            AuthMessage(s.delete_keeps, positive: true),
            _Label(s.delete_type_email('\u2066${widget.profile.email}\u2069')),
            AuthTextField(
              fieldKey: const ValueKey('delete-email'),
              controller: _email,
              hint: s.auth_email_hint,
              ltr: true,
              keyboardType: TextInputType.emailAddress,
              enabled: !state.busy,
            ),
            if (_withGoogle)
              _Label(s.delete_google_note)
            else
              AuthTextField(
                fieldKey: const ValueKey('delete-password'),
                controller: _password,
                hint: s.auth_password_hint,
                obscure: true,
                ltr: true,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                enabled: !state.busy,
              ),
            if (state.subscriptionRunning)
              _SubscriptionNotice(
                autoRenewing: state.autoRenewing ?? true,
                acknowledged: state.acknowledged,
                onChanged: state.busy
                    ? null
                    : context.read<DeleteAccountCubit>().setAcknowledged,
              ),
            if (message != null) AuthMessage(message),
            AuthPrimaryButton(
              buttonKey: const ValueKey('delete-submit'),
              label: _withGoogle ? s.delete_action_google : s.delete_action,
              destructive: true,
              busy: state.busy,
              onTap: blocked ? null : _submit,
            ),
          ],
        );
      },
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
          height: 1.6,
        ),
      ),
    );
  }
}

/// What deleting means for a running Bazaar subscription, and the tick the
/// server requires before it deletes anyway.
class _SubscriptionNotice extends StatelessWidget {
  const _SubscriptionNotice({
    required this.autoRenewing,
    required this.acknowledged,
    required this.onChanged,
  });

  final bool autoRenewing;
  final bool acknowledged;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      key: const ValueKey('delete-subscription-notice'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.delete_sub_title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Text(
              autoRenewing ? s.delete_sub_body_renewing : s.delete_sub_body,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),
          // Its own Material, so the tile's ink shows on the card colour.
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              key: const ValueKey('delete-subscription-ack'),
              value: acknowledged,
              onChanged: onChanged == null
                  ? null
                  : (value) => onChanged!(value ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppColors.amber,
              checkColor: AppColors.background,
              title: Text(
                s.delete_sub_ack,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

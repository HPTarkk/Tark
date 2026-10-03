import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/email_link.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../manager/code_entry_cubit.dart';
import '../widget/auth_error_text.dart';
import '../widget/auth_widgets.dart';
import '../widget/code_input.dart';
import 'forgot_password_page.dart';

/// "Check your email": the 6-digit code for sign-up or password reset.
///
/// Also where an email link lands. While this screen is open it claims
/// links for its flow, so opening the link from the mail app finishes the
/// flow right here; when the app was closed, the app opens this screen with
/// [linkToken] instead.
///
/// Pops true once sign-up signed in, or once the new password was set.
class CodeEntryPage extends StatefulWidget {
  const CodeEntryPage._({required this.kind, this.linkToken});

  static const routeName = 'CodeEntryPage';

  static Widget buildPage({required FlowKind kind, String? linkToken}) =>
      BlocProvider(
        create: (_) => CodeEntryCubit(
          repository: GetIt.instance<AuthRepository>(),
          kind: kind,
        ),
        child: CodeEntryPage._(kind: kind, linkToken: linkToken),
      );

  /// For a link that opened the app. A link for a flow this app does not
  /// run (email change) has no [FlowKind]; it is shown like a link from
  /// another phone.
  static Widget buildForLink(EmailLink link) {
    final kind = link.kind;
    if (kind == null) return const _NoFlowPage();
    return buildPage(kind: kind, linkToken: link.token);
  }

  final FlowKind kind;
  final String? linkToken;

  @override
  State<CodeEntryPage> createState() => _CodeEntryPageState();
}

class _CodeEntryPageState extends State<CodeEntryPage> {
  final _code = TextEditingController();
  void Function()? _releaseLinks;

  /// Sign-up finished: the check mark is playing and the screen leaves when
  /// it lands.
  bool _registered = false;

  CodeEntryCubit get _cubit => context.read<CodeEntryCubit>();

  @override
  void initState() {
    super.initState();
    unawaited(_cubit.load(linkToken: widget.linkToken));
    if (GetIt.instance.isRegistered<EmailLinkDispatcher>()) {
      _releaseLinks = GetIt.instance<EmailLinkDispatcher>().claim(widget.kind, (
        link,
      ) {
        _code.clear();
        unawaited(_cubit.submitLink(link.token));
        return true;
      });
    }
  }

  @override
  void dispose() {
    _releaseLinks?.call();
    _code.dispose();
    super.dispose();
  }

  Future<void> _onState(BuildContext context, CodeEntryState state) async {
    if (state.error != null) _code.clear();
    if (state.phase != CodeEntryPhase.done) return;
    switch (widget.kind) {
      case FlowKind.register:
        setState(() => _registered = true);
      case FlowKind.reset:
        final ticket = state.ticket;
        if (ticket == null) return;
        final done = await pushAuthPage(
          context,
          ResetPasswordPage.routeName,
          (_) => ResetPasswordPage.buildPage(ticket: ticket),
        );
        if (context.mounted) finishAuthFlow(context, signedIn: done);
    }
  }

  void _leave() {
    showAuthToast(context, context.getString.signin_done);
    finishAuthFlow(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocConsumer<CodeEntryCubit, CodeEntryState>(
      listenWhen: (p, c) => p.phase != c.phase || p.error != c.error,
      listener: _onState,
      builder: (context, state) {
        switch (state.phase) {
          case CodeEntryPhase.loading:
            // The same frame the code arrives in, so the hero is already in
            // place and only the fields arrive when the flow has loaded.
            return AuthScaffold(
              icon: Icons.mark_email_unread_outlined,
              title: s.code_title,
              busy: true,
              contentKey: CodeEntryPhase.loading,
              children: const [],
            );
          case CodeEntryPhase.noFlow:
            return const _NoFlowPage();
          case CodeEntryPhase.entering ||
              CodeEntryPhase.verifying ||
              CodeEntryPhase.done:
            break;
        }
        final flow = state.flow!;
        final error = state.error;
        final message = error == null ? null : authErrorText(context, error);
        final verifying = state.phase == CodeEntryPhase.verifying;
        final done = state.phase == CodeEntryPhase.done;
        return AuthScaffold(
          icon: Icons.mark_email_unread_outlined,
          title: s.code_title,
          body: s.code_body('\u2066${flow.email}\u2069'),
          busy: verifying,
          error: error,
          success: _registered,
          onSuccessShown: _leave,
          contentKey: CodeEntryPhase.entering,
          children: [
            CodeInput(
              controller: _code,
              length: flow.codeLength,
              enabled:
                  state.phase == CodeEntryPhase.entering && !state.flowDead,
              error: error,
              success: done,
              onCompleted: _cubit.submitCode,
            ),
            const SizedBox(height: 14),
            AuthReveal(visible: verifying, child: const _Verifying()),
            AuthMessageSlot(
              state.linkRejected ? s.code_link_elsewhere_body : null,
            ),
            AuthMessageSlot(message),
            AuthMessageSlot(
              state.resent ? s.code_resent : null,
              positive: true,
            ),
            PhaseSwitcher(
              alignment: Alignment.center,
              child: state.flowDead
                  ? AuthPrimaryButton(
                      key: const ValueKey('start-over'),
                      buttonKey: const ValueKey('code-start-over'),
                      label: s.code_start_over,
                      onTap: () => finishAuthFlow(context, signedIn: false),
                    )
                  : _ResendRow(
                      key: const ValueKey('resend'),
                      state: state,
                      onResend: _cubit.resend,
                    ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.mark_email_read_outlined,
                  size: 15,
                  color: AppColors.textSecondary.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    s.code_spam_hint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary.withValues(alpha: 0.8),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// "Checking…" with a small spinner, under the code while it is verified.
class _Verifying extends StatelessWidget {
  const _Verifying();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.amber,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            context.getString.code_verifying,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ResendRow extends StatelessWidget {
  const _ResendRow({required this.state, required this.onResend, super.key});

  final CodeEntryState state;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final left = state.resendIn;
    if (left > Duration.zero) {
      final minutes = left.inMinutes;
      final seconds = (left.inSeconds % 60).toString().padLeft(2, '0');
      return Padding(
        key: const ValueKey('code-resend-wait'),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                s.code_resend_in('$minutes:$seconds'.localized(context)),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      child: AuthTextLink(
        linkKey: const ValueKey('code-resend'),
        label: s.code_resend,
        onTap: state.canResend ? onResend : null,
      ),
    );
  }
}

/// A link for a flow this phone did not start (or one already finished):
/// the person finishes it by typing the code on the phone that started it.
class _NoFlowPage extends StatelessWidget {
  const _NoFlowPage();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return AuthScaffold(
      icon: Icons.phonelink_rounded,
      title: s.code_link_elsewhere_title,
      body: s.code_link_elsewhere_body,
      children: [
        AuthPrimaryButton(
          buttonKey: const ValueKey('code-close'),
          label: s.auth_close,
          onTap: () => finishAuthFlow(context, signedIn: false),
        ),
      ],
    );
  }
}

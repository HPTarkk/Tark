import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// The frame every account screen shares: a back arrow, a glyph, a heading
/// and a line of explanation, then the screen's own fields — in the same
/// palette and stagger as Profile and the subscription screens.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    required this.icon,
    required this.title,
    required this.children,
    this.body,
    this.iconColor,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Color? iconColor;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? AppColors.amber;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: AutofillGroup(
              child: StaggeredEntrance(
                builder: (context, items) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: items,
                ),
                children: [
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color.withValues(alpha: 0.10),
                        border: Border.all(
                          color: color.withValues(alpha: 0.28),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, size: 32, color: color),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        height: 1.3,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 24),
                    child: body == null
                        ? const SizedBox.shrink()
                        : Text(
                            body!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                              height: 1.7,
                            ),
                          ),
                  ),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A text field in the Profile page's style. Addresses and passwords are
/// identifiers, so they are always laid out left to right, even in Persian.
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    required this.controller,
    required this.hint,
    this.fieldKey,
    this.keyboardType,
    this.autofillHints,
    this.obscure = false,
    this.ltr = false,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.enabled = true,
    this.maxLength,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final Key? fieldKey;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final bool obscure;
  final bool ltr;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final int? maxLength;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color),
    );
    final field = TextField(
      key: widget.fieldKey,
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: !widget.obscure && !widget.ltr,
      keyboardType: widget.keyboardType,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      maxLength: widget.maxLength,
      style: TextStyle(color: AppColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: widget.hint,
        counterText: '',
        hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(160)),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        border: border(AppColors.border),
        enabledBorder: border(AppColors.border),
        disabledBorder: border(AppColors.border),
        focusedBorder: border(AppColors.amber),
        suffixIcon: widget.obscure
            ? IconButton(
                tooltip: _hidden ? s.auth_show_password : s.auth_hide_password,
                icon: Icon(
                  _hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
                onPressed: () => setState(() => _hidden = !_hidden),
              )
            : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: widget.ltr
          ? Directionality(textDirection: TextDirection.ltr, child: field)
          : field,
    );
  }
}

/// The one strong action on an account screen.
class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    required this.label,
    required this.onTap,
    this.busy = false,
    this.destructive = false,
    this.buttonKey,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;
  final bool destructive;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    final enabled = onTap != null && !busy;
    final color = destructive ? AppColors.red : AppColors.amber;
    return Semantics(
      button: true,
      enabled: enabled,
      child: PressableScale(
        key: buttonKey,
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: AnimatedContainer(
          duration: AppMotion.card,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            color: enabled || busy ? color : color.withAlpha(90),
            borderRadius: radius,
          ),
          alignment: Alignment.center,
          child: busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: AppColors.background,
                  ),
                )
              : Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.background,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                  ),
                ),
        ),
      ),
    );
  }
}

/// A secondary action: outlined, same height as [AuthPrimaryButton].
class AuthSecondaryButton extends StatelessWidget {
  const AuthSecondaryButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.buttonKey,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return PressableScale(
      key: buttonKey,
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: radius,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: AppColors.textPrimary),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: onTap == null
                      ? AppColors.textSecondary
                      : AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A quiet text link ("Forgot your password?").
class AuthTextLink extends StatelessWidget {
  const AuthTextLink({
    required this.label,
    required this.onTap,
    this.linkKey,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final Key? linkKey;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: linkKey,
      onPressed: onTap,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.amber,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A calm inline message under the fields. Never red-alarm styling: a
/// wrong code or a dead connection is not the person's fault.
class AuthMessage extends StatelessWidget {
  const AuthMessage(this.text, {this.positive = false, super.key});

  final String text;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final color = positive ? AppColors.green : AppColors.amber;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: color.withAlpha(22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(70)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              positive
                  ? Icons.check_circle_outline_rounded
                  : Icons.info_outline_rounded,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pops the current account screen with [signedIn] as its result, so the
/// screen that opened the flow (Profile, the subscription gate) knows how it
/// ended.
void finishAuthFlow(BuildContext context, {bool signedIn = true}) =>
    Navigator.of(context).pop(signedIn);

/// Pushes the next screen of an account flow. Resolves true when that
/// screen (or one after it) finished the flow.
Future<bool> pushAuthPage(
  BuildContext context,
  String name,
  WidgetBuilder builder,
) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        settings: RouteSettings(name: name),
        builder: builder,
      ),
    ) ??
    false;

void showAuthToast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), backgroundColor: AppColors.card),
  );
}

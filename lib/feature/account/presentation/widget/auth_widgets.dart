import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/status_hero.dart';

/// The frame every account screen shares: a back arrow, the [StatusHero], a
/// heading and a line of explanation, then the screen's own fields, all
/// arriving in one stagger over a warm wash that cools to green once the
/// flow is done. The same composition as the Wi-Fi page.
///
/// [busy], [error] and [success] are the screen's state, and the hero shows
/// it: an arc while a request is out, a shake on a refusal, a check mark when
/// done. [onSuccessShown] fires once the check mark has landed; that is when
/// a finished screen should leave.
///
/// A new [contentKey] replays the entrance, for a screen that swaps what it
/// shows (a code screen finishing its load).
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    required this.icon,
    required this.title,
    required this.children,
    this.body,
    this.iconColor,
    this.busy = false,
    this.error,
    this.success = false,
    this.onSuccessShown,
    this.contentKey,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Color? iconColor;
  final List<Widget> children;
  final bool busy;
  final Object? error;
  final bool success;
  final VoidCallback? onSuccessShown;
  final Object? contentKey;

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? AppColors.amber;
    final wash = success ? AppColors.green : color;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // A static gradient crossfaded by colour, so it costs nothing per
            // frame while the hero animates.
            Positioned.fill(
              child: AnimatedContainer(
                duration: AppMotion.entrance,
                curve: AppMotion.easeOut,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.78),
                    radius: 0.9,
                    colors: [
                      wash.withValues(alpha: 0.14),
                      AppColors.background.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 4,
                        top: 4,
                      ),
                      child: IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        // Mirrors itself in Persian, so it always points
                        // back towards where the screen came from.
                        icon: Icon(
                          Icons.arrow_back_rounded,
                          color: AppColors.textPrimary,
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: StatusHero(
                                icon: icon,
                                color: color,
                                busy: busy,
                                error: error,
                                success: success,
                                onSuccessShown: onSuccessShown,
                              ),
                            ),
                            StaggeredEntrance(
                              key: ValueKey(contentKey),
                              builder: (context, items) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: items,
                              ),
                              children: [
                                _Heading(title: title, body: body),
                                ...children,
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The title and its explanation. A screen that changes its heading
/// crossfades it instead of cutting.
class _Heading extends StatelessWidget {
  const _Heading({required this.title, required this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final body = this.body;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 26),
      child: PhaseSwitcher(
        child: Column(
          key: ValueKey((title, body)),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 23,
                height: 1.3,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (body != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                    height: 1.7,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Letter spacing for the uppercase English button labels. Persian is a
/// joined script, and spacing its letters pulls every word apart.
double authLabelSpacing(BuildContext context, double latin) =>
    Directionality.of(context) == TextDirection.rtl ? 0 : latin;

/// A text field with a floating label, an icon at its start and a soft glow
/// while focused.
///
/// Addresses and passwords ([ltr]) are identifiers, so what is typed is
/// always laid out left to right, even in Persian. Only the typed text: the
/// label, icon and show-password button still follow the page's direction,
/// so in Persian the label sits on the right with everything else.
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    required this.controller,
    required this.hint,
    this.icon,
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
  final IconData? icon;
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
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final focused = _focus.hasFocus;
    final amber = AppColors.amber;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );
    Color tint(Set<WidgetState> states) =>
        states.contains(WidgetState.focused) ? amber : AppColors.textSecondary;
    final field = TextField(
      key: widget.fieldKey,
      controller: widget.controller,
      focusNode: _focus,
      enabled: widget.enabled,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: !widget.obscure && !widget.ltr,
      keyboardType: widget.keyboardType,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      maxLength: widget.maxLength,
      textDirection: widget.ltr ? TextDirection.ltr : null,
      cursorColor: amber,
      style: TextStyle(color: AppColors.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        labelText: widget.hint,
        counterText: '',
        labelStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(
            color: tint(states),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        filled: true,
        fillColor: focused ? AppColors.card : AppColors.surface,
        contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 18, 16, 18),
        prefixIcon: widget.icon == null ? null : Icon(widget.icon, size: 20),
        prefixIconColor: WidgetStateColor.resolveWith(tint),
        border: border(AppColors.border),
        enabledBorder: border(AppColors.border),
        disabledBorder: border(AppColors.border.withValues(alpha: 0.6)),
        focusedBorder: border(amber, 1.6),
        suffixIcon: widget.obscure
            ? IconButton(
                tooltip: _hidden ? s.auth_show_password : s.auth_hide_password,
                icon: AnimatedSwitcher(
                  duration: AppMotion.chip,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.leaving,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.7,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Icon(
                    _hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    key: ValueKey(_hidden),
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                ),
                onPressed: () => setState(() => _hidden = !_hidden),
              )
            : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: AnimatedContainer(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: amber.withValues(alpha: focused ? 0.16 : 0),
              blurRadius: 18,
            ),
          ],
        ),
        child: field,
      ),
    );
  }
}

/// The one strong action on an account screen: a warm gradient that swaps
/// its label for a spinner while busy and for a check mark once done.
class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    required this.label,
    required this.onTap,
    this.busy = false,
    this.done = false,
    this.destructive = false,
    this.buttonKey,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;
  final bool done;
  final bool destructive;
  final Key? buttonKey;

  static final _radius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy && !done;
    final base = done
        ? AppColors.green
        : destructive
        ? AppColors.red
        : AppColors.amber;
    final ink = AppColors.background;
    final Widget content;
    if (done) {
      content = Icon(
        Icons.check_rounded,
        key: const ValueKey('done'),
        color: ink,
        size: 26,
      );
    } else if (busy) {
      content = SizedBox(
        key: const ValueKey('busy'),
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: ink),
      );
    } else {
      content = Text(
        label,
        key: const ValueKey('label'),
        textAlign: TextAlign.center,
        maxLines: 2,
        style: TextStyle(
          color: ink,
          fontSize: 14.5,
          fontWeight: FontWeight.w900,
          letterSpacing: authLabelSpacing(context, 1.2),
        ),
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        opacity: enabled || busy || done ? 1 : 0.45,
        child: PressableScale(
          key: buttonKey,
          onTap: enabled ? onTap : null,
          borderRadius: _radius,
          child: AnimatedContainer(
            duration: AppMotion.card,
            curve: AppMotion.easeOut,
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: _radius,
              gradient: LinearGradient(
                begin: AlignmentDirectional.centerStart,
                end: AlignmentDirectional.centerEnd,
                colors: [
                  base,
                  Color.lerp(
                    base,
                    done ? Colors.teal : Colors.deepOrange,
                    destructive && !done ? 0.2 : 0.35,
                  )!,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: base.withValues(alpha: enabled || done ? 0.24 : 0),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: AnimatedSwitcher(
              duration: AppMotion.card,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: content,
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
    this.leading,
    this.buttonKey,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Drawn in place of [icon], for a mark that is not an icon font glyph.
  final Widget? leading;
  final Key? buttonKey;

  static final _radius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final leading =
        this.leading ??
        (icon == null
            ? null
            : Icon(icon, size: 20, color: AppColors.textPrimary));
    return AnimatedOpacity(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      opacity: enabled ? 1 : 0.5,
      child: PressableScale(
        key: buttonKey,
        onTap: onTap,
        borderRadius: _radius,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: _radius,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 12)],
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: authLabelSpacing(context, 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Google's four-colour "G", drawn rather than taken from the icon font,
/// which only has a one-colour stand-in.
class GoogleMark extends StatelessWidget {
  const GoogleMark({this.size = 20, super.key});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: const _GoogleMarkPainter());
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    // Angles run clockwise from three o'clock. The gap at the top-right is
    // where the G opens.
    const deg = math.pi / 180;
    canvas
      ..drawArc(rect, 0, 45 * deg, false, arc(_blue))
      ..drawArc(rect, 45 * deg, 90 * deg, false, arc(_green))
      ..drawArc(rect, 135 * deg, 75 * deg, false, arc(_yellow))
      ..drawArc(rect, 210 * deg, 105 * deg, false, arc(_red));
    // The crossbar, from the centre out to the right edge.
    final c = size.center(Offset.zero);
    canvas.drawRect(
      Rect.fromLTRB(c.dx, c.dy - stroke / 2, size.width, c.dy + stroke / 2),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(_GoogleMarkPainter oldDelegate) => false;
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
    return AnimatedOpacity(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      opacity: onTap == null ? 0.5 : 1,
      child: TextButton(
        key: linkKey,
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.amber,
          disabledForegroundColor: AppColors.amber,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.amber,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// "or", between two lines that fade out towards the edges.
class AuthOrDivider extends StatelessWidget {
  const AuthOrDivider({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    Widget line(AlignmentGeometry from) => Expanded(
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: from,
            end: from == AlignmentDirectional.centerStart
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            colors: [AppColors.border.withValues(alpha: 0), AppColors.border],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          line(AlignmentDirectional.centerStart),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              label,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ),
          line(AlignmentDirectional.centerEnd),
        ],
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
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  positive ? Icons.check_rounded : Icons.priority_high_rounded,
                  size: 16,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    text,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where an [AuthMessage] appears and goes: it opens its space and drops
/// in, and a new message crossfades over the old one, instead of the fields
/// below jumping. Holds its place in the page's stagger even while empty.
class AuthMessageSlot extends StatelessWidget {
  const AuthMessageSlot(this.text, {this.positive = false, super.key});

  final String? text;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final text = this.text;
    final reduced = AppMotion.reduced(context);
    return AnimatedSize(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppMotion.card,
        switchInCurve: AppMotion.easeOut,
        switchOutCurve: AppMotion.leaving,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) {
          final fade = FadeTransition(opacity: animation, child: child);
          if (reduced) return fade;
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.12),
              end: Offset.zero,
            ).animate(animation),
            child: fade,
          );
        },
        child: text == null
            ? const SizedBox(key: ValueKey('none'), width: double.infinity)
            : AuthMessage(
                text,
                positive: positive,
                key: ValueKey((text, positive)),
              ),
      ),
    );
  }
}

/// Shows or hides [child] by opening and closing its space, for a block a
/// screen only sometimes has, so it keeps its place in the page's stagger.
class AuthReveal extends StatelessWidget {
  const AuthReveal({required this.visible, required this.child, super.key});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppMotion.card,
        switchInCurve: AppMotion.easeOut,
        switchOutCurve: AppMotion.leaving,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        child: visible
            ? KeyedSubtree(key: const ValueKey(true), child: child)
            : const SizedBox(key: ValueKey(false), width: double.infinity),
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

/// A short note that outlives the screen that raised it ("You're signed
/// in." over Profile, once the sign-in screen has gone).
void showAuthToast(
  BuildContext context,
  String message, {
  bool positive = true,
}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.card,
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.border),
      ),
      content: Row(
        children: [
          Icon(
            positive ? Icons.check_circle_rounded : Icons.info_rounded,
            color: positive ? AppColors.green : AppColors.amber,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

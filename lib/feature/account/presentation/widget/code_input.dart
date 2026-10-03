import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';

/// The code as a row of boxes over one invisible field, so the numeric
/// keypad, paste and one-time-code autofill all work as for a normal field.
/// Persian digits typed on a Persian keyboard count as digits.
///
/// Each digit drops into its box, the box waiting for the next one is lit,
/// a refused code shakes the row and an accepted one turns it green.
class CodeInput extends StatefulWidget {
  const CodeInput({
    required this.controller,
    required this.length,
    required this.onCompleted,
    this.enabled = true,
    this.error,
    this.success = false,
    super.key,
  });

  final TextEditingController controller;
  final int length;
  final ValueChanged<String> onCompleted;
  final bool enabled;

  /// The current refusal. A new non-null value shakes the row once.
  final Object? error;

  /// The code was accepted.
  final bool success;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: AppMotion.entrance + AppMotion.press,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _focus.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(CodeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null &&
        widget.error != oldWidget.error &&
        !AppMotion.reduced(context)) {
      _shake.forward(from: 0);
    }
    if (!oldWidget.enabled && widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onChanged(String raw) {
    final digits = asciiDigits(raw);
    final clipped = digits.length > widget.length
        ? digits.substring(0, widget.length)
        : digits;
    if (clipped != raw) {
      widget.controller.value = TextEditingValue(
        text: clipped,
        selection: TextSelection.collapsed(offset: clipped.length),
      );
    }
    if (clipped.length == widget.length) widget.onCompleted(clipped);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final farsi = Localizations.localeOf(context).languageCode == 'fa';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? _focus.requestFocus : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The field that actually takes the input; its own text is not
          // drawn, the boxes below are.
          Opacity(
            opacity: 0,
            child: TextField(
              key: const ValueKey('code-field'),
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9۰-۹٠-٩]')),
              ],
              showCursor: false,
              enableInteractiveSelection: true,
              onChanged: _onChanged,
            ),
          ),
          // Codes read left to right in every language.
          Directionality(
            textDirection: TextDirection.ltr,
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 8.0;
                  final fit =
                      (constraints.maxWidth - gap * (widget.length - 1)) /
                      widget.length;
                  final width = math.min(50.0, fit);
                  return AnimatedBuilder(
                    animation: _shake,
                    builder: (context, child) {
                      final t = _shake.value;
                      final dx = math.sin(t * math.pi * 6) * 8 * (1 - t);
                      return Transform.translate(
                        offset: Offset(dx, 0),
                        child: child,
                      );
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < widget.length; i++) ...[
                          if (i > 0) const SizedBox(width: gap),
                          _Box(
                            width: width,
                            digit: i < text.length
                                ? localizeDigits(text[i], farsi: farsi)
                                : '',
                            active:
                                _focus.hasFocus &&
                                widget.enabled &&
                                (i == text.length ||
                                    (i == widget.length - 1 &&
                                        text.length == widget.length)),
                            enabled: widget.enabled,
                            success: widget.success,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({
    required this.width,
    required this.digit,
    required this.active,
    required this.enabled,
    required this.success,
  });

  final double width;
  final String digit;
  final bool active;
  final bool enabled;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final filled = digit.isNotEmpty;
    final accent = success ? AppColors.green : AppColors.amber;
    final Color edge;
    if (success) {
      edge = AppColors.green;
    } else if (active) {
      edge = AppColors.amber;
    } else if (filled) {
      edge = AppColors.amber.withValues(alpha: 0.4);
    } else {
      edge = AppColors.border;
    }
    return AnimatedContainer(
      duration: AppMotion.chip,
      curve: AppMotion.easeOut,
      width: width,
      height: width * 1.2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active || success ? AppColors.card : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: edge, width: active || success ? 1.8 : 1.2),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: active || success ? 0.22 : 0),
            blurRadius: 14,
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The digit drops in from just above, a little small.
          AnimatedSwitcher(
            duration: AppMotion.chip,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              digit,
              key: ValueKey(digit),
              style: TextStyle(
                color: success
                    ? AppColors.green
                    : enabled
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          // Where the next digit goes: a short bar at the foot of the box.
          PositionedDirectional(
            bottom: 10,
            child: AnimatedOpacity(
              duration: AppMotion.chip,
              curve: AppMotion.easeOut,
              opacity: active && !filled ? 1 : 0,
              child: Container(
                width: 14,
                height: 2.4,
                decoration: BoxDecoration(
                  color: AppColors.amber,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

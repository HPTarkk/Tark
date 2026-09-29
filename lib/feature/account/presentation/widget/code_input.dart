import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';

/// The code as a row of boxes over one invisible field, so the numeric
/// keypad, paste and one-time-code autofill all work as for a normal field.
/// Persian digits typed on a Persian keyboard count as digits.
class CodeInput extends StatefulWidget {
  const CodeInput({
    required this.controller,
    required this.length,
    required this.onCompleted,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final int length;
  final ValueChanged<String> onCompleted;
  final bool enabled;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  final _focus = FocusNode();

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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.length; i++)
                    _Box(
                      digit: i < text.length
                          ? localizeDigits(text[i], farsi: farsi)
                          : '',
                      active:
                          _focus.hasFocus &&
                          (i == text.length ||
                              (i == widget.length - 1 &&
                                  text.length == widget.length)),
                      enabled: widget.enabled,
                    ),
                ],
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
    required this.digit,
    required this.active,
    required this.enabled,
  });

  final String digit;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 54,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? AppColors.amber : AppColors.border,
          width: active ? 1.6 : 1,
        ),
      ),
      child: Text(
        digit,
        style: TextStyle(
          color: enabled ? AppColors.textPrimary : AppColors.textSecondary,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

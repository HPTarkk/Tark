import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// What a [showStatusNote] is telling: done, a heads-up, or a problem.
enum StatusTone { done, notice, problem }

/// A short note at the foot of the screen: a floating, lit card with its
/// mark in a ring of the tone's colour, instead of a bare grey bar. Replaces
/// whatever note is up, so two never stack.
void showStatusNote(
  BuildContext context,
  String message, {
  StatusTone tone = StatusTone.notice,
}) {
  final (icon, color) = switch (tone) {
    StatusTone.done => (Icons.check_rounded, AppColors.green),
    StatusTone.notice => (Icons.info_outline_rounded, AppColors.amber),
    StatusTone.problem => (Icons.priority_high_rounded, AppColors.red),
  };
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        content: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(10, 10, 16, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: AlignmentDirectional.centerStart,
              end: AlignmentDirectional.centerEnd,
              colors: [
                Color.alphaBlend(color.withAlpha(40), AppColors.card),
                AppColors.card,
              ],
            ),
            border: Border.all(color: color.withAlpha(110)),
            boxShadow: [
              BoxShadow(
                color: color.withAlpha(40),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withAlpha(40),
                  border: Border.all(color: color.withAlpha(150)),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontFamily: 'Vazirmatn',
                    color: AppColors.textPrimary,
                    fontSize: 13.5,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
}

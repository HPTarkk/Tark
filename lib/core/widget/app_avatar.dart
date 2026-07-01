import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Shared avatar widget showing name initials in an amber circle.
///
/// Amber border when [isActive], grey border when inactive.
class AppAvatar extends StatelessWidget {
  final String name;
  final bool isActive;
  final double size;

  const AppAvatar({
    super.key,
    required this.name,
    this.isActive = true,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.amber.withAlpha(30),
        border: Border.all(
          color: isActive
              ? AppColors.amber.withAlpha(180)
              : AppColors.border,
          width: 1.5,
        ),
        boxShadow: isActive
            ? [BoxShadow(color: AppColors.amber.withAlpha(60), blurRadius: 12)]
            : null,
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: AppColors.amber,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

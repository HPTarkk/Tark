import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../manager/walkie_talkie_cubit.dart';

/// The "Edit" chip beside your own name on the channel screen.
///
/// Goes straight to the Profile page — the one place the name and avatar
/// live — rather than to Settings, where Profile is one row among many and
/// the person would have to find it again. The running [WalkieTalkieCubit]
/// rides along in `extra` (the same threading Settings uses), so a new name
/// reaches the other phones the moment it is saved, and the back gesture
/// lands on this channel screen, not on Settings.
class EditProfileChip extends StatelessWidget {
  const EditProfileChip({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return PressableScale(
      scale: 0.94,
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        ScreenLog.tap('Channel edit profile');
        context.pushNamed(
          AppRoutes.profileName,
          extra: context.read<WalkieTalkieCubit>(),
        );
      },
      child: Container(
        key: const Key('channel-edit-profile'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.border,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_rounded, color: AppColors.amber, size: 12),
            const SizedBox(width: 4),
            Text(
              s.edit_name,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 10,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

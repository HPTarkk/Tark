import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/widget/avatar_picker_grid.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 3 — pick a face to go with the callsign. Nothing is pre-selected:
/// the CTA waits for a tap, like the callsign beat waits for a name, so the
/// face people see in the channel is one this person chose.
class AvatarStep extends StatelessWidget {
  final Animation<double> reveal;

  const AvatarStep({super.key, required this.reveal});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      buildWhen: (p, c) => p.avatarId != c.avatarId,
      builder: (context, state) => StaggeredItem(
        reveal: reveal,
        index: 0,
        count: 1,
        child: HudPanel(
          header: s.onboarding_avatar_title,
          status: '04·06',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.onboarding_avatar_help,
                style: const TextStyle(
                  color: Onb.textDim,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              AvatarPickerGrid(
                selectedId: state.avatarId,
                accent: Onb.amber,
                idleRing: Onb.line,
                onSelected: (id) {
                  Sfx.play(SfxEvent.toggle);
                  context.read<OnboardingCubit>().selectAvatar(id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

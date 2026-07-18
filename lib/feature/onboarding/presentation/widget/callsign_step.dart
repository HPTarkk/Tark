import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/utils/extensions.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 2 — pick a callsign, entered on a terminal-style HUD field. The handle
/// is echoed live on the radio's screen (which lit up for this beat), so this
/// panel is just the input plus a dice key to roll a random handle.
class CallsignStep extends StatefulWidget {
  final Animation<double> reveal;

  /// Called on keyboard "done" with a valid name — advances the journey.
  final VoidCallback onSubmit;

  const CallsignStep({super.key, required this.reveal, required this.onSubmit});

  @override
  State<CallsignStep> createState() => _CallsignStepState();
}

class _CallsignStepState extends State<CallsignStep> {
  late final TextEditingController _controller;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<OnboardingCubit>().state.name,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The gamified escape hatch for name-picker paralysis: rolls a radio
  /// handle from a localized pool plus a two-digit unit number (Persian
  /// digits under fa, so no bidi reordering inside the name).
  void _shuffle() {
    final pool = context.getString.onboarding_callsign_pool.split(',');
    final word = pool[_rng.nextInt(pool.length)].trim();
    final number = (10 + _rng.nextInt(90)).localized(context);
    final name = '$word$number';
    Sfx.play(SfxEvent.toggle);
    _controller.text = name;
    context.read<OnboardingCubit>().setName(name);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocListener<OnboardingCubit, OnboardingState>(
      listenWhen: (p, c) => p.name != c.name && c.name != _controller.text,
      listener: (_, state) => _controller.text = state.name,
      child: StaggeredItem(
        reveal: widget.reveal,
        index: 0,
        count: 1,
        child: HudPanel(
          header: s.onboarding_callsign_title,
          status: '03·05',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              HudField(
                controller: _controller,
                hint: s.name_hint,
                onChanged: context.read<OnboardingCubit>().setName,
                onSubmitted: () {
                  if (_controller.text.trim().isNotEmpty) widget.onSubmit();
                },
                trailing: HudMiniKey(
                  icon: Icons.casino_rounded,
                  onTap: _shuffle,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 13, color: Onb.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.onboarding_callsign_help,
                      style: const TextStyle(
                        color: Onb.textDim,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
